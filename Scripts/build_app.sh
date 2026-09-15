#!/usr/bin/env bash
# 组装 TopologyKeeper.app。
#
# 本机没有完整 Xcode，无法用 xcodebuild 产出 .app，
# 因此这里手工组装 bundle（《详细设计.md》§11.2）。
#
# 用法:
#   Scripts/build_app.sh              # release 构建
#   Scripts/build_app.sh --debug      # debug 构建
#   Scripts/build_app.sh --install    # 构建后复制到 /Applications
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG="debug" ;;
        --install) INSTALL=1 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

APP_NAME="TopologyKeeper"
DIST="$TK_ROOT/Dist"
APP="$DIST/$APP_NAME.app"
BIN="$TK_ROOT/.build/spm/$CONFIG/$APP_NAME"

echo "==> 1/5 编译（${CONFIG}）"
"$TK_ROOT/Scripts/build.sh" -c "$CONFIG" --product "$APP_NAME"

if [[ ! -x "$BIN" ]]; then
    echo "❌ 找不到可执行文件: $BIN" >&2
    exit 1
fi

echo "==> 2/5 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$TK_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$TK_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$TK_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    echo "    图标: AppIcon.icns"
else
    echo "    ⚠️  未找到 AppIcon.icns，将使用系统默认图标" >&2
fi

# SwiftPM 产物默认带 rpath 指向 .build，脱离后可能找不到动态库；
# TopologyKeeper 只依赖系统框架，这里用 install_name_tool 检查一遍更稳妥。
if command -v otool >/dev/null 2>&1; then
    if otool -L "$APP/Contents/MacOS/$APP_NAME" | grep -q "\.build/spm"; then
        echo "⚠️  可执行文件仍引用 .build 内的库，可能无法独立运行：" >&2
        otool -L "$APP/Contents/MacOS/$APP_NAME" | grep "\.build/spm" >&2
    fi
fi

# 清理扩展属性，避免签名失败
xattr -cr "$APP" 2>/dev/null || true

echo "==> 3/5 ad-hoc 自签名（本机无开发者身份，只能用 ad-hoc）"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> 4/5 打包 dmg"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$TK_ROOT/.build/dmg-staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $DMG"

echo "==> 5/5 完成"
echo "    $APP"
echo "    $DMG"
ls -la "$APP/Contents/MacOS/"

if [[ "$INSTALL" == "1" ]]; then
    echo "==> 复制到 /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "    /Applications/$APP_NAME.app"
    echo "    运行: open -a $APP_NAME"
fi
