#!/usr/bin/env bash
# 校验 Dist/ 下的发布产物是否可交付。
#
# 本地构建与两个 workflow（ci.yml / release.yml）都调用它，
# 避免出现「本地校验一套、CI 校验另一套」。
#
# 用法：Scripts/verify_app.sh            # 校验 Dist/ 下现有产物
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

APP_NAME="TopologyKeeper"
DIST="$TK_ROOT/Dist"
APP="$DIST/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
DMG="$DIST/$APP_NAME.dmg"

fail() { echo "❌ $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "找不到 $APP —— 先跑 Scripts/build_app.sh"
[[ -f "$DMG" ]] || fail "找不到 $DMG —— 先跑 Scripts/build_app.sh"

echo "== 1/4 可执行文件架构（必须同时含 arm64 与 x86_64）=="
ARCHS="$(lipo -archs "$BIN")"
echo "    $ARCHS"
case " $ARCHS " in
    *" arm64 "*)  ;;
    *) fail "产物缺少 arm64 架构" ;;
esac
case " $ARCHS " in
    *" x86_64 "*) ;;
    *) fail "产物缺少 x86_64 架构" ;;
esac

echo "== 2/4 最低系统版本 =="
# 通用二进制会为每个 slice 各输出一段
vtool -show-build "$BIN" 2>&1 | grep -E "architecture|platform|minos|sdk" | sed 's/^/    /'

echo "== 3/4 代码签名 =="
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier)=" | sed 's/^/    /' || true

echo "== 4/4 dmg 挂载内容 =="
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/tk-verify.XXXXXX")"
cleanup() {
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach -nobrowse -quiet "$DMG" -mountpoint "$MOUNT"
ls -la "$MOUNT" | sed 's/^/    /'
[[ -L "$MOUNT/Applications" ]] || fail "dmg 内缺少 /Applications 拖放快捷方式"
[[ -d "$MOUNT/$APP_NAME.app" ]] || fail "dmg 内缺少 $APP_NAME.app"

# 必须复查**挂载后**的 App，而不是只查打包前的 Dist/。
# 打包方式会给镜像里的每个条目带上 FinderInfo 之类的 detritus，这类污染
# 只在挂载后才显现（打包前的目录是完全干净的），会让 --strict 校验失败。
# 我们曾用 `hdiutil makehybrid` 出包时踩到过，因此这里作为硬性门槛。
echo "    --- dmg 内 App 的严格签名校验 ---"
if ! codesign --verify --deep --strict --verbose=2 "$MOUNT/$APP_NAME.app" 2>&1 | sed 's/^/    /'; then
    fail "dmg 内的 App 未通过严格签名校验 —— 很可能被打包过程污染（例如带上了 com.apple.FinderInfo）"
fi

if xattr -lr "$MOUNT/$APP_NAME.app" 2>/dev/null | grep -q .; then
    echo "    ⚠️  dmg 内 App 带有扩展属性："
    xattr -lr "$MOUNT/$APP_NAME.app" 2>/dev/null | sed 's/^/      /'
    fail "dmg 内的 App 不应带扩展属性（detritus）"
fi

echo
echo "✅ 产物校验通过"
ls -l "$DMG" | sed 's/^/    /'
shasum -a 256 "$DMG" | sed 's/^/    /'
