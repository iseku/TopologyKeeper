#!/usr/bin/env bash
# 构建全部 target。
#
# 带上 Swift Testing 的框架搜索路径，这样 `--build-tests` 也能直接工作
# （本机无完整 Xcode，Testing.framework 只在 CommandLineTools 的非常规位置）。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# 仅在构建测试时才引入 Swift Testing 的框架路径。
# 否则 release 版的 App 会被链接上 Testing.framework —— 那是测试专用库，
# 不该进入交付产物（会产生 CLT 路径的 rpath 依赖）。
WANT_TESTS=0
for arg in "$@"; do
    [[ "$arg" == "--build-tests" ]] && WANT_TESTS=1
done

FW="$TK_CLT_FRAMEWORKS"
EXTRA=()
if [[ "$WANT_TESTS" == "1" && -d "$FW/Testing.framework" ]]; then
    EXTRA=(-Xswiftc -F -Xswiftc "$FW"
           -Xlinker -F -Xlinker "$FW"
           -Xlinker -framework -Xlinker Testing
           -Xlinker -rpath -Xlinker "$FW")
fi

cd "$TK_ROOT"
# 注意：macOS 自带 bash 3.2，配合 `set -u` 时空数组展开会报
# "unbound variable"，因此用 ${arr[@]+"${arr[@]}"} 这种兼容写法。
swift build "${TK_SPM_ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
