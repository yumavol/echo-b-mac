#!/bin/sh
# Builds ECHO-B.app (universal, macOS 14+) and ECHO-B.zip for GitHub releases.
set -e
cd "$(dirname "$0")"
APP="ECHO-B.app"
VERSION="${1:-1.0}"
rm -rf "$APP" ECHO-B.zip
mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos14" -o "EchoB-$arch" EchoB.swift
done
lipo -create -output "$APP/Contents/MacOS/EchoB" EchoB-arm64 EchoB-x86_64
rm EchoB-arm64 EchoB-x86_64
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>EchoB</string>
    <key>CFBundleIdentifier</key><string>local.echob.control</string>
    <key>CFBundleName</key><string>ECHO-B</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/EchoB" --selftest
ditto -c -k --keepParent "$APP" ECHO-B.zip
echo "built $APP and ECHO-B.zip ($VERSION)"
