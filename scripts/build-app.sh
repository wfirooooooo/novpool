#!/bin/zsh
# Assemble a double-clickable NovPool.app.
#
# Usage:
#   scripts/build-app.sh                 # host-arch Release build
#   NOVPOOL_UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64 universal binary
#   scripts/build-app.sh --run           # launch after build
#   NOVPOOL_SKIP_SELFTEST=1 scripts/build-app.sh   # skip post-build self-check
#   scripts/build-app.sh -- --disable-sandbox --scratch-path /tmp/novpool-build
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# Output dir is overridable: when the repo is under FileProvider sync (iCloud, etc.),
# the sync daemon can rewrite com.apple.FinderInfo between xattr cleanup and codesign.
# Putting the product outside sync (e.g. $HOME/Applications) avoids that race.
app_dir="${NOVPOOL_APP_DIR:-$repo_root/build}/NovPool.app"
run_after_build=0
swift_args=()

for arg in "$@"; do
  case "$arg" in
    --run) run_after_build=1 ;;
    --) ;;
    *) swift_args+=("$arg") ;;
  esac
done

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/modulecache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$repo_root/.build/modulecache}"

arch_args=()
if [[ "${NOVPOOL_UNIVERSAL:-0}" == "1" ]]; then
  arch_args=(--arch arm64 --arch x86_64)
fi

# In restricted sandbox / CI, dsymutil may be denied (Operation not permitted).
# Set NOVPOOL_SKIP_DSYM=1 to skip dSYM generation; the executable is unaffected.
dsym_args=()
if [[ "${NOVPOOL_SKIP_DSYM:-0}" == "1" ]]; then
  dsym_args=(-debug-info-format none)
fi

echo "==> Building Release"
cd "$repo_root"
swift build -c release --product NovPool "${arch_args[@]}" "${dsym_args[@]}" "${swift_args[@]}"

bin_path="$(swift build -c release --product NovPool "${arch_args[@]}" "${dsym_args[@]}" "${swift_args[@]}" --show-bin-path)"
echo "==> Assembling $app_dir"

if [[ -d "$app_dir" ]]; then
  # Only remove our own build product directory.
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

cp "$bin_path/NovPool" "$app_dir/Contents/MacOS/NovPool"
cp "$repo_root/NovPoolApp/Info.plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# Icon assets (lake mark + app icon)
cp "$repo_root/NovPoolApp/Assets/blackhole.png" "$app_dir/Contents/Resources/blackhole.png"
cp "$repo_root/NovPoolApp/Assets/blackhole-template.png" "$app_dir/Contents/Resources/blackhole-template.png"
cp "$repo_root/NovPoolApp/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

# Keep dSYM next to the app so crash reports symbolicate to line numbers.
if [[ -d "$bin_path/NovPool.dSYM" ]]; then
  rm -rf "${app_dir}.dSYM"
  cp -R "$bin_path/NovPool.dSYM" "${app_dir}.dSYM"
  echo "==> Kept symbols: ${app_dir}.dSYM"
fi

echo "==> Clearing FileProvider / Finder xattrs (codesign rejects FinderInfo)"
# Under sync folders, xattrs may be rewritten; retry cleanup + sign a few times.
sign_attempt=1
while true; do
  xattr -cr "$app_dir" 2>/dev/null || true
  if codesign --force --sign - --timestamp=none \
      --entitlements "$repo_root/NovPoolApp/NovPool.entitlements" \
      "$app_dir" 2>&1 | tee /tmp/novpool-codesign.log; then
    if ! grep -q "detritus not allowed" /tmp/novpool-codesign.log; then
      break
    fi
  fi
  if [[ "$sign_attempt" -ge 3 ]]; then
    echo "Signing failed: product is under a sync-protected path ($app_dir)."
    echo "Retry with NOVPOOL_APP_DIR=\"\$HOME/Applications\" to write outside sync."
    exit 1
  fi
  sign_attempt=$((sign_attempt + 1))
  echo "==> Sign interrupted by sync; retry $sign_attempt"
  sleep 1
done

codesign -dv --entitlements :- "$app_dir" 2>&1 | sed -n '1,40p'
echo "==> Done: $app_dir"

# Post-build self-check with a disposable data dir: catch “install then silent crash”
# at build time. Default on; disable with NOVPOOL_SKIP_SELFTEST=1.
if [[ "${NOVPOOL_SKIP_SELFTEST:-0}" != "1" ]]; then
  selftest_dir="$(mktemp -d "${TMPDIR:-/tmp}/novpool-selftest.XXXXXX")"
  echo "==> Launch self-check (data dir: $selftest_dir)"
  if NOVPOOL_DATA_DIR="$selftest_dir" "$app_dir/Contents/MacOS/NovPool" --selftest; then
    echo "==> Self-check passed"
  else
    echo "==> Self-check failed — see output above (app was still produced)"
  fi
  rm -rf "$selftest_dir"
fi

if [[ "$run_after_build" == "1" ]]; then
  open "$app_dir"
fi
