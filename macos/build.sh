#!/bin/zsh
# Builds Superlocal.app (native macOS window + background server with Claude bridge)
# and installs it to ~/Applications. Usage: macos/build.sh
set -euo pipefail
here="${0:A:h}"
repo="${here:h}"
out="$HOME/Applications/Superlocal.app"
bun="$(command -v bun)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/Superlocal" "$here/Superlocal.swift" -framework AppKit -framework WebKit

swift "$here/make-icon.swift" "$work/icon.png"
iconset="$work/Superlocal.iconset"; mkdir "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$work/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$work/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$work/Superlocal.icns"

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$work/Superlocal" "$out/Contents/MacOS/Superlocal"
cp "$work/Superlocal.icns" "$out/Contents/Resources/Superlocal.icns"
cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Superlocal</string>
  <key>CFBundleDisplayName</key><string>Superlocal</string>
  <key>CFBundleIdentifier</key><string>local.superlocal.app</string>
  <key>CFBundleExecutable</key><string>Superlocal</string>
  <key>CFBundleIconFile</key><string>Superlocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>SuperlocalRepo</key><string>$repo</string>
  <key>SuperlocalBun</key><string>$bun</string>
</dict></plist>
PLIST
codesign --force --sign - "$out" >/dev/null 2>&1 || true
echo "Installed $out"
