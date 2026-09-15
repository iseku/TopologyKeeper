#!/usr/bin/env bash
# 共享构建环境。source 这个文件后再调用 swift。
#
# 为什么需要它：本机只有 CommandLineTools（无完整 Xcode），且文件写入受限，
# 默认的 SwiftPM/swiftc 行为会失败。四个必须的处理：
#
#   1. 模块缓存默认写到 /var/folders/.../C/clang/ModuleCache → 被拒
#      → CLANG_MODULE_CACHE_PATH + SWIFTPM_MODULECACHE_OVERRIDE 重定向到仓库内
#   2. SwiftPM 会把 manifest 编译放进自己的 sandbox-exec
#      → 嵌套沙箱被拒，必须加 --disable-sandbox
#   3. XCTest 不在 CommandLineTools 里 → 测试改用 Swift Testing
#   4. Testing.framework 在 CLT 的非常规位置
#      → 需要 -F 与 -rpath（见 test.sh）
#
# 用法：  source Scripts/env.sh

TK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TK_ROOT

# ── 强制稳定的 locale ──────────────────────────────────────────────
# 为什么必须显式设置：本项目的脚本里有大量中文（提示语、注释里的全角标点），
# 而 **bash 的变量名解析依赖 locale**：
#   * UTF-8 locale 下，`$VAR）` 会把多字节的「）」当成变量名的一部分
#     → 实际变量名成了 `VAR）`，配 `set -u` 直接报 "unbound variable"；
#   * C/POSIX locale 下则正常截断。
# 实测：同一条 `Scripts/build_app.sh --install`
#   在 LC_ALL=en_US.UTF-8 下失败，在 LC_ALL=C 下成功。
# 因此这里统一钉成 C —— 脚本只在定义域内做算术/字符串处理，不需要宽字符。
# 教训：写脚本时变量后若紧跟中文标点，**一律用 ${VAR} 花括号形式**。
export LC_ALL=C
export LANG=C

TK_LOCAL="$TK_ROOT/.build/local"
mkdir -p "$TK_LOCAL/tmp" "$TK_LOCAL/clangcache" "$TK_LOCAL/smcache"

export TMPDIR="$TK_LOCAL/tmp"
export CLANG_MODULE_CACHE_PATH="$TK_LOCAL/clangcache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TK_LOCAL/smcache"

# CLT 提供的 Swift Testing 框架（无 Xcode 时唯一可用的测试框架）
export TK_CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

# SwiftPM 通用参数
export TK_SPM_ARGS=(--disable-sandbox
                    --scratch-path "$TK_ROOT/.build/spm"
                    --cache-path "$TK_ROOT/.build/spm/cache")
