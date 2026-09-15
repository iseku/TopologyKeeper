#!/usr/bin/env bash
# 组装 TopologyKeeper.app。
#
# 本机没有完整 Xcode，无法用 xcodebuild 产出 .app，
# 因此这里手工组装 bundle。
#
# 默认产出**通用二进制**（arm64 + x86_64）。
#
# 为什么不用 `swift build --arch arm64 --arch x86_64`：多架构构建会让 SwiftPM
# 切换到 xcbuild 后端，而 xcbuild 只随完整 Xcode 提供 —— 本机只有 CommandLineTools，
# 会直接报 "xcbuild executable at /Library/Developer/SharedFrameworks/... does not exist"。
# 所以改为**分别构建两个单架构、再用 lipo 合并**：本地与 CI 因此走完全相同的路径，
# 也不额外要求 Xcode 版本。
#
# 用法:
#   Scripts/build_app.sh              # release 构建（通用二进制）
#   Scripts/build_app.sh --debug      # debug 构建
#   Scripts/build_app.sh --native     # 只构建本机架构（本地迭代时省一半时间）
#   Scripts/build_app.sh --install    # 构建后复制到 /Applications
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

CONFIG="release"
INSTALL=0
UNIVERSAL=1
for arg in "$@"; do
    case "$arg" in
        --debug)     CONFIG="debug" ;;
        --install)   INSTALL=1 ;;
        --universal) UNIVERSAL=1 ;;
        --native)    UNIVERSAL=0 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

APP_NAME="TopologyKeeper"
DIST="$TK_ROOT/Dist"
APP="$DIST/$APP_NAME.app"
BUNDLE_BIN="$APP/Contents/MacOS/$APP_NAME"

# 注意：.build/spm/<config> 只是指向「最近一次构建所用架构」的符号链接，
# 多架构时不能依赖它，必须用 <arch>-apple-macosx 显式路径。
spm_bin() { echo "$TK_ROOT/.build/spm/$1-apple-macosx/$CONFIG/$APP_NAME"; }

if [[ "$UNIVERSAL" == "1" ]]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

echo "==> 1/5 编译（${CONFIG}；架构：${ARCHS[*]}）"
SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "    - $arch"
    "$TK_ROOT/Scripts/build.sh" -c "$CONFIG" --arch "$arch" --product "$APP_NAME"
    slice="$(spm_bin "$arch")"
    if [[ ! -x "$slice" ]]; then
        echo "❌ 找不到 $arch 的可执行文件: $slice" >&2
        exit 1
    fi
    SLICES+=("$slice")
done

echo "==> 2/5 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ ${#SLICES[@]} -gt 1 ]]; then
    lipo -create ${SLICES[@]+"${SLICES[@]}"} -output "$BUNDLE_BIN"
    echo "    架构: $(lipo -archs "$BUNDLE_BIN")"
else
    cp "${SLICES[0]}" "$BUNDLE_BIN"
    echo "    架构: $(lipo -archs "$BUNDLE_BIN")"
fi
chmod +x "$BUNDLE_BIN"

cp "$TK_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$TK_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$TK_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    echo "    图标: AppIcon.icns"
else
    echo "    ⚠️  未找到 AppIcon.icns，将使用系统默认图标" >&2
fi

# SwiftPM 产物默认带 rpath 指向 .build，脱离后可能找不到动态库；
# TopologyKeeper 只依赖系统框架，这里用 otool 检查一遍更稳妥。
if command -v otool >/dev/null 2>&1; then
    if otool -L "$BUNDLE_BIN" | grep -q "\.build/spm"; then
        echo "⚠️  可执行文件仍引用 .build 内的库，可能无法独立运行：" >&2
        otool -L "$BUNDLE_BIN" | grep "\.build/spm" >&2
    fi
fi

# 清理扩展属性，避免签名失败
xattr -cr "$APP" 2>/dev/null || true

echo "==> 3/5 ad-hoc 自签名（本机无开发者身份，只能用 ad-hoc）"
# 必须放在 lipo 合并之后：合并会破坏各 slice 原有的签名
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> 4/5 打包 dmg"
# dmg 固定命名（不带版本号），配合 GitHub /releases/latest/download 永久链接，
# README 无需随版本更新；版本信息由 Release 的 tag 承载
#
# 必须用 `hdiutil create -srcfolder`，**不要**换成 `hdiutil makehybrid`。
# makehybrid 会给镜像里的每个条目写入 FinderInfo，挂载后还原成
# com.apple.FinderInfo 扩展属性，于是 dmg 里的 App 通不过
# `codesign --verify --deep --strict`。注意打包前的 Dist/ 目录是干净的，
# 这个污染只有在挂载点上才查得出来（Scripts/verify_app.sh 会拦住它）。
#
# 该形式需要挂载一块可写临时镜像，所以在挂载受限的环境（受限沙箱、部分容器）
# 会失败，并报出误导性的 "create failed - 目录非空"。遇到就换到不受限的环境构建，
# 不要为了绕开它改回 makehybrid。
DMG="$DIST/$APP_NAME.dmg"
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
