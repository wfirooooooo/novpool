#!/bin/zsh
# 运行 NovPoolKit 全部单元测试。
#
# 额外参数会透传给 `swift test`，例如在无 GUI 会话 / 受限沙盒环境中：
#   scripts/test.sh --disable-sandbox --scratch-path /tmp/novpool-build
#
# 仓库若在 Documents / iCloud / FileProvider 目录下，本地 .build 签名常因
# Finder 扩展属性失败；默认把 scratch 放到 /private/tmp，可用 NOVPOOL_SCRATCH 覆盖。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# 受限沙盒里 ~/Library 不可写，把编译缓存重定向到仓库内，避免 SwiftPM 报 readonly database。
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/modulecache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$repo_root/.build/modulecache}"

extra=()
if [[ "$*" != *"--scratch-path"* ]]; then
  extra+=(--disable-sandbox --scratch-path "${NOVPOOL_SCRATCH:-/private/tmp/novpool-build}")
fi

exec swift test --package-path "$repo_root/Packages/NovPoolKit" "${extra[@]}" "$@"
