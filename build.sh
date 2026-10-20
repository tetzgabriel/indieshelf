#!/bin/sh
# Builds indieshelf.app next to this script. Needs only the Xcode command line tools.
set -e
cd "$(dirname "$0")"

APP=indieshelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# One binary for both Apple Silicon and Intel Macs.
swiftc -O -target arm64-apple-macos14 -o "$APP/indieshelf-arm64" main.swift
swiftc -O -target x86_64-apple-macos14 -o "$APP/indieshelf-x86_64" main.swift
lipo -create "$APP/indieshelf-arm64" "$APP/indieshelf-x86_64" -output "$APP/Contents/MacOS/indieshelf"
rm "$APP/indieshelf-arm64" "$APP/indieshelf-x86_64"
strip -x "$APP/Contents/MacOS/indieshelf"  # drop debug symbols: about 25% smaller, same behavior

# The app icon is drawn in code too (icon.swift).
swiftc -O -o "$APP/make-icon" icon.swift
"$APP/make-icon" "$APP/Contents/Resources" >/dev/null
rm "$APP/make-icon"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>indieshelf</string>
	<key>CFBundleIdentifier</key><string>io.github.tetzgabriel.indieshelf</string>
	<key>CFBundleExecutable</key><string>indieshelf</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.3</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
