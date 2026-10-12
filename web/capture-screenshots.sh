#!/usr/bin/env bash
#
# 采集官网（web/）使用的 App 截图：简体中文 / 英文 × 浅色 / 深色。
# 画面全部来自 Debug 种子数据（Demo Mac Studio、/Users/demo、占位 Token），
# 不连接真实主机，不会出现维护者的项目、路径或凭据。
#
# 用法（先把 Debug App 装到"采集用的这台" Simulator，再采集）：
#   IOS_TARGET_MODE=simulator IOS_SIMULATOR_NAME='iPhone 17 Pro' \
#     IOS_OPEN_BIN=/usr/bin/true bash ./scripts/ios-dev.sh run
#   bash ./web/capture-screenshots.sh --device iphone [--simulator-id UDID]
#   iPad 同理，把机型换成 'iPad Pro 13-inch (M5)' 后 --device ipad。
#   只补拍部分画面：追加 --scenes approval,workspaces 和/或 --langs en
#   共享的 M5 iPad 可能在构建与采集之间被其他任务覆盖安装：把刚构建的 .app 复制出来，
#   采集时追加 --app PATH，脚本会在持有设备租约后重新安装这一份再截图。
#
# 不显式指定机型时 ios-dev.sh 会优先真机、无真机才回退固定 M5 iPad，装不到本脚本
# 选中的设备上；采集前会检查 App 是否存在，缺少时直接报出该执行的安装命令。
# 没有 iPhone 17 Pro 时按名称回退 iPhone 17（同为 1206 × 2622 屏幕与灵动岛）；
# 截图分辨率与官网设备外框比例不符时直接失败，不会写出变形的图。
# 只用已开机的 Simulator，不改系统语言（语言走 App 启动参数），结束后恢复原外观；
# 设备原本没有状态栏覆盖时才临时固定 09:41，结束后清掉。
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
APP_PATH=""

fail() { echo "capture-screenshots: $1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || fail "--device requires a value"; DEVICE="$2"; shift 2 ;;
    --simulator-id) [[ $# -ge 2 ]] || fail "--simulator-id requires a value"; SIMULATOR_ID="$2"; shift 2 ;;
    --scenes) [[ $# -ge 2 ]] || fail "--scenes requires a value"; SCENES_OVERRIDE="$2"; shift 2 ;;
    --langs) [[ $# -ge 2 ]] || fail "--langs requires a value"; LANGS="$2"; shift 2 ;;
    --app) [[ $# -ge 2 ]] || fail "--app requires a value"; APP_PATH="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

# 官网外框按原始屏幕比例绘制（web/styles.css 的 .device--phone / .device--ipad），
# 所以只接受这两种原始分辨率，缩放到 WEB_WIDTH 后再交给页面。
case "$DEVICE" in
  iphone)
    DEFAULT_NAMES="iPhone 17 Pro|iPhone 17"; RAW_SIZE="1206x2622"; WEB_WIDTH=720
    SCENES=(sessions conversation approval mac-connection workspaces) ;;
  ipad)
    DEFAULT_NAMES="iPad Pro 13-inch (M5)"; RAW_SIZE="2064x2752"; WEB_WIDTH=1320
    SCENES=(approval workspaces) ;;
  *) fail "--device must be iphone or ipad" ;;
esac
[[ -z "$SCENES_OVERRIDE" ]] || IFS=',' read -r -a SCENES <<< "$SCENES_OVERRIDE"

command -v xcrun >/dev/null || fail "missing xcrun"
command -v cwebp >/dev/null || fail "missing cwebp (brew install webp)"
[[ -z "$APP_PATH" || -d "$APP_PATH" ]] || fail "--app is not an .app directory: $APP_PATH"

# 输出 "UDID<TAB>状态<TAB>名称"：给了 UDID 就按 UDID 找，否则按机型名的先后顺序找第一台可用设备。
IFS=$'\t' read -r SIMULATOR_ID INITIAL_STATE SIMULATOR_NAME < <(
  xcrun simctl list devices available -j | WANT_ID="$SIMULATOR_ID" WANT_NAMES="$DEFAULT_NAMES" python3 -c '
import json, os, sys
want_id, want_names = os.environ["WANT_ID"], os.environ["WANT_NAMES"].split("|")
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
if want_id:
    matches = [d for d in devices if d["udid"] == want_id]
else:
    matches = [d for name in want_names for d in devices if d["name"] == name]
if matches:
    d = matches[0]
    print(d["udid"] + "\t" + d["state"] + "\t" + d["name"])
'
) || true
[[ -n "$SIMULATOR_ID" ]] || fail "simulator not found: ${SIMULATOR_ID:-$DEFAULT_NAMES}"
echo "==> $SIMULATOR_NAME ($INITIAL_STATE)"

RAW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-web-shots.XXXXXX")"
DERIVED_DATA="$(bash "$ROOT_DIR/scripts/development-cache-path.sh" xcode/ios/Debug)/dev-simulator-derived/$SIMULATOR_ID"

# 与构建、测试、商店截图共用跨 Worktree 设备租约，避免采集中途被其他任务覆盖安装或切换外观。
# 设备忙时按 IOS_DEVICE_LEASE_WAIT_SECONDS 排队等待，不切换到其他机型。
# shellcheck source=../scripts/ios-device-lease.sh
source "$ROOT_DIR/scripts/ios-device-lease.sh"
ios_lease_acquire_wait simulator "$SIMULATOR_ID" "$SIMULATOR_NAME" \
  "bash ./web/capture-screenshots.sh --device $DEVICE" "$DERIVED_DATA"
ios_lease_install_traps

ensure_app_installed() {
  xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 && return 0
  fail "App 未安装在 $SIMULATOR_NAME ($SIMULATOR_ID)。先执行：
  IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID=$SIMULATOR_ID IOS_OPEN_BIN=/usr/bin/true bash ./scripts/ios-dev.sh run"
}

scene_args() {
  case "$1" in
    sessions)       echo "--debug-seed-ui --debug-seed-store-ui --debug-open-sessions" ;;
    conversation)   echo "--debug-seed-ui --debug-seed-store-ui --debug-open-conversation" ;;
    approval)       echo "--debug-seed-store-ui --debug-seed-mcp-approval-ui --debug-open-conversation" ;;
    mac-connection) echo "--debug-seed-ui --debug-seed-store-ui --debug-open-mac-connection" ;;
    settings)       echo "--debug-seed-ui --debug-seed-store-ui --debug-open-settings" ;;
    workspaces)     echo "--debug-seed-ui --debug-seed-store-ui --debug-open-workspaces" ;;
    *) fail "unknown scene: $1" ;;
  esac
}

# 只用已经开机的 Simulator：共享机器上同时开太多设备会拖垮 CoreSimulator，脚本不替你开机。
[[ "$INITIAL_STATE" == "Booted" ]] || fail "$SIMULATOR_NAME 未开机；确认没有其他任务需要释放资源后先执行 xcrun simctl boot $SIMULATOR_ID"

# 不改系统语言：切换后重启设备会让 App 启动失败（Launchd job spawn failed），
# 也会影响共用这台设备的其他任务。语言改用启动参数只作用于本次启动的 App。
# 结束时只恢复本脚本动过的两项：外观，以及原本没有的状态栏覆盖。
ORIGINAL_APPEARANCE="$(xcrun simctl ui "$SIMULATOR_ID" appearance 2>/dev/null || echo unsupported)"
OWNS_STATUS_BAR=0
restore_simulator() {
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" 2>/dev/null || true
  case "$ORIGINAL_APPEARANCE" in
    light|dark) xcrun simctl ui "$SIMULATOR_ID" appearance "$ORIGINAL_APPEARANCE" || true ;;
  esac
  [[ "$OWNS_STATUS_BAR" == 0 ]] || xcrun simctl status_bar "$SIMULATOR_ID" clear || true
}
# 失败或中断时同样恢复设备，再释放租约。
trap 'restore_simulator || true; ios_lease_release_active' EXIT
if ! xcrun simctl status_bar "$SIMULATOR_ID" list 2>/dev/null | grep -q '^Time:'; then
  OWNS_STATUS_BAR=1
  xcrun simctl status_bar "$SIMULATOR_ID" override --time "09:41" --dataNetwork wifi \
    --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
fi

# 负载高时 simctl launch 偶尔返回 Launchd job spawn failed，稍等重试即可。
launch_app() {
  local attempt
  for attempt in 1 2 3; do
    xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" "$@" >/dev/null && return 0
    echo "  launch failed (attempt $attempt), retrying" >&2
    sleep 5
  done
  fail "无法启动 $BUNDLE_ID"
}

# 启动动画期间灵动岛会以黑色胶囊出现在截图里，而官网外框会自己画岛。
# 在岛的中线上取样：几乎全黑就说明动画还没结束。
island_visible() {
  [[ "$DEVICE" == "iphone" ]] || return 1
  sips -s format bmp "$1" --out "$RAW_DIR/island.bmp" >/dev/null 2>&1 || return 1
  python3 - "$RAW_DIR/island.bmp" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
off = struct.unpack_from("<I", d, 10)[0]
w, h = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0] // 8
row = (w * bpp + 3) & ~3
y = 95  # 1206 宽的竖屏上岛的垂直中线
r = (abs(h) - 1 - y) if h > 0 else y
black = sum(1 for x in range(500, 707, 10)
            if max(d[off + r * row + x * bpp: off + r * row + x * bpp + 3]) < 6)
sys.exit(0 if black > 15 else 1)
PY
}

capture() {
  local lang="$1" app_lang="$2" app_locale="$3" theme="$4" scene="$5"
  local name="$DEVICE-$scene-$lang-$theme" args size attempt
  args="$(scene_args "$scene")"
  # 新装的 App 会弹系统通知授权框，挡住画面且在 App 退出后仍留在设备上；
  # 采集时只在本次启动的参数域里关掉消息通知，不改设备上的任何设置。
  # 共享设备上 App 可能留着别的任务选的主题，固定为默认主题，与官网配色一致。
  # shellcheck disable=SC2086  # scene_args 需要按空格拆成多个参数
  launch_app --debug-skip-pairing $args \
    -AppleLanguages "($app_lang)" -AppleLocale "$app_locale" \
    -messageNotifications.enabled.v1 "<false/>" -appearance.theme.preset codex \
    -app.language "$app_lang" -appearance.theme.mode "$theme"
  # 种子数据在内存里，无需网络；等待只为首次布局与设置 Sheet 动画落定。
  sleep 9
  for attempt in 1 2 3 4 5; do
    xcrun simctl io "$SIMULATOR_ID" screenshot --type=png --mask=ignored "$RAW_DIR/$name.png" >/dev/null 2>&1
    island_visible "$RAW_DIR/$name.png" || break
    [[ "$attempt" -lt 5 ]] || fail "$name: 灵动岛动画一直没有结束，请重拍这一张"
    sleep 3
  done
  size="$(sips -g pixelWidth -g pixelHeight "$RAW_DIR/$name.png" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
  [[ "$size" == "$RAW_SIZE" ]] || fail "$name: 截图为 $size，官网外框需要 $RAW_SIZE（竖屏 $SIMULATOR_NAME）"
  # sharp_yuv 让细字号的中英文边缘在 4:2:0 色度采样后仍然清楚；-m 6 换更小的体积。
  cwebp -quiet -q 82 -m 6 -sharp_yuv -metadata none -resize "$WEB_WIDTH" 0 \
    "$RAW_DIR/$name.png" -o "$OUT_DIR/$name.webp"
  # cwebp 按 mktemp 目录的权限写出 0600，静态服务器读不到。
  chmod 644 "$OUT_DIR/$name.webp"
  echo "  $name.webp  $(( $(wc -c < "$OUT_DIR/$name.webp") / 1024 )) KB"
}

mkdir -p "$OUT_DIR"
[[ -z "$APP_PATH" ]] || xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"
ensure_app_installed
for spec in "zh zh-Hans zh_CN" "en en en_US"; do
  read -r lang app_lang app_locale <<< "$spec"
  [[ ",$LANGS," == *",$lang,"* ]] || continue
  echo "==> $DEVICE · $lang"
  for theme in light dark; do
    xcrun simctl ui "$SIMULATOR_ID" appearance "$theme"
    for scene in "${SCENES[@]}"; do
      capture "$lang" "$app_lang" "$app_locale" "$theme" "$scene"
    done
  done
done

echo "RAW=$RAW_DIR"
echo "OUT=$OUT_DIR"
