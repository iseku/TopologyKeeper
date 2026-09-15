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

echo
echo "✅ 产物校验通过"
ls -l "$DMG" | sed 's/^/    /'
shasum -a 256 "$DMG" | sed 's/^/    /'
