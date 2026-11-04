#!/bin/zsh
# Builds "YT Wallpaper.app" and installs it to /Applications.
set -e
cd "${0:A:h}"
APP="build/YT Wallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 main.swift -o "$APP/Contents/MacOS/YTWallpaper"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>YT Wallpaper</string>
  <key>CFBundleIdentifier</key><string>com.jake.ytwallpaper</string>
  <key>CFBundleExecutable</key><string>YTWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
pkill -x YTWallpaper || true
rm -rf "/Applications/YT Wallpaper.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/YT Wallpaper.app"
