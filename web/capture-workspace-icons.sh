#!/usr/bin/env bash
#
# 已过时——网站当前不再使用本脚本的产物。
# web/assets 里是真机截图，命名为 {ipad,iphone}-{workspace,sessions}-{light,dark}.png，
# 页面按深浅色而不是按语言切换；本脚本仍输出旧的 ipad-icons-{en,zh}.png，
# 跑一遍只会多出页面不加载的文件。要继续用请先按上面的命名改写。
#
# 从固定 M5 iPad Simulator 的当前 Debug App 采集个性化工作区图标素材。
# 中英文各启动一次真实 App；网站再用 CSS 裁出工作区卡片区域。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DEV="$ROOT/scripts/ios-dev.sh"
OUT="$ROOT/web/assets"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"

if [[ "$SIMULATOR_NAME" != "iPad Pro 13-inch (M5)" ]]; then
  echo "视觉素材必须使用固定 iPad Pro 13-inch (M5) Simulator。" >&2
  exit 2
fi

export IOS_TARGET_MODE=simulator
export IOS_SIMULATOR_NAME="$SIMULATOR_NAME"
# 统一 run 仍负责租约、构建、安装与首次启动；无独立 Simulator.app 时不影响 CLI 采集。
export IOS_OPEN_BIN="${IOS_OPEN_BIN:-/usr/bin/true}"

echo "==> 确认固定目标与设备占用"
bash "$IOS_DEV" target
bash "$IOS_DEV" leases

SIMULATOR_ID="$(bash "$IOS_DEV" destination | sed -nE 's/.*id=([^,}]+).*/\1/p')"
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "无法解析固定 Simulator UDID。" >&2
  exit 3
fi
DERIVED_DATA="$(bash "$IOS_DEV" derived-data-path)"

echo "==> 通过统一脚本构建、安装并启动 Debug App"
bash "$IOS_DEV" run

# run 结束后会释放构建租约；截图阶段重新持有同一设备，防止其他 Worktree 插入安装或启动。
ROOT_DIR="$ROOT"
export ROOT_DIR
export IOS_DEVICE_LEASE_WAIT_SECONDS="${IOS_DEVICE_LEASE_WAIT_SECONDS:-60}"
# shellcheck source=../scripts/ios-device-lease.sh
source "$ROOT/scripts/ios-device-lease.sh"
ios_lease_acquire_wait \
  simulator \
  "$SIMULATOR_ID" \
  "$SIMULATOR_NAME" \
  "bash ./web/capture-workspace-icons.sh" \
  "$DERIVED_DATA"
ios_lease_install_traps

capture_language() {
  local language="$1"
  local suffix="$2"
  local output="$OUT/ipad-icons-$suffix.png"

  echo "==> 采集 $language 个性化工作区图标"
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" \
    --debug-skip-pairing --debug-seed-ui --debug-open-workspaces \
    -app.language "$language" >/dev/null
  sleep 4
  xcrun simctl io "$SIMULATOR_ID" screenshot "$output" >/dev/null
  echo "    saved $output"
}

capture_language "en" "en"
capture_language "zh-Hans" "zh"

echo "==> 完成；保留 Simulator 开启，便于后续网页与 App 对照验收。"
