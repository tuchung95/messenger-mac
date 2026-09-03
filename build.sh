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
pkill -f "Applications/Messenger.app/Contents/MacOS/Messenger" || true
rm -rf ~/Applications/Messenger.app
cp -R "$APP" ~/Applications/Messenger.app
echo "OK -> ~/Applications/Messenger.app"
