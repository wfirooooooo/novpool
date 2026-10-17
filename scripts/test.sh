#!/bin/zsh
# 运行 NovPoolKit 全部单元测试。
#
# 额外参数会透传给 `swift test`，例如在无 GUI 会话 / 受限沙盒环境中：
#   scripts/test.sh --disable-sandbox --scratch-path /tmp/novpool-build
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# 受限沙盒里 ~/Library 不可写，把编译缓存重定向到仓库内，避免 SwiftPM 报 readonly database。
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/modulecache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$repo_root/.build/modulecache}"

exec swift test --package-path "$repo_root/Packages/NovPoolKit" "$@"
