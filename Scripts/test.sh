#!/usr/bin/env bash
# 运行单元测试。
#
# 为什么不能直接 `swift test`：本机无完整 Xcode，XCTest 不存在，
# 测试用 Swift Testing；而 Testing.framework 只存在于 CommandLineTools 的
# 非常规路径下，需要显式 -F（编译期查找）与 -rpath（运行期加载）。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

FW="$TK_CLT_FRAMEWORKS"
if [[ ! -d "$FW/Testing.framework" ]]; then
    echo "❌ 找不到 Testing.framework: $FW" >&2
    echo "   若已安装完整 Xcode，请改用: swift test" >&2
    exit 1
fi

cd "$TK_ROOT"
swift test "${TK_SPM_ARGS[@]}" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -framework -Xlinker Testing \
    -Xlinker -rpath -Xlinker "$FW" \
    "$@"
