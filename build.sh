#!/bin/zsh
# Builds Ebb in release mode and installs it to ~/Applications.
# Relaunches the app if it was running.
set -euo pipefail
cd "${0:A:h}"

app_name="Ebb"
executable="Ebb"
version="0.1.0"
install_path="$HOME/Applications/$app_name.app"

swift build -c release
binary="$(swift build -c release --show-bin-path)/$executable"

stage="$(mktemp -d)/$app_name.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$binary" "$stage/Contents/MacOS/$executable"

# The Icon Composer icon needs Xcode's actool; without it, the prebuilt .icns stands in.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Resources/Ebb.icon --compile "$stage/Contents/Resources" \
        --platform macosx --minimum-deployment-target 26.0 --app-icon Ebb \
        --output-partial-info-plist "$(mktemp)" >/dev/null
else
    echo "actool not found; using Resources/Ebb.icns"
    cp Resources/Ebb.icns "$stage/Contents/Resources/Ebb.icns"
fi
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$stage/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.lucasnsaraujo.ebb</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundleDisplayName</key>
    <string>$app_name</string>
    <key>CFBundleExecutable</key>
    <string>$executable</string>
    <key>CFBundleIconFile</key>
    <string>Ebb</string>
    <key>CFBundleIconName</key>
    <string>Ebb</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$stage"

# Matches the installed copy by path, so other builds named Ebb keep running.
installed_binary="$install_path/Contents/MacOS/$executable"
was_running=false
if pgrep -fq "^$installed_binary"; then
    was_running=true
    pkill -f "^$installed_binary"
    while pgrep -fq "^$installed_binary"; do sleep 0.2; done
fi

mkdir -p "$HOME/Applications"
rm -rf "$install_path"
mv "$stage" "$install_path"
echo "Installed $install_path"

if $was_running; then
    open "$install_path"
fi
