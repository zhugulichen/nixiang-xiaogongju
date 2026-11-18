#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_KEY="$(pwd -P | shasum -a 256 | cut -c1-16)"
BUILD_ROOT="${QINGZHOU_BUILD_DIR:-$HOME/Library/Caches/QingzhouBuild/$PROJECT_KEY}"
SIGNING_IDENTITY="${QINGZHOU_SIGNING_IDENTITY:-}"
SIGNING_CONFIG="$HOME/Library/Application Support/QingzhouDevelopment/signing-identity.txt"
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$SIGNING_CONFIG" ]; then
    IFS= read -r SIGNING_IDENTITY < "$SIGNING_CONFIG"
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo '固定签名配置为空，请重新配置签名身份。' >&2
        exit 1
    fi
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
swift build --scratch-path "$BUILD_ROOT" -c release
BIN_DIR="$(swift build --scratch-path "$BUILD_ROOT" -c release --show-bin-path)"
STAGING_DIR="$(mktemp -d -t qingzhou-package)"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/清舟.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Qingzhou" "$APP/Contents/MacOS/Qingzhou"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Qingzhou</string>
<key>CFBundleIdentifier</key><string>cn.local.qingzhou</string>
<key>CFBundleName</key><string>清舟</string>
<key>CFBundleDisplayName</key><string>清舟</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.8.1</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppBundlesUsageDescription</key><string>清舟需要在你确认卸载时把所选应用移入废纸篓，并在你选择恢复时放回原位置。</string>
<key>NSAppDataUsageDescription</key><string>清舟需要核对所选应用的数据容器；只有你勾选并确认的项目才会移入废纸篓。</string>
<key>NSAppleEventsUsageDescription</key><string>当你选择通过访达回收或允许在权限不足时重试，并确认应用路径后，清舟可请求访达将所选应用本体移入废纸篓。</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>应用程序</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
</dict></array>
<key>NSHumanReadableCopyright</key><string>清舟 · 本机独立版本</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$PWD/dist"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$PWD/dist/清舟.zip"
printf '已签名安装存档：%s\n' "$PWD/dist/清舟.zip"
printf '展开应用仅用于临时打包，安装后请打开“应用程序”中的清舟。\n'
