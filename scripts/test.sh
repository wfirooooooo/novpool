#!/bin/zsh
# Run all NovPoolKit unit tests.
#
# Extra args are forwarded to `swift test`, e.g. in a headless / restricted sandbox:
#   scripts/test.sh --disable-sandbox --scratch-path /tmp/novpool-build
#
# If the repo lives under Documents / iCloud / FileProvider, local .build signing often fails
# because of Finder xattrs; scratch defaults to /private/tmp (override with NOVPOOL_SCRATCH).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# In restricted sandboxes ~/Library is not writable; keep compile caches inside the repo.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/modulecache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$repo_root/.build/modulecache}"

extra=()
if [[ "$*" != *"--scratch-path"* ]]; then
  extra+=(--disable-sandbox --scratch-path "${NOVPOOL_SCRATCH:-/private/tmp/novpool-build}")
fi

exec swift test --package-path "$repo_root/Packages/NovPoolKit" "${extra[@]}" "$@"
