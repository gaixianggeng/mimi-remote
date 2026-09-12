#!/usr/bin/env bash
#
# 采集官网（web/）使用的 App 截图：简体中文 / 英文 × 浅色 / 深色。
# 画面全部来自 Debug 种子数据（Demo Mac Studio、/Users/demo、占位 Token），
# 不连接真实主机，不会出现维护者的项目、路径或凭据。
#
# 用法：
#   bash ./scripts/ios-dev.sh run                                   # 先把 Debug App 装到目标 Simulator
#   bash ./web/capture-screenshots.sh --device iphone [--simulator-id UDID]
#   bash ./web/capture-screenshots.sh --device ipad   [--simulator-id UDID]
#   只补拍部分画面：追加 --scenes settings,approval 和/或 --langs en
#
# 产物：web/assets/shots/{iphone|ipad}-{场景}-{zh|en}-{light|dark}.webp
# 页面用 [data-shot] 加当前语言与深浅色拼出文件名，见 web/site.js。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/web/assets/shots}"
DEVICE=""
SIMULATOR_ID=""
SCENES_OVERRIDE=""
LANGS="zh,en"

fail() { echo "capture-screenshots: $1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || fail "--device requires a value"; DEVICE="$2"; shift 2 ;;
    --simulator-id) [[ $# -ge 2 ]] || fail "--simulator-id requires a value"; SIMULATOR_ID="$2"; shift 2 ;;
    --scenes) [[ $# -ge 2 ]] || fail "--scenes requires a value"; SCENES_OVERRIDE="$2"; shift 2 ;;
    --langs) [[ $# -ge 2 ]] || fail "--langs requires a value"; LANGS="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$DEVICE" in
  iphone)
    DEFAULT_NAME="iPhone 17 Pro"; WEB_WIDTH=720
    SCENES=(sessions conversation approval mac-connection workspaces) ;;
  ipad)
    DEFAULT_NAME="iPad Pro 13-inch (M5)"; WEB_WIDTH=1320
    SCENES=(approval workspaces) ;;
  *) fail "--device must be iphone or ipad" ;;
esac
[[ -z "$SCENES_OVERRIDE" ]] || IFS=',' read -r -a SCENES <<< "$SCENES_OVERRIDE"

command -v xcrun >/dev/null || fail "missing xcrun"
command -v cwebp >/dev/null || fail "missing cwebp (brew install webp)"

# 输出 "UDID<TAB>名称"：给了 UDID 就按 UDID 找，否则按默认机型名找第一台可用设备。
read -r SIMULATOR_ID SIMULATOR_NAME < <(
  xcrun simctl list devices available -j | WANT_ID="$SIMULATOR_ID" WANT_NAME="$DEFAULT_NAME" python3 -c '
import json, os, sys
want_id, want_name = os.environ["WANT_ID"], os.environ["WANT_NAME"]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if (want_id and d["udid"] == want_id) or (not want_id and d["name"] == want_name):
            print(d["udid"] + "\t" + d["name"]); sys.exit()
' | tr '\t' ' '
) || true
[[ -n "$SIMULATOR_ID" ]] || fail "simulator not found: ${SIMULATOR_ID:-$DEFAULT_NAME}"

RAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-web-shots.XXXXXX")"

# 与构建、测试、商店截图共用跨 Worktree 设备租约，避免切换系统语言时被其他任务插入。
# shellcheck source=../scripts/ios-device-lease.sh
source "$ROOT_DIR/scripts/ios-device-lease.sh"
ios_lease_acquire_wait simulator "$SIMULATOR_ID" "$SIMULATOR_NAME" \
  "bash ./web/capture-screenshots.sh --device $DEVICE" \
  "$ROOT_DIR/ios/MimiRemote/build/dev-simulator-derived/$SIMULATOR_ID"
ios_lease_install_traps

scene_args() {
  case "$1" in
    sessions)       echo "--debug-seed-ui --debug-seed-store-ui --debug-open-sessions" ;;
    conversation)   echo "--debug-seed-ui --debug-seed-store-ui --debug-open-conversation" ;;
    approval)       echo "--debug-seed-store-ui --debug-seed-mcp-approval-ui --debug-open-conversation" ;;
    mac-connection) echo "--debug-seed-ui --debug-seed-store-ui --debug-open-mac-connection" ;;
    settings)       echo "--debug-seed-ui --debug-seed-store-ui --debug-open-settings" ;;
    workspaces)     echo "--debug-seed-ui --debug-seed-store-ui --debug-open-workspaces" ;;
  esac
}

boot() {
  xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
  xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null
}

set_locale() {
  boot
  xcrun simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLanguages -array "$1"
  xcrun simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLocale "$2"
  # 状态栏日期等系统文案只在重启后读取新语言，所以每种语言只重启一次。
  xcrun simctl shutdown "$SIMULATOR_ID"
  boot
  # 刚启动时系统可能弹出欢迎类横幅，等它消失再截图。
  sleep 20
  xcrun simctl status_bar "$SIMULATOR_ID" override --time "09:41" --dataNetwork wifi \
    --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
}

capture() {
  local lang="$1" app_lang="$2" theme="$3" scene="$4"
  local name="$DEVICE-$scene-$lang-$theme"
  # shellcheck disable=SC2046  # scene_args 需要按空格拆成多个参数
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" \
    --debug-skip-pairing $(scene_args "$scene") \
    -app.language "$app_lang" -appearance.theme.mode "$theme" >/dev/null
  # 种子数据在内存里，无需网络；等待只为首次布局与设置 Sheet 动画落定。
  sleep 9
  xcrun simctl io "$SIMULATOR_ID" screenshot --type=png --mask=ignored "$RAW_DIR/$name.png" >/dev/null 2>&1
  cwebp -quiet -q 84 -resize "$WEB_WIDTH" 0 "$RAW_DIR/$name.png" -o "$OUT_DIR/$name.webp"
  # cwebp 按 mktemp 目录的权限写出 0600，静态服务器读不到。
  chmod 644 "$OUT_DIR/$name.webp"
  echo "  $name.webp"
}

mkdir -p "$OUT_DIR"
for spec in "zh zh-Hans zh-Hans-CN zh_CN" "en en en-US en_US"; do
  read -r lang app_lang sys_lang sys_locale <<< "$spec"
  [[ ",$LANGS," == *",$lang,"* ]] || continue
  echo "==> $DEVICE · $lang"
  set_locale "$sys_lang" "$sys_locale"
  for theme in light dark; do
    xcrun simctl ui "$SIMULATOR_ID" appearance "$theme"
    for scene in "${SCENES[@]}"; do
      capture "$lang" "$app_lang" "$theme" "$scene"
    done
  done
done

# 恢复中文系统语言与浅色外观后关机，下次启动即回到原状态。
xcrun simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLanguages -array "zh-Hans-CN" "en-CN"
xcrun simctl spawn "$SIMULATOR_ID" defaults write NSGlobalDomain AppleLocale "zh_CN"
xcrun simctl ui "$SIMULATOR_ID" appearance light
xcrun simctl status_bar "$SIMULATOR_ID" clear || true
xcrun simctl shutdown "$SIMULATOR_ID"
echo "RAW=$RAW_DIR"
echo "OUT=$OUT_DIR"
