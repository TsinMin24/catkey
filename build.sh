#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MagicKey"
BUILD_DIR="$SCRIPT_DIR/build"
SOURCES_DIR="$SCRIPT_DIR/Sources"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE="$SCRIPT_DIR/module-cache"

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
    -module-cache-path "$MODULE_CACHE" \
    -Xfrontend -interface-compiler-version -Xfrontend 6.3 \
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
    "$SOURCES_DIR/PushToTalkManager.swift" \
    "$SOURCES_DIR/AppToggleManager.swift" \
    "$SOURCES_DIR/KeyBinding.swift" \
    "$SOURCES_DIR/SettingsView.swift" \
    "$SOURCES_DIR/VoiceInputManager.swift" \
    "$SOURCES_DIR/ASRSupport.swift" \
    "$SOURCES_DIR/QwenASR.swift" \
    "$SOURCES_DIR/MiMoASR.swift" \
    "$SOURCES_DIR/LogManager.swift" \
    "$SOURCES_DIR/LogPanel.swift" \
    -Xlinker -rpath -Xlinker /usr/lib/swift

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 用稳定的自签名证书签名，权限（辅助功能/输入监控/麦克风）授权一次后重建不失效
SIGN_KEYCHAIN="$HOME/Library/Keychains/MagicKeySigning.keychain-db"
SIGN_PASS_FILE="$HOME/.config/magickey/signing.keychain.pass"
SIGN_IDENTITY="MagicKey Local Signing"

if [ -f "$SIGN_PASS_FILE" ]; then
    SIGN_PASS=$(cat "$SIGN_PASS_FILE")
    security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"
    # Desktop 被 iCloud 同步时会不断往包里写 fileprovider/FinderInfo 属性，
    # codesign 会拒绝这类“detritus”。清属性后重试几次，再校验签名。
    SIGNED=0
    for attempt in 1 2 3 4 5; do
        xattr -cr "$APP_BUNDLE" 2>/dev/null
        if codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP_BUNDLE" 2>/dev/null; then
            if codesign --verify --strict "$APP_BUNDLE" 2>/dev/null; then
                SIGNED=1
                break
            fi
        fi
        sleep 1
    done
    if [ "$SIGNED" = "1" ]; then
        echo "已签名: $SIGN_IDENTITY"
    else
        echo "签名失败，请重试 build.sh"
        exit 1
    fi
else
    echo "警告: 未找到签名配置 $SIGN_PASS_FILE，跳过签名"
fi

# === 安装到 /Applications ===
# 源码/构建目录若被 iCloud/FileProvider 接管，签名后系统会往包里写回 FinderInfo、
# fileprovider 等属性，导致 codesign 校验失败；签名一失效，TCC 就不会把辅助功能/
# 输入监控的授权落到这个 App 上。所以装到本地磁盘后再清一次属性并重签。
INSTALL_APP="/Applications/MagicKey.app"
if [ "${1:-}" = "--no-install" ]; then
    echo "跳过安装（--no-install）"
elif [ ! -w /Applications ]; then
    echo "跳过安装：/Applications 不可写"
else
    WAS_RUNNING=0
    if pgrep -f "$INSTALL_APP/Contents/MacOS/MagicKey" >/dev/null 2>&1; then
        WAS_RUNNING=1
        pkill -f "$INSTALL_APP/Contents/MacOS/MagicKey" || true
        sleep 1
    fi
    rm -rf "$INSTALL_APP"
    ditto "$APP_BUNDLE" "$INSTALL_APP"
    xattr -cr "$INSTALL_APP" 2>/dev/null
    if [ -f "$SIGN_PASS_FILE" ]; then
        security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN" >/dev/null
        codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$INSTALL_APP"
    fi
    if codesign --verify --strict "$INSTALL_APP" 2>/dev/null; then
        echo "已安装并校验签名: $INSTALL_APP"
    else
        echo "安装后签名校验失败: $INSTALL_APP"
        exit 1
    fi
    if [ "$WAS_RUNNING" = "1" ]; then
        open "$INSTALL_APP"
        echo "已重启 MagicKey"
    fi
fi

echo ""
echo "=== 编译完成 ==="
echo "构建产物: $APP_BUNDLE"
echo "安装位置: $INSTALL_APP"
echo ""
echo "如需只构建不安装: ./build.sh --no-install"
echo ""
echo "首次运行需要授予权限:"
echo "  系统设置 → 隐私与安全性 → 辅助功能 / 输入监控 / 麦克风 → 勾选 MagicKey"
