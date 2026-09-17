#!/usr/bin/env bash
#
# 发版前置钩子 —— 由 `/Users/tony/Work/Projects/release.sh` 在
# **暂存之前、提交之前、打 tag 之前**自动调用，把本次要发布的版本号写进
# `Resources/Info.plist`，避免"tag 是 v0.1.4、App 里还写着 0.1.3"这种脱节。
#
# ## 为什么必须由钩子做，而不是靠人记得改
#
# 本项目的发布流水线是 `.github/workflows/release.yml`：它**检出 tag 的源码**
# 再构建 App ⇒ Info.plist 的值直接决定用户"关于本机"里看到的版本。
# 而 tag 是脚本生成的、Info.plist 是手写的 —— 两者没有任何机制保证一致。
# 发 v0.1.3 时就是"先手动改 Info.plist 提交、再发版"，全靠记性；
# 一次忘记就会出包带旧版本号，而 CI **不会**报错（它不比对这两者）。
#
# ## ★ 为什么不用 PlistBuddy（本轮实测踩到）
#
# `PlistBuddy -c Set` 会**重写整个 plist 文件**：丢掉全部注释、并重排键顺序。
# 本项目的 Info.plist 里有一段按版本维护的注释（0.1.1/0.1.2/0.1.3 各改了什么），
# 是给后人看的版本简史 —— 用 PlistBuddy 跑一次就没了。
# ⇒ 改用**定点文本替换**（只动版本号那两行的 <string>），
#   文件其余部分逐字节保留。回读校验照做（见 交接说明.md §8 坑 #1）。
#
# ## 调用约定（与 release.sh 的契约）
#
#   $1        版本号，形如 `0.1.4` 或 `v0.1.4`（两种都接受）
#   $VERSION  同上（环境变量，便于只读场景）
#   工作目录  仓库根目录
#
# 退出码：0 = 成功（含"无需修改"）；非 0 = 失败，release.sh 会中止发版。
#
# ## 为什么同时改 CFBundleVersion
#
# `CFBundleShortVersionString` 是用户看到的版本；`CFBundleVersion` 是构建号，
# macOS 用它判断"哪个更新"。本项目惯例每发一版 +1（0.1.0→1 … 0.1.3→4）。
# 沿用"读到即 +1"：日期/时间戳方案会让构建号不可读，而本项目没有
# "同版本多构建"的需求。
#
set -euo pipefail

RAW_VERSION="${1:-${VERSION:-}}"

if [ -z "$RAW_VERSION" ]; then
    echo "[pre_release] 用法: pre_release.sh <版本号，如 0.1.4 或 v0.1.4>" >&2
    exit 2
fi

# 归一化并按段校验。
# 不用 sed 校验：BSD sed（本机 /usr/bin/sed）对 (1[0-9]{2}|...) 这类分组
# 支持不可靠，容易写出"在 Linux 上通过、在 macOS 上误判"的规则。
VERSION="${RAW_VERSION#v}"
IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<EOF
$VERSION
EOF
if [ -z "${V_MAJOR:-}" ] || [ -z "${V_MINOR:-}" ] || [ -z "${V_PATCH:-}" ]; then
    echo "[pre_release] 版本号格式不合法: $RAW_VERSION（需要 x.y.z 三段）" >&2
    exit 2
fi
for part in "$V_MAJOR" "$V_MINOR" "$V_PATCH"; do
    if ! printf '%s' "$part" | grep -Eq '^[0-9]+$'; then
        echo "[pre_release] 版本号格式不合法: $RAW_VERSION（每段必须是数字）" >&2
        exit 2
    fi
done
VERSION="${V_MAJOR}.${V_MINOR}.${V_PATCH}"

PLIST="Resources/Info.plist"
if [ ! -f "$PLIST" ]; then
    # 找不到就当作"本项目不需要同步版本号"——但要说清楚，不能静默成功
    echo "[pre_release] 未找到 $PLIST（跳过版本号同步）" >&2
    exit 0
fi

if ! grep -q "<key>CFBundleShortVersionString</key>" "$PLIST"; then
    echo "[pre_release] $PLIST 里没有 CFBundleShortVersionString，无法同步" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[pre_release] 找不到 python3，无法安全改写 plist（不用 PlistBuddy：它会丢注释）" >&2
    exit 1
fi

# 定点替换 + 回读校验 + 幂等，全部交给 python3（正则与文件写入更可控）
python3 - "$PLIST" "$VERSION" <<'PY'
import re, sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

def current_value(src, key):
    m = re.search(r"<key>%s</key>\s*<string>([^<]*)</string>" % re.escape(key), src)
    return m.group(1) if m else None

old_short = current_value(text, "CFBundleShortVersionString")
old_build = current_value(text, "CFBundleVersion")
if old_short is None or old_build is None:
    sys.exit("[pre_release] 缺少 CFBundleShortVersionString 或 CFBundleVersion")

# 构建号：读到整数就 +1；读到非数字从 1 起
try:
    new_build = str(int(old_build) + 1)
except ValueError:
    new_build = "1"

if old_short == version:
    # 幂等：重复运行同一版本（例如上次发版中途取消）不应把构建号一直加上去
    print("[pre_release] Info.plist 已经是 %s（构建号 %s），无需修改" % (version, old_build))
    sys.exit(0)

def replace_value(src, key, value):
    pattern = re.compile(r"(<key>%s</key>\s*<string>)([^<]*)(</string>)" % re.escape(key))
    new_src, n = pattern.subn(lambda m: m.group(1) + value + m.group(3), src, count=1)
    if n != 1:
        sys.exit("[pre_release] 替换 %s 失败（匹配到 %d 处）" % (key, n))
    return new_src

text = replace_value(text, "CFBundleShortVersionString", version)
text = replace_value(text, "CFBundleVersion", new_build)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)

# 回读校验：写成功不等于生效（交接说明.md §8 坑 #1）
with open(path, encoding="utf-8") as fh:
    back = fh.read()
got_short = current_value(back, "CFBundleShortVersionString")
got_build = current_value(back, "CFBundleVersion")
if got_short != version or got_build != new_build:
    sys.exit("[pre_release] 回读校验失败：期望 %s/%s，实际 %s/%s"
             % (version, new_build, got_short, got_build))

print("[pre_release] Info.plist: %s (build %s) → %s (build %s)"
      % (old_short, old_build, version, new_build))
PY
