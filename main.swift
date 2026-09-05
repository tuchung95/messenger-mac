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

/// How long the window stays closed before the page is recycled to give
/// its accumulated caches back.
let idleTrimDelay: TimeInterval = 10 * 60

// Update feed. The release's .zip asset must contain Messenger.app.
let updateFeedURL = URL(string:
    "https://api.github.com/repos/tuchung95/messenger-mac/releases/latest")!
let releasesPageURL = URL(string:
    "https://github.com/tuchung95/messenger-mac/releases")!

/// Quotes a path for /bin/sh; bundle paths can contain spaces.
func shq(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

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

/// Answers whether a call or a playing clip would be cut short by a reload.
let mediaActiveJS = #"""
(function () {
  var els = document.querySelectorAll("video, audio");
  for (var i = 0; i < els.length; i++) {
    if (!els[i].paused && !els[i].ended) { return true; }
  }
  return false;
})();
"""#

/// messenger.com no longer puts the unread count in the document title, so it
/// is read off the chat rail's own label — "Đoạn chat · 5 tin nhắn chưa đọc",
/// "Chats · 5 unread messages". Thread rows carry their own smaller counts, so
/// the largest label wins. -1 means the chat list is not up and the count is
/// unknown, which is not the same as nothing unread.
let unreadCountJS = #"""
(function () {
  if (!document.querySelector('[role="grid"]')) { return -1; }
  var best = 0;
  var els = document.querySelectorAll(
    '[aria-label*="unread" i],[aria-label*="chưa đọc" i]');
  for (var i = 0; i < els.length; i++) {
    var m = (els[i].getAttribute("aria-label") || "").match(/\d+/);
    if (m) { best = Math.max(best, parseInt(m[0], 10)); }
  }
  // Kept as a second source in case the label ever goes away again.
  var t = document.title.match(/\((\d+)\)/);
  if (t) { best = Math.max(best, parseInt(t[1], 10)); }
  return best;
})();
"""#

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                         WKScriptMessageHandler, UNUserNotificationCenterDelegate,
                         URLSessionDownloadDelegate {

    var window: NSWindow!
    var webView: WKWebView!
    private var lastWebNotification = Date.distantPast
    private var lastBadgeCount = 0
    /// Unread messages as of the last reading, kept across reloads and
    /// relaunches so the badge stays up while the page is not there to ask.
    private var unreadCount = 0
    /// The page reports the count only in its DOM, so it has to be asked.
    private var badgeTimer: Timer?
    /// Set when UNUserNotificationCenter refuses this (non-Apple-signed) app.
    private var useLegacy = false
    /// Suspends title-driven badge updates during a manual badge test.
    private var badgeTestUntil = Date.distantPast
    /// Fires a page recycle once the window has been closed long enough.
    private var idleTrimTimer: Timer?
    /// A recycle replays the unread count from zero; the fallback banner would
    /// otherwise announce every existing message again.
    private var silentBadgeUntil = Date.distantPast
    private var updatePanel: NSWindow?
    private var updateBar: NSProgressIndicator?
    private var updateLabel: NSTextField?
    private var updateTask: URLSessionDownloadTask?
    private var updateTag = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWebView()
        buildWindow()
        buildMenu()
        setUpNotifications()
        restoreBadge()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in self?.syncBadge()
        }
        badgeTimer?.tolerance = 1
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
        cancelIdleTrim()
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
    }

    private func syncBadge() {
        guard Date() >= badgeTestUntil else { return }
        webView.evaluateJavaScript(unreadCountJS) { [weak self] result, _ in
            guard let self = self else { return }
            let count = (result as? NSNumber)?.intValue ?? -1
            // The chat list is not up yet, so the count is unknown rather than
            // zero: leave the badge that is already on the tile alone.
            guard count >= 0 else { return }
            self.showBadge(count)

            // Fallback: if the page never called Notification but the unread
            // count climbed, still tell the user. Suppressed right after a real
            // web notification so a single message cannot fire two banners.
            let previous = self.lastBadgeCount
            self.lastBadgeCount = count
            guard Date() >= self.silentBadgeUntil,
                  count > previous,
                  Date().timeIntervalSince(self.lastWebNotification) > 5 else { return }
            let n = count - previous
            self.post(title: "Messenger",
                      body: n == 1 ? "Bạn có tin nhắn mới" : "Bạn có \(n) tin nhắn mới",
                      tag: "")
        }
    }

    private func showBadge(_ count: Int) {
        unreadCount = count
        UserDefaults.standard.set(count, forKey: "unreadCount")
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    /// Puts the count from the last session back on the tile so the badge is up
    /// before the page has finished loading; it self-corrects once it has.
    private func restoreBadge() {
        showBadge(UserDefaults.standard.integer(forKey: "unreadCount"))
        // Those messages were already counted, so they must not be announced.
        lastBadgeCount = unreadCount
    }

    // MARK: Idle memory trim

    /// Messenger keeps growing its image and DOM caches for as long as the page
    /// lives, and closing the window only hides it. Once the window has been
    /// closed for a while the page is recycled instead: a reload hands the
    /// caches back but lets the page reconnect, so notifications keep arriving.
    /// Unloading the view would free more, at the cost of silencing the app.
    private func scheduleIdleTrim() {
        idleTrimTimer?.invalidate()
        idleTrimTimer = Timer.scheduledTimer(withTimeInterval: idleTrimDelay,
                                             repeats: false) { [weak self] _ in
            self?.trimMemory()
        }
    }

    private func cancelIdleTrim() {
        idleTrimTimer?.invalidate()
        idleTrimTimer = nil
    }

    private func trimMemory() {
        guard !window.isVisible else { return }
        webView.evaluateJavaScript(mediaActiveJS) { [weak self] result, _ in
            guard let self = self else { return }
            // A call can outlive the window; wait it out rather than cut it off.
            if (result as? Bool) == true { self.scheduleIdleTrim(); return }
            let caches: Set<String> = [
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
            ]
            self.silentBadgeUntil = Date().addingTimeInterval(30)
            WKWebsiteDataStore.default().removeData(ofTypes: caches,
                                                    modifiedSince: .distantPast) {
                self.webView.reload()
            }
        }
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

    /// User preference; the notification sound defaults to on.
    private var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notificationSound") }
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        soundEnabled.toggle()
        sender.state = soundEnabled ? .on : .off
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
        content.sound = soundEnabled ? .default : nil
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
        n.soundName = soundEnabled ? NSUserNotificationDefaultSoundName : nil
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
        handler(soundEnabled ? [.banner, .sound] : [.banner])
    }

    // Clicking a banner brings the window back.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        cancelIdleTrim()
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
        scheduleIdleTrim()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        cancelIdleTrim()
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

    /// Every load replays the unread count from zero, so the fallback banner
    /// has to sit out the moments after one or it announces the whole inbox.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        silentBadgeUntil = Date().addingTimeInterval(20)
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

    // MARK: Update

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String) ?? "0"
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Compares component by component: "1.10" is newer than "1.9", which a
    /// plain string compare would get backwards.
    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let l = parts(lhs), r = parts(rhs)
        for i in 0..<max(l.count, r.count) {
            let x = i < l.count ? l[i] : 0
            let y = i < r.count ? r[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func checkForUpdate(_ sender: Any?) {
        guard updateTask == nil else { updatePanel?.makeKeyAndOrderFront(nil); return }
        var req = URLRequest(url: updateFeedURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.alert("Không kiểm tra được cập nhật", error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    self.alert("Không kiểm tra được cập nhật", code == 404
                        ? "Repo chưa có bản phát hành nào, hoặc đang ở chế độ riêng tư."
                        : "GitHub trả về mã \(code).")
                    return
                }
                guard self.isNewer(tag, than: self.currentVersion) else {
                    self.alert("Đã là bản mới nhất",
                               "Bạn đang dùng phiên bản \(self.currentVersion).")
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.compactMap { $0["browser_download_url"] as? String }
                    .first { $0.lowercased().hasSuffix(".zip") }
                    .flatMap { URL(string: $0) }
                guard let zip = zip else {
                    self.alert("Bản \(tag) không có file cài",
                               "Bản phát hành này không kèm file .zip nào.")
                    NSWorkspace.shared.open(releasesPageURL)
                    return
                }
                self.confirmUpdate(tag: tag, zip: zip,
                                   notes: json["body"] as? String ?? "")
            }
        }.resume()
    }

    private func confirmUpdate(tag: String, zip: URL, notes: String) {
        let a = NSAlert()
        a.messageText = "Đã có bản \(tag)"
        var text = "Bạn đang dùng \(currentVersion). Tải về và cài đặt ngay?"
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n\n" + String(trimmed.prefix(400)) }
        a.informativeText = text
        a.addButton(withTitle: "Cập nhật")
        a.addButton(withTitle: "Để sau")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        updateTag = tag
        showUpdatePanel("Đang tải bản \(tag)…")
        let session = URLSession(configuration: .default, delegate: self,
                                 delegateQueue: nil)
        updateTask = session.downloadTask(with: zip)
        updateTask?.resume()
    }

    private func showUpdatePanel(_ text: String) {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Cập nhật Messenger"
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 68, width: 340, height: 18)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 44, width: 340, height: 16))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let cancel = NSButton(title: "Huỷ", target: self,
                              action: #selector(cancelUpdate(_:)))
        cancel.frame = NSRect(x: 280, y: 8, width: 80, height: 28)
        cancel.bezelStyle = .rounded
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        updatePanel = panel
        updateBar = bar
        updateLabel = label
    }

    private func closeUpdatePanel() {
        updatePanel?.orderOut(nil)
        updatePanel = nil
        updateBar = nil
        updateLabel = nil
        updateTask = nil
    }

    @objc func cancelUpdate(_ sender: Any?) {
        updateTask?.cancel()
        closeUpdatePanel()
    }

    private func failUpdate(_ reason: String) {
        closeUpdatePanel()
        alert("Cập nhật thất bại", reason)
    }

    // MARK: Update — download delegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let done = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            guard let bar = self?.updateBar else { return }
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = done
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error, (error as NSError).code != NSURLErrorCancelled
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.failUpdate(error.localizedDescription)
        }
    }

    /// The temp file is gone once this returns, so the zip is moved out first.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("messenger-update-" + UUID().uuidString)
        let zip = stage.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: stage,
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zip)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.failUpdate(error.localizedDescription)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.install(zip: zip, stage: stage)
        }
    }

    // MARK: Update — install

    /// Runs a tool and returns its combined output, or nil if it exited non-zero.
    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    /// codesign writes its description to stderr; `run` folds both streams.
    private func signingAuthority(of app: URL) -> String? {
        guard let out = run("/usr/bin/codesign", ["-dvv", app.path]) else { return nil }
        return out.split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
    }

    private func install(zip: URL, stage: URL) {
        updateLabel?.stringValue = "Đang kiểm tra bản tải về…"
        updateBar?.isIndeterminate = true
        updateBar?.startAnimation(nil)

        func abort(_ why: String) {
            try? FileManager.default.removeItem(at: stage)
            failUpdate(why)
        }

        let unpacked = stage.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) != nil else {
            abort("Không giải nén được file tải về."); return
        }

        // The app may sit at the top level or one folder down.
        let fm = FileManager.default
        var found: URL?
        if let e = fm.enumerator(at: unpacked, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent == "Messenger.app" {
                found = url; break
            }
        }
        guard let newApp = found else {
            abort("Không tìm thấy Messenger.app trong file tải về."); return
        }

        // Downloaded code replaces code that is already running, so require the
        // signature to be intact and to come from the same signer as this build.
        run("/usr/bin/xattr", ["-cr", newApp.path])
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) != nil
        else {
            abort("Chữ ký của bản tải về không hợp lệ."); return
        }
        let mine = signingAuthority(of: Bundle.main.bundleURL)
        let theirs = signingAuthority(of: newApp)
        guard mine == nil || mine == theirs else {
            abort("Bản tải về được ký bởi \(theirs ?? "một bên khác"), "
                  + "không khớp với \(mine!) của bản đang chạy."); return
        }

        let dest = Bundle.main.bundleURL
        let helper = stage.appendingPathComponent("swap.sh")
        // The bundle cannot overwrite itself while running, so a detached script
        // waits for this process to exit, swaps it, and launches the new copy.
        // The old bundle is kept aside until the copy succeeds.
        let script = """
        #!/bin/sh
        DEST=\(shq(dest.path))
        SRC=\(shq(newApp.path))
        OLD="$DEST.old"
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
          sleep 0.2
        done
        sleep 0.5
        rm -rf "$OLD"
        mv "$DEST" "$OLD" 2>/dev/null
        if cp -R "$SRC" "$DEST"; then
          rm -rf "$OLD"
          /usr/bin/xattr -cr "$DEST"
        else
          rm -rf "$DEST"
          mv "$OLD" "$DEST"
        fi
        /usr/bin/open "$DEST"
        rm -rf \(shq(stage.path))
        """
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
        } catch {
            abort(error.localizedDescription); return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper.path]
        do { try p.run() } catch {
            abort("Không chạy được bước cài đặt."); return
        }
        updateLabel?.stringValue = "Đang cài bản \(updateTag), app sẽ mở lại…"
        NSApp.terminate(nil)
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
        appMenu.addItem(item("Kiểm tra cập nhật…", #selector(checkForUpdate(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Gửi thông báo thử", #selector(testNotification(_:)), ""))
        let banners = item("Hiện thông báo banner", #selector(toggleBanners(_:)), "")
        banners.state = bannersEnabled ? .on : .off
        appMenu.addItem(banners)
        let sound = item("Phát âm thanh thông báo", #selector(toggleSound(_:)), "")
        sound.state = soundEnabled ? .on : .off
        appMenu.addItem(sound)
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
