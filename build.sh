#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f Assets/clips.json || ! -f Assets/pairs.json || ! -d Assets/Clips ]]; then
    printf '缺少 Assets/clips.json、Assets/pairs.json 或 Assets/Clips。\n先运行：Tools/venv/bin/python Tools/build-clips.py\n' >&2
    exit 1
fi

mkdir -p build
swiftc -O -target arm64-apple-macosx14.0 -framework AppKit -framework AVFoundation Sources/main.swift -o build/LeiYuPet

for role in lei yu; do
    if [[ "$role" == lei ]]; then name="雷军桌宠"; else name="余承东桌宠"; fi
    app="build/$name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp build/LeiYuPet "$app/Contents/MacOS/LeiYuPet"
    cp "Assets/$role.png" "$app/Contents/Resources/face.png"
    cp "Assets/$role.icns" "$app/Contents/Resources/AppIcon.icns"
    cp Assets/clips.json "$app/Contents/Resources/clips.json"
    cp Assets/pairs.json "$app/Contents/Resources/pairs.json"
    cp -R Assets/Clips "$app/Contents/Resources/Clips"
    cp LICENSE LICENSE-SunPet "$app/Contents/Resources/"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LeiYuPet</string>
<key>CFBundleIdentifier</key><string>local.leiyupets.$role</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>PetRole</key><string>$role</string>
</dict></plist>
PLIST
    codesign --force --sign - "$app"
    printf '已构建：%s\n' "$app"
done
