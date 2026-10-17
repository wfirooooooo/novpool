#!/bin/zsh
# 组装可直接双击运行的 NovPool.app。
#
# 用法：
#   scripts/build-app.sh                 # 宿主架构 Release 构建
#   NOVPOOL_UNIVERSAL=1 scripts/build-app.sh   # arm64 + x86_64 通用二进制
#   scripts/build-app.sh --run           # 构建完成后直接启动
#   NOVPOOL_SKIP_SELFTEST=1 scripts/build-app.sh   # 跳过构建后的启动自检
#   scripts/build-app.sh -- --disable-sandbox --scratch-path /tmp/novpool-build
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# 产物目录可覆盖：仓库在受 FileProvider（iCloud / 坚果云等）同步的目录下时，
# 同步守护进程会在 xattr 清理与 codesign 之间把 com.apple.FinderInfo 写回去，
# 把产物放到未同步的路径（例如 $HOME/Applications）可以彻底避开这个竞态。
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

# 受限沙盒 / CI 里 dsymutil 会被内核拒绝（Operation not permitted），
# 此时用 NOVPOOL_SKIP_DSYM=1 跳过 dSYM 生成，不影响可执行文件本身。
dsym_args=()
if [[ "${NOVPOOL_SKIP_DSYM:-0}" == "1" ]]; then
  dsym_args=(-debug-info-format none)
fi

echo "==> 编译 Release 产物"
cd "$repo_root"
swift build -c release --product NovPool "${arch_args[@]}" "${dsym_args[@]}" "${swift_args[@]}"

bin_path="$(swift build -c release --product NovPool "${arch_args[@]}" "${dsym_args[@]}" "${swift_args[@]}" --show-bin-path)"
echo "==> 组装 $app_dir"

if [[ -d "$app_dir" ]]; then
  # 只清理我们自己的构建产物目录，不使用破坏性通配删除。
  rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

cp "$bin_path/NovPool" "$app_dir/Contents/MacOS/NovPool"
cp "$repo_root/NovPoolApp/Info.plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# 图标资源（黑洞图案 + app 图标）
cp "$repo_root/NovPoolApp/Assets/blackhole.png" "$app_dir/Contents/Resources/blackhole.png"
cp "$repo_root/NovPoolApp/Assets/blackhole-template.png" "$app_dir/Contents/Resources/blackhole-template.png"
cp "$repo_root/NovPoolApp/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

# 把 dSYM 放在 app 旁边：崩溃报告才能被符号化到具体行号（排查启动/渲染崩溃的关键）。
if [[ -d "$bin_path/NovPool.dSYM" ]]; then
  rm -rf "${app_dir}.dSYM"
  cp -R "$bin_path/NovPool.dSYM" "${app_dir}.dSYM"
  echo "==> 已保留符号文件：${app_dir}.dSYM"
fi

echo "==> 清除 FileProvider / Finder 残留扩展属性（codesign 拒绝带 FinderInfo 的包）"
# 同步目录里 xattr 会被反复写回，因此清属性 + 签名整体重试若干次。
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
    echo "签名失败：产物位于受同步保护的目录（$app_dir）。"
    echo "可用 NOVPOOL_APP_DIR=\"\$HOME/Applications\" 把产物放到未同步路径后重试。"
    exit 1
  fi
  sign_attempt=$((sign_attempt + 1))
  echo "==> 签名被同步进程打断，重试第 $sign_attempt 次"
  sleep 1
done

codesign -dv --entitlements :- "$app_dir" 2>&1 | sed -n '1,40p'
echo "==> 完成：$app_dir"

# 构建后用一次性数据目录跑启动自检：这类「装完就崩」的问题必须在构建阶段暴露，
# 而不是等到用户双击后「什么都没发生」。默认开启，可用 NOVPOOL_SKIP_SELFTEST=1 关闭。
if [[ "${NOVPOOL_SKIP_SELFTEST:-0}" != "1" ]]; then
  selftest_dir="$(mktemp -d "${TMPDIR:-/tmp}/novpool-selftest.XXXXXX")"
  echo "==> 启动自检（数据目录：$selftest_dir）"
  if NOVPOOL_DATA_DIR="$selftest_dir" "$app_dir/Contents/MacOS/NovPool" --selftest; then
    echo "==> 自检通过"
  else
    echo "==> 自检未通过，请检查上方输出（app 仍已生成，可手动排查）"
  fi
  rm -rf "$selftest_dir"
fi

if [[ "$run_after_build" == "1" ]]; then
  open "$app_dir"
fi
