#!/bin/bash
# Build + install Messenger.app vào ~/Applications
set -e
cd "$(dirname "$0")"
APP="build/Messenger.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework WebKit \
  -o "$APP/Contents/MacOS/Messenger" main.swift
chmod -R u+w "$APP"
xattr -cr "$APP"
codesign --force --deep --sign "Tide Local Dev" "$APP"
# A hard kill drops the cookies WebKit has not flushed yet, which signs the
# app out; ask it to quit and only force it if it will not go.
osascript -e 'quit app id "io.athr.messenger-web"' 2>/dev/null || true
for _ in $(seq 30); do
  pgrep -f "Applications/Messenger.app/Contents/MacOS/Messenger" >/dev/null || break
  sleep 0.3
done
pkill -f "Applications/Messenger.app/Contents/MacOS/Messenger" || true
rm -rf ~/Applications/Messenger.app
cp -R "$APP" ~/Applications/Messenger.app
echo "OK -> ~/Applications/Messenger.app"
