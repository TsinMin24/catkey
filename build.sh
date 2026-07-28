#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MagicKey"
BUILD_DIR="$SCRIPT_DIR/build"
SOURCES_DIR="$SCRIPT_DIR/Sources"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "=== 编译 Magic Key ==="

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$SOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# 生成像素猫图标
if [ ! -f "$SCRIPT_DIR/cat_icon.icns" ]; then
    swift "$SCRIPT_DIR/gen_icon.swift" > /dev/null 2>&1
    iconutil -c icns "$SCRIPT_DIR/cat_icon.iconset" -o "$SCRIPT_DIR/cat_icon.icns" > /dev/null 2>&1
fi
cp "$SCRIPT_DIR/cat_icon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "正在编译..."
swiftc \
    -target arm64-apple-macosx13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework Network \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework CryptoKit \
    -lz \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SOURCES_DIR/MagicKeyApp.swift" \
    "$SOURCES_DIR/AppDelegate.swift" \
    "$SOURCES_DIR/HotkeyManager.swift" \
    "$SOURCES_DIR/AppToggleManager.swift" \
    "$SOURCES_DIR/KeyBinding.swift" \
    "$SOURCES_DIR/SettingsView.swift" \
    "$SOURCES_DIR/VoiceInputManager.swift" \
    "$SOURCES_DIR/LogManager.swift" \
    "$SOURCES_DIR/LogWindow.swift" \
    -Xlinker -rpath -Xlinker /usr/lib/swift

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "=== 编译完成 ==="
echo "应用位置: $APP_BUNDLE"
echo ""
echo "运行方式:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "首次运行需要授予辅助功能权限:"
echo "  系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MagicKey"
