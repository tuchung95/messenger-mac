import Cocoa
import WebKit
import UserNotifications

// MARK: - Config

let homeURL = URL(string: "https://www.messenger.com/")!

let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

// Domains kept inside the app; everything else opens in the default browser.
let internalHosts = [
    "messenger.com", "facebook.com", "fbcdn.net", "fbsbx.com", "meta.com",
]

func isInternal(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return internalHosts.contains { host == $0 || host.hasSuffix("." + $0) }
}

// MARK: - JS shim

/// WKWebView does not expose the Web Notifications API, so the page's
/// Notification calls are re-routed to the native UNUserNotificationCenter.
let notifyShimJS = #"""
(function () {
  if (window.__nativeNotify) { return; }
  window.__nativeNotify = true;

  function send(title, options) {
    options = options || {};
    try {
      window.webkit.messageHandlers.notify.postMessage({
        title: String(title == null ? "" : title),
        body: String(options.body == null ? "" : options.body),
        tag: String(options.tag == null ? "" : options.tag)
      });
    } catch (e) {}
  }

  function NativeNotification(title, options) {
    if (!(this instanceof NativeNotification)) {
      return new NativeNotification(title, options);
    }
    options = options || {};
    this.title = title;
    this.body = options.body || "";
    this.tag = options.tag || "";
    this.data = options.data;
    this.onclick = null;
    this.onclose = null;
    this.onerror = null;
    this.onshow = null;
    send(title, options);
  }
  NativeNotification.prototype.close = function () {};
  NativeNotification.prototype.addEventListener = function () {};
  NativeNotification.prototype.removeEventListener = function () {};
  NativeNotification.prototype.dispatchEvent = function () { return true; };

  NativeNotification.requestPermission = function (cb) {
    if (typeof cb === "function") { try { cb("granted"); } catch (e) {} }
    return Promise.resolve("granted");
  };
  Object.defineProperty(NativeNotification, "permission", {
    get: function () { return "granted"; }
  });
  Object.defineProperty(NativeNotification, "maxActions", {
    get: function () { return 2; }
  });

  window.Notification = NativeNotification;

  // Messenger may go through the service worker instead of window.Notification.
  if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype) {
    ServiceWorkerRegistration.prototype.showNotification = function (t, o) {
      send(t, o);
      return Promise.resolve();
    };
    ServiceWorkerRegistration.prototype.getNotifications = function () {
      return Promise.resolve([]);
    };
  }

  // Keep feature detection that queries navigator.permissions consistent.
  if (navigator.permissions && navigator.permissions.query) {
    var realQuery = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = function (desc) {
      if (desc && desc.name === "notifications") {
        return Promise.resolve({
          state: "granted", status: "granted",
          onchange: null,
          addEventListener: function () {}, removeEventListener: function () {}
        });
      }
      return realQuery(desc);
    };
  }
})();
"""#

/// Reports the page's real background colour so the window chrome can match it.
/// Covers Messenger's own light/dark switch, not just the system setting.
let themeSyncJS = #"""
(function () {
  if (window.__themeSync) { return; }
  window.__themeSync = true;

  function bgOf(el) {
    if (!el) { return ""; }
    try { return getComputedStyle(el).backgroundColor || ""; } catch (e) { return ""; }
  }
  function isBlank(c) {
    return !c || c === "transparent" || c === "rgba(0, 0, 0, 0)";
  }

  function report() {
    var c = bgOf(document.body);
    if (isBlank(c)) { c = bgOf(document.documentElement); }
    if (isBlank(c)) { return; }
    try { window.webkit.messageHandlers.theme.postMessage(c); } catch (e) {}
  }

  report();
  // The real chat UI paints later than DOMContentLoaded.
  setTimeout(report, 600);
  setTimeout(report, 1800);
  setTimeout(report, 4000);

  try {
    var mo = new MutationObserver(report);
    mo.observe(document.documentElement, {
      attributes: true, attributeFilter: ["class", "style", "data-theme"]
    });
    if (document.body) {
      mo.observe(document.body, { attributes: true, attributeFilter: ["class", "style"] });
    }
  } catch (e) {}

  try {
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", report);
  } catch (e) {}
})();
"""#

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler, UNUserNotificationCenterDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    private var titleObs: NSKeyValueObservation?
    private var lastWebNotification = Date.distantPast
    private var lastBadgeCount = 0
    /// Set when UNUserNotificationCenter refuses this (non-Apple-signed) app.
    private var useLegacy = false
    /// Suspends title-driven badge updates during a manual badge test.
    private var badgeTestUntil = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWebView()
        buildWindow()
        buildMenu()
        setUpNotifications()
        if let pending = pendingURL {
            open(deepLink: pending)
            pendingURL = nil
        } else {
            webView.load(URLRequest(url: homeURL))
        }
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--test-notify") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.testNotification(nil)
                // Force a visible badge so it can be checked independently
                // of whether the page currently has unread messages.
                self?.badgeTestUntil = Date().addingTimeInterval(16)
                NSApp.dockTile.badgeLabel = "9"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.syncBadge()
            }
        }
    }

    // MARK: URL scheme (messenger:// , fb-messenger://)

    private var pendingURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // Cold launch can deliver the URL before the web view exists.
        if webView == nil { pendingURL = url; return }
        open(deepLink: url)
    }

    private func open(deepLink url: URL) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: threadURL(from: url) ?? homeURL))
    }

    /// fb-messenger://user-thread/123 -> https://www.messenger.com/t/123
    private func threadURL(from url: URL) -> URL? {
        let parts = (url.host.map { [$0] } ?? []) + url.pathComponents
        guard let id = parts.last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return URL(string: "https://www.messenger.com/t/\(id)")
    }

    // MARK: Web view

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        // .default() is the persistent store, so the login session survives relaunches.
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let ucc = WKUserContentController()
        ucc.add(self, name: "notify")
        ucc.add(self, name: "theme")
        ucc.addUserScript(WKUserScript(source: themeSyncJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: notifyShimJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        config.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // messenger.com puts the unread count in the document title as "(3) Messenger".
        titleObs = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            self?.syncBadge()
        }
    }

    private func syncBadge() {
        guard Date() >= badgeTestUntil else { return }
        let title = webView.title ?? ""
        var badge = ""
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            badge = String(title[title.index(after: title.startIndex)..<close])
        }
        NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge

        // Fallback: if the page never called Notification but the unread count
        // climbed, still tell the user. Suppressed right after a real web
        // notification so a single message cannot fire two banners.
        let count = Int(badge) ?? 0
        defer { lastBadgeCount = count }
        guard count > lastBadgeCount,
              Date().timeIntervalSince(lastWebNotification) > 5 else { return }
        let n = count - lastBadgeCount
        post(title: "Messenger",
             body: n == 1 ? "Bạn có tin nhắn mới" : "Bạn có \(n) tin nhắn mới",
             tag: "")
    }

    // MARK: Notifications

    /// User preference; banners default to on.
    private var bannersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showBanners") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showBanners") }
    }

    @objc func toggleBanners(_ sender: NSMenuItem) {
        bannersEnabled.toggle()
        sender.state = bannersEnabled ? .on : .off
    }

    /// NSLog is not retained for third-party apps, so diagnostics go to a file.
    private func diag(_ line: String) {
        let path = "/tmp/msgr-notify.log"
        let text = line + "\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(text.utf8))
            try? fh.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                DispatchQueue.main.async { self.useLegacy = true }
                self.diag("authorization failed: " + error.localizedDescription)
            } else {
                self.diag("authorization granted=" + (granted ? "true" : "false"))
            }
        }
    }

    /// The page calls Notification(...) / showNotification(...); the shim forwards here.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "theme", let css = message.body as? String {
            applyTheme(cssColor: css)
            return
        }
        guard message.name == "notify", let d = message.body as? [String: Any] else { return }
        lastWebNotification = Date()
        post(title: (d["title"] as? String) ?? "Messenger",
             body: (d["body"] as? String) ?? "",
             tag: (d["tag"] as? String) ?? "")
    }

    private func post(title: String, body: String, tag: String) {
        guard bannersEnabled else { return }
        if useLegacy { postLegacy(title: title, body: body); return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Messenger" : title
        content.body = body
        content.sound = .default
        if !tag.isEmpty { content.threadIdentifier = tag }
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error = error {
                self.diag("post failed: " + error.localizedDescription)
            }
        }
    }

    /// Deprecated API, but it is the only one an app signed outside Apple's
    /// chain can still deliver through.
    @available(macOS, deprecated: 11.0)
    private func postLegacy(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title.isEmpty ? "Messenger" : title
        n.informativeText = body
        n.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(n)
        diag("legacy delivered: " + title + " / " + body)
    }

    @objc func testNotification(_ sender: Any?) {
        post(title: "Messenger", body: "Thông báo thử — nếu bạn thấy dòng này thì banner hoạt động.", tag: "")
    }

    // Show banners even when Messenger is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // Clicking a banner brings the window back.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        handler()
    }

    // MARK: Theme

    /// Paints the titlebar with the page's own background colour so the window
    /// reads as one surface, and flips the appearance so the traffic lights and
    /// title text stay legible on it.
    private func applyTheme(cssColor: String) {
        let parts = cssColor
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .filter { !$0.isEmpty }
            .compactMap { Double($0) }
        guard parts.count >= 3 else { return }
        let r = parts[0] / 255, g = parts[1] / 255, b = parts[2] / 255
        window.backgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        window.appearance = NSAppearance(named: luma < 0.5 ? .darkAqua : .aqua)
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Messenger"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 480)
        window.delegate = self
        window.contentView = webView
        window.setFrameAutosaveName("MessengerMainWindow")
        if window.frame.width < 420 { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    // Closing the window parks the app in the Dock instead of quitting it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if action.navigationType == .linkActivated, !isInternal(url), let url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // target="_blank" links: hand them to the browser rather than dropping them.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isInternal(url) { webView.load(URLRequest(url: url)) }
            else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    // Audio/video calls.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(isInternal(frame.request.url) ? .grant : .deny)
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(name)
            n += 1
        }
        completionHandler(dest)
    }

    // MARK: Actions

    @objc func goHome(_ sender: Any?) { webView.load(URLRequest(url: homeURL)) }
    @objc func reload(_ sender: Any?) { webView.reload() }
    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 2.5) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc func toggleFloat(_ sender: NSMenuItem) {
        let on = window.level == .floating
        window.level = on ? .normal : .floating
        sender.state = on ? .off : .on
    }

    @objc func signOut(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Đăng xuất khỏi Messenger?"
        alert.informativeText = "Toàn bộ cookie và dữ liệu web của app sẽ bị xoá."
        alert.addButton(withTitle: "Đăng xuất")
        alert.addButton(withTitle: "Huỷ")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            self.webView.load(URLRequest(url: homeURL))
        }
    }

    // MARK: Menu

    private func item(_ title: String, _ sel: Selector?, _ key: String,
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        return mi
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Về Messenger", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Gửi thông báo thử", #selector(testNotification(_:)), ""))
        let banners = item("Hiện thông báo banner", #selector(toggleBanners(_:)), "")
        banners.state = bannersEnabled ? .on : .off
        appMenu.addItem(banners)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Đăng xuất…", #selector(signOut(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Ẩn Messenger", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Ẩn app khác", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Thoát Messenger", #selector(NSApplication.terminate(_:)), "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Sửa")
        edit.addItem(item("Hoàn tác", Selector(("undo:")), "z"))
        edit.addItem(item("Làm lại", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cắt", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Sao chép", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Dán", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Chọn tất cả", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "Xem")
        view.addItem(item("Tải lại", #selector(reload(_:)), "r"))
        view.addItem(item("Trang chủ", #selector(goHome(_:)), "0", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Quay lại", #selector(goBack(_:)), "["))
        view.addItem(item("Tiến tới", #selector(goForward(_:)), "]"))
        view.addItem(.separator())
        view.addItem(item("Phóng to", #selector(zoomIn(_:)), "+"))
        view.addItem(item("Thu nhỏ", #selector(zoomOut(_:)), "-"))
        view.addItem(item("Cỡ thật", #selector(zoomReset(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Toàn màn hình", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        viewItem.submenu = view
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Cửa sổ")
        win.addItem(item("Thu nhỏ", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Đóng", #selector(NSWindow.performClose(_:)), "w"))
        win.addItem(.separator())
        win.addItem(item("Luôn hiện trên cùng", #selector(toggleFloat(_:)), ""))
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
