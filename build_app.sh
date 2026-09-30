#!/bin/bash
# Builds WavNotes.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/WavNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/WavNotes "$APP/Contents/MacOS/WavNotes"
cp -R .build/release/whisper.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/WavNotes"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WavNotes</string>
    <key>CFBundleDisplayName</key><string>WavNotes</string>
    <key>CFBundleIdentifier</key><string>local.wavnotes</string>
    <key>CFBundleExecutable</key><string>WavNotes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>WAV Audio</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.microsoft.waveform-audio</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
