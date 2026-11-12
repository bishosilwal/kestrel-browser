#!/bin/bash
# Build Lantern into a runnable .app bundle. No dependencies, no package manager.
set -euo pipefail
cd "$(dirname "$0")"

APP="Lantern.app"
NAME="Lantern"
BUNDLE_ID="com.lantern.browser"
VERSION="1.0"
DEST="${1:-.}"

echo "==> Compiling ($(ls Sources/*.swift | wc -l | tr -d ' ') files)"
rm -rf "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -O -whole-module-optimization -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/$NAME" \
  Sources/*.swift

cp Resources/blocked-domains.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleScriptEnabled</key><false/>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use the microphone.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Generate a simple app icon from an SF Symbol-ish drawing.
if [ -x /usr/bin/python3 ]; then python3 tools/make_icon.py "$APP/Contents/Resources/AppIcon.icns" || true; fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (ad-hoc signing skipped)"
touch "$APP"

if [ "$DEST" != "." ]; then
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/"
  echo "==> Installed to $DEST/$APP"
fi
SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built $APP ($SIZE)"
