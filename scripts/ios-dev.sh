#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ios/MimiRemote/MimiRemote.xcodeproj}"
SCHEME="${SCHEME:-MimiRemote}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET_MODE="${IOS_TARGET_MODE:-auto}"
DEFAULT_SIMULATOR_NAME="iPad Pro 13-inch (M5)"
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-$DEFAULT_SIMULATOR_NAME}"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
DEFAULT_DEVICE_NAME="iPad Pro"
DEVICE_NAME="${IOS_DEVICE_NAME:-${DEVICE_NAME:-$DEFAULT_DEVICE_NAME}}"
DEVICE_ID="${IOS_DEVICE_ID:-${DEVICE_ID:-}}"
SIMULATOR_DERIVED_DATA_ROOT="$ROOT_DIR/ios/MimiRemote/build/dev-simulator-derived"
DEVICE_DERIVED_DATA_ROOT="$ROOT_DIR/ios/MimiRemote/build/dev-device-derived"
BUNDLE_ID="${BUNDLE_ID:-com.gaixianggeng.mimi}"
XCRUN_BIN="${IOS_XCRUN_BIN:-xcrun}"
XCODEBUILD_BIN="${IOS_XCODEBUILD_BIN:-xcodebuild}"
OPEN_BIN="${IOS_OPEN_BIN:-open}"
DEVICE_GUI_HANDOFF_BIN="${IOS_DEVICE_GUI_HANDOFF_BIN:-$ROOT_DIR/scripts/ios-device-gui-handoff-macos.sh}"
TAILCAT_MOBILE_BUILD_SCRIPT="${IOS_TAILCAT_BUILD_SCRIPT:-$ROOT_DIR/scripts/build-tailcat-mobile.sh}"

# shellcheck source=./ios-device-lease.sh
source "$ROOT_DIR/scripts/ios-device-lease.sh"

SELECTED_KIND=""
SELECTED_ID=""
SELECTED_NAME=""
SELECTED_DESTINATION=""
SELECTED_DERIVED_DATA=""
SELECTED_TRANSPORT=""
SELECTED_REASON=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/ios-dev.sh [build|build-for-testing|test|run]
  bash ./scripts/ios-dev.sh target
  bash ./scripts/ios-dev.sh test-destination
  bash ./scripts/ios-dev.sh test-derived-data-path
  bash ./scripts/ios-dev.sh leases

默认目标：
  build/run: USB 真机 → 本地网络真机 → 无可达真机时固定 iPad Simulator
             已连接真机全部忙时明确失败，不静默切换到 Simulator
  test:      精确固定 iPad Pro 13-inch (M5)，忙或缺失时明确失败
  Scheme:    MimiRemote
  Config:    Debug

统一入口：
  日常编译、部署和运行只调用本脚本。deploy-ipad.sh 是内部真机执行器；
  macOS 真机 build/run 固定交给当前登录用户的 GUI LaunchAgent，确保 codesign
  不依赖 Codex Desktop、CLI 或 agentd 的启动会话；
  XcodeBuildMCP 的 Simulator workflow 只用于测试、快照和明确的兼容性验收。
  每次 iOS build/test/run 都会先按源码指纹准备 Tailcat XCFramework；未变化时复用缓存。

可选覆盖：
  IOS_TARGET_MODE         auto（默认）、device 或 simulator
  IOS_DEVICE_NAME         用名称明确选择 USB 或本地网络真机；默认排序优先 iPad Pro
  IOS_DEVICE_ID           用 UDID 明确选择 USB 或本地网络真机
  IOS_SIMULATOR_NAME      普通 build/run 显式选择兼容性 Simulator
  IOS_SIMULATOR_ID        普通 build/run 用 UDID 选择 Simulator
  IOS_TEST_DESTINATION    CI 解析一次的测试 destination；设备必须仍是固定 M5 iPad
  IOS_DERIVED_DATA_PATH   覆盖本次 Simulator DerivedData
  IOS_DEVICE_DERIVED_DATA_PATH 覆盖本次真机 DerivedData
  IOS_DEVICE_LEASE_WAIT_SECONDS 固定测试设备忙时的等待秒数，默认 0（明确失败）

兼容别名：destination / prepare、derived-data-path 仍分别等同于
test-destination、test-derived-data-path。

租约按 UDID 跨 Worktree 原子占用，并记录 PID、Codex Task、Worktree、命令、
DerivedData 和开始时间。脚本不会创建、擦除或删除 Simulator，也不会关闭其他任务的设备。
EOF
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1 && [[ ! -x "$command_name" ]]; then
    echo "缺少命令：$command_name" >&2
    exit 1
  fi
}

ensure_tailcat_mobile() {
  [[ -f "$TAILCAT_MOBILE_BUILD_SCRIPT" ]] || {
    echo "缺少 Tailcat iOS 构建脚本：$TAILCAT_MOBILE_BUILD_SCRIPT" >&2
    exit 1
  }
  echo "==> 准备 Tailcat iOS 框架"
  IOS_TAILCAT_BUILD_ACTION="$command_name" \
    GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" \
    bash "$TAILCAT_MOBILE_BUILD_SCRIPT"
}

simulator_record() {
  local requested_id="$1"
  local requested_name="$2"
  local require_name="$3"

  "$XCRUN_BIN" simctl list devices available -j | \
    IOS_REQUESTED_ID="$requested_id" \
    IOS_REQUESTED_NAME="$requested_name" \
    IOS_REQUIRE_NAME="$require_name" \
    ruby -rjson -e '
      requested_id = ENV.fetch("IOS_REQUESTED_ID", "")
      requested_name = ENV.fetch("IOS_REQUESTED_NAME")
      require_name = ENV.fetch("IOS_REQUIRE_NAME") == "1"
      entries = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
        version = runtime.scan(/\d+/).map(&:to_i)
        devices.map { |device| [version, device] }
      end
      candidates = entries.select do |_version, device|
        next false unless device["isAvailable"]
        if requested_id.empty?
          device["name"] == requested_name
        else
          device["udid"] == requested_id && (!require_name || device["name"] == requested_name)
        end
      end
      chosen = candidates.max_by { |version, _device| version }
      puts [chosen.last.fetch("udid"), chosen.last.fetch("name")].join("\t") if chosen
    '
}

resolve_simulator_record() {
  local requested_id="$1"
  local requested_name="$2"
  local require_name="$3"
  local record
  record="$(simulator_record "$requested_id" "$requested_name" "$require_name")"
  if [[ -z "$record" ]]; then
    if [[ "$require_name" == "1" ]]; then
      echo "找不到精确的测试 Simulator：$DEFAULT_SIMULATOR_NAME" >&2
      [[ -n "$requested_id" ]] && echo "指定 UDID 不是可用的 ${DEFAULT_SIMULATOR_NAME}：$requested_id" >&2
    elif [[ -n "$requested_id" ]]; then
      echo "找不到可用的 iOS Simulator：$requested_id" >&2
    else
      echo "找不到可用的 iOS Simulator：$requested_name" >&2
    fi
    echo "不会回退到 iPad mini、其他 iPad 或 iPhone。当前可用设备：" >&2
    "$XCRUN_BIN" simctl list devices available >&2
    return 4
  fi
  printf '%s\n' "$record"
}

destination_id() {
  local destination="$1"
  local suffix
  suffix="${destination#*id=}"
  [[ "$suffix" != "$destination" ]] || return 1
  printf '%s\n' "${suffix%%,*}"
}

fixed_test_simulator_record() {
  local requested_id=""
  if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
    if [[ "$IOS_TEST_DESTINATION" != *"platform=iOS Simulator"* || "$IOS_TEST_DESTINATION" != *"id="* ]]; then
      echo "IOS_TEST_DESTINATION 必须包含固定 Simulator 的 UDID。" >&2
      return 2
    fi
    requested_id="$(destination_id "$IOS_TEST_DESTINATION")"
  fi
  resolve_simulator_record "$requested_id" "$DEFAULT_SIMULATOR_NAME" 1
}

build_simulator_record() {
  resolve_simulator_record "$SIMULATOR_ID" "$SIMULATOR_NAME" 0
}

physical_device_records() {
  local include_all="${1:-0}"
  local restrict_name=0
  local requested_device_id="$DEVICE_ID"
  local requested_device_name="$DEVICE_NAME"
  [[ -n "${IOS_DEVICE_NAME:-}" ]] && restrict_name=1
  if [[ "$include_all" == "1" ]]; then
    restrict_name=0
    requested_device_id=""
    requested_device_name="$DEFAULT_DEVICE_NAME"
  fi
  "$XCRUN_BIN" devicectl list devices --json-output - --quiet --timeout 5 | \
    IOS_REQUESTED_DEVICE_ID="$requested_device_id" \
    IOS_REQUESTED_DEVICE_NAME="$requested_device_name" \
    IOS_RESTRICT_DEVICE_NAME="$restrict_name" \
    ruby -rjson -e '
      requested_id = ENV.fetch("IOS_REQUESTED_DEVICE_ID", "")
      requested_name = ENV.fetch("IOS_REQUESTED_DEVICE_NAME")
      restrict_name = ENV.fetch("IOS_RESTRICT_DEVICE_NAME") == "1"
      devices = JSON.parse(STDIN.read).fetch("result").fetch("devices")
      candidates = devices.map do |device|
        legacy = device.fetch("properties", {})
        legacy_connection = legacy.fetch("connection", {})
        legacy_hardware = legacy.fetch("hardware", {})
        legacy_state = legacy.fetch("state", {})
        connection = device.fetch("connectionProperties", {})
        hardware = device.fetch("hardwareProperties", {})
        state = device.fetch("deviceProperties", {})
        first_value = ->(*values) { values.find { |value| !value.nil? && !value.to_s.empty? } }

        # Xcode 26 新版 devicectl 把字段提到顶层，旧版则放在
        # properties.* 下。只在传输已连接且已配对时才视为可达。
        platform = first_value.call(hardware["platform"], legacy_hardware["platform"])
        reality = first_value.call(hardware["reality"], legacy_hardware["reality"])
        transport = first_value.call(connection["transportType"], legacy_connection["transportType"])
        connection_state = first_value.call(
          connection["tunnelState"], connection["state"],
          legacy_connection["tunnelState"], legacy_connection["state"]
        )
        pairing_state = first_value.call(connection["pairingState"], legacy_connection["pairingState"])
        next unless ["iOS", "iPadOS"].include?(platform) && reality == "physical"
        next unless ["wired", "localNetwork"].include?(transport)
        next unless connection_state == "connected" && pairing_state == "paired"
        udid = first_value.call(hardware["udid"], legacy_hardware["udid"])
        name = first_value.call(state["name"], legacy_state["name"])
        next if udid.to_s.empty? || name.to_s.empty?
        next if !requested_id.empty? && udid != requested_id
        next if requested_id.empty? && restrict_name && name != requested_name
        [udid, name, transport]
      end.compact
      # 同一 UDID 可能在连接切换期间出现多条记录；先排序再去重，
      # 确保 wired 始终优先，同时共用该 UDID 的租约和 DerivedData。
      transport_rank = { "wired" => 0, "localNetwork" => 1 }
      candidates.sort_by! do |udid, name, transport|
        [transport_rank.fetch(transport), name == requested_name ? 0 : 1, name, udid]
      end
      seen = {}
      candidates.each do |udid, name, transport|
        next if seen[udid]
        seen[udid] = true
        puts [udid, name, transport].join("\t")
      end
    '
}

observable_device_records() {
  physical_device_records 1 | while IFS=$'\t' read -r device_id device_name device_transport; do
    [[ -n "$device_id" ]] && printf 'device\t%s\t%s\t%s\n' \
      "$device_id" "$device_name" "$device_transport"
  done
  "$XCRUN_BIN" simctl list devices available -j | ruby -rjson -e '
    records = JSON.parse(STDIN.read).fetch("devices").flat_map do |runtime, devices|
      version = runtime.scan(/\d+/).map(&:to_i)
      devices.map do |device|
        next unless device["isAvailable"]
        [version, device.fetch("name"), device.fetch("udid")]
      end.compact
    end
    records.sort_by { |version, name, udid| [version, name, udid] }.each do |_version, name, udid|
      puts ["simulator", udid, name].join("\t")
    end
  '
}

simulator_derived_data_path() {
  local simulator_id="$1"
  if [[ -n "${IOS_DERIVED_DATA_PATH:-}" ]]; then
    printf '%s\n' "$IOS_DERIVED_DATA_PATH"
  else
    # 租约按 UDID 隔离，DerivedData 必须使用相同粒度。否则两个 Runtime
    # 下的同名 Simulator 会持有不同租约，却并发写入同一构建数据库。
    printf '%s/%s\n' "$SIMULATOR_DERIVED_DATA_ROOT" "$simulator_id"
  fi
}

device_derived_data_path() {
  local device_id="$1"
  if [[ -n "${IOS_DEVICE_DERIVED_DATA_PATH:-}" ]]; then
    printf '%s\n' "$IOS_DEVICE_DERIVED_DATA_PATH"
  else
    printf '%s/%s\n' "$DEVICE_DERIVED_DATA_ROOT" "$device_id"
  fi
}

select_target() {
  local kind="$1"
  local device_id="$2"
  local device_name="$3"
  local device_transport="${4:-}"
  local selection_reason="${5:-}"
  SELECTED_KIND="$kind"
  SELECTED_ID="$device_id"
  SELECTED_NAME="$device_name"
  SELECTED_TRANSPORT="$device_transport"
  SELECTED_REASON="$selection_reason"
  if [[ "$kind" == "device" ]]; then
    SELECTED_DESTINATION="platform=iOS,id=$device_id"
    SELECTED_DERIVED_DATA="$(device_derived_data_path "$device_id")"
  else
    SELECTED_DESTINATION="platform=iOS Simulator,id=$device_id"
    SELECTED_DERIVED_DATA="$(simulator_derived_data_path "$device_id")"
  fi
}

effective_target_mode() {
  local effective_mode="$TARGET_MODE"
  if [[ -z "${IOS_TARGET_MODE:-}" ]]; then
    if [[ -n "${IOS_SIMULATOR_ID:-}" || -n "${IOS_SIMULATOR_NAME:-}" ]]; then
      effective_mode="simulator"
    elif [[ -n "$DEVICE_ID" || -n "${IOS_DEVICE_NAME:-}" ]]; then
      effective_mode="device"
    fi
  fi
  case "$effective_mode" in
    auto|device|simulator) printf '%s\n' "$effective_mode" ;;
    *)
      echo "IOS_TARGET_MODE 只支持 auto、device 或 simulator：$effective_mode" >&2
      return 2
      ;;
  esac
}

select_available_build_target() {
  local effective_mode physical_records device_id device_name device_transport simulator_record_value
  effective_mode="$(effective_target_mode)" || return

  if [[ "$effective_mode" == "simulator" ]]; then
    simulator_record_value="$(build_simulator_record)" || return
    IFS=$'\t' read -r device_id device_name <<< "$simulator_record_value"
    if ! ios_lease_device_is_available simulator "$device_id" "$device_name"; then
      echo "指定 Simulator 正在使用：$device_name ($device_id)" >&2
      echo "$IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
      return 75
    fi
    select_target simulator "$device_id" "$device_name" "" \
      "显式 Simulator 覆盖"
    return
  fi

  physical_records="$(physical_device_records)"
  if [[ -n "$DEVICE_ID" && -z "$physical_records" ]]; then
    echo "指定真机不可达或未配对（USB 或本地网络）：$DEVICE_ID" >&2
    echo "设备可能已断开，或只保留了历史配对记录。" >&2
    return 4
  fi
  if [[ -n "${IOS_DEVICE_NAME:-}" && -z "$physical_records" ]]; then
    echo "指定真机不可达或未配对（USB 或本地网络）：$IOS_DEVICE_NAME" >&2
    echo "设备可能已断开，或只保留了历史配对记录。" >&2
    return 4
  fi

  while IFS=$'\t' read -r device_id device_name device_transport; do
    [[ -n "$device_id" ]] || continue
    if ios_lease_device_is_available device "$device_id" "$device_name"; then
      local selection_reason="检测到空闲 USB 真机"
      [[ "$device_transport" == "localNetwork" ]] \
        && selection_reason="没有空闲 USB 真机，使用可达的本地网络真机"
      if [[ "$effective_mode" == "device" ]]; then
        selection_reason="显式真机模式：${device_transport}"
      fi
      select_target device "$device_id" "$device_name" "$device_transport" \
        "$selection_reason"
      return
    fi
    echo "==> 跳过占用设备：$device_name ($device_id) · $IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
  done <<< "$physical_records"

  if [[ "$effective_mode" == "device" ]]; then
    if [[ -z "$physical_records" ]]; then
      echo "没有检测到 available、paired、可达的 iOS 真机（USB 或本地网络）。" >&2
    else
      echo "所有匹配的 USB 或本地网络真机都在使用中。" >&2
    fi
    return 75
  fi

  # 已经检测到可达真机但全部忙时，静默换成 Simulator 会让部署结果与
  # 操作者预期相反。只有完全没有可达真机时，auto 才允许跨设备类型回退。
  if [[ -n "$physical_records" ]]; then
    echo "检测到可达真机，但所有真机都在使用中；本次不会自动部署到 Simulator。" >&2
    echo "请等待真机释放、运行 leases 查看占用，或显式设置 IOS_TARGET_MODE=simulator。" >&2
    return 75
  fi

  simulator_record_value="$(resolve_simulator_record "" "$DEFAULT_SIMULATOR_NAME" 1)" || return
  IFS=$'\t' read -r device_id device_name <<< "$simulator_record_value"
  if ! ios_lease_device_is_available simulator "$device_id" "$device_name"; then
    echo "USB 和本地网络真机不可用，固定 fallback Simulator 也正在使用：$device_name ($device_id)" >&2
    echo "$IOS_DEVICE_LEASE_BUSY_DETAIL" >&2
    return 75
  fi
  select_target simulator "$device_id" "$device_name" "" \
    "没有检测到可达的 USB 或本地网络真机，使用固定 fallback Simulator"
}

acquire_selected_target() {
  local lease_command="$1"
  ios_lease_try_acquire \
    "$SELECTED_KIND" \
    "$SELECTED_ID" \
    "$SELECTED_NAME" \
    "$lease_command" \
    "$SELECTED_DERIVED_DATA"
}

select_and_acquire_build_target() {
  local lease_command="$1"
  local attempts=0
  while (( attempts < 16 )); do
    select_available_build_target || return
    if acquire_selected_target "$lease_command"; then
      ios_lease_install_traps
      return
    fi
    attempts=$((attempts + 1))
  done
  echo "设备状态持续变化，无法获得稳定租约。请运行 leases 查看占用。" >&2
  return 75
}

select_fixed_test_target() {
  local record
  record="$(fixed_test_simulator_record)" || return
  IFS=$'\t' read -r SELECTED_ID SELECTED_NAME <<< "$record"
  select_target simulator "$SELECTED_ID" "$SELECTED_NAME" "" \
    "测试、快照与 CI 固定使用 M5 Simulator"
}

acquire_fixed_test_target() {
  local lease_command="$1"
  select_fixed_test_target || return
  ios_lease_acquire_wait \
    simulator \
    "$SELECTED_ID" \
    "$SELECTED_NAME" \
    "$lease_command" \
    "$SELECTED_DERIVED_DATA"
  ios_lease_install_traps
}

simulator_is_booted() {
  local target_id="$1"
  "$XCRUN_BIN" simctl list devices booted -j | IOS_TARGET_ID="$target_id" ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    exit(devices.any? { |device| device["udid"] == ENV.fetch("IOS_TARGET_ID") } ? 0 : 1)
  '
}

simulator_ui_warning() {
  echo "警告：$1。Simulator 界面不是必需步骤，将继续构建、安装并启动。" >&2
}

current_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return 0
  fi

  if ! command -v xcode-select >/dev/null 2>&1; then
    return 1
  fi
  xcode-select -p
}

open_simulator_ui() {
  local developer_dir
  if ! developer_dir="$(current_developer_dir 2>/dev/null)" || [[ -z "$developer_dir" ]]; then
    simulator_ui_warning "无法解析当前 Developer 目录"
    return 0
  fi

  if [[ ! -d "$developer_dir" ]]; then
    simulator_ui_warning "Developer 目录不存在：$developer_dir"
    return 0
  fi

  local resolved_developer_dir
  if ! resolved_developer_dir="$(cd "$developer_dir" 2>/dev/null && pwd -P)"; then
    simulator_ui_warning "无法解析 Developer 目录：$developer_dir"
    return 0
  fi
  local xcode_contents_dir
  if ! xcode_contents_dir="$(cd "$resolved_developer_dir/.." 2>/dev/null && pwd -P)"; then
    simulator_ui_warning "无法解析 Xcode 包目录：$developer_dir"
    return 0
  fi

  local ui_app=""
  if [[ -d "$resolved_developer_dir/Applications/Simulator.app" ]]; then
    ui_app="$resolved_developer_dir/Applications/Simulator.app"
  elif [[ -d "$xcode_contents_dir/Applications/DeviceHub.app" ]]; then
    ui_app="$xcode_contents_dir/Applications/DeviceHub.app"
  else
    simulator_ui_warning "找不到 Simulator 或 DeviceHub 界面应用"
    return 0
  fi

  if ! command -v "$OPEN_BIN" >/dev/null 2>&1 && [[ ! -x "$OPEN_BIN" ]]; then
    simulator_ui_warning "找不到或无法执行 open 命令：$OPEN_BIN"
    return 0
  fi
  if ! "$OPEN_BIN" "$ui_app"; then
    simulator_ui_warning "打开界面应用失败：$ui_app"
  fi
}

run_xcodebuild() {
  local action="$1"
  shift
  echo "==> $SCHEME $CONFIGURATION · $action"
  echo "    destination: $SELECTED_DESTINATION"
  echo "    DerivedData: $SELECTED_DERIVED_DATA"
  echo "    reason: $SELECTED_REASON"

  "$XCODEBUILD_BIN" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$SELECTED_DESTINATION" \
    -derivedDataPath "$SELECTED_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    "$action"
}

run_device_action() {
  local action="$1"
  shift
  local transport_label="USB"
  local skip_install="0"
  local skip_launch="0"
  local development_team="${IOS_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM:-}}"
  local -a deploy_command
  [[ "$SELECTED_TRANSPORT" == "localNetwork" ]] && transport_label="本地网络"
  echo "==> 使用已租用${transport_label}真机：$SELECTED_NAME ($SELECTED_ID)"
  echo "    reason: $SELECTED_REASON"
  if [[ "$action" == "build" ]]; then
    skip_install="1"
    skip_launch="1"
  fi
  deploy_command=(
    /usr/bin/env
    "IOS_UNIFIED_ENTRYPOINT=1"
    "PROJECT_PATH=$PROJECT_PATH"
    "SCHEME=$SCHEME"
    "CONFIGURATION=$CONFIGURATION"
    "DEVICE_ID=$SELECTED_ID"
    "DEVICE_NAME=$SELECTED_NAME"
    "BUNDLE_ID=$BUNDLE_ID"
    "DERIVED_DATA_PATH=$SELECTED_DERIVED_DATA"
    "IOS_XCODEBUILD_BIN=$XCODEBUILD_BIN"
    "IOS_XCRUN_BIN=$XCRUN_BIN"
    "TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}"
    "SKIP_INSTALL=$skip_install"
    "SKIP_LAUNCH=$skip_launch"
    "REFRESH_INSTALL=${REFRESH_INSTALL:-0}"
    "ALLOW_PROVISIONING_UPDATES=${ALLOW_PROVISIONING_UPDATES:-1}"
    "IOS_DEVELOPMENT_TEAM=$development_team"
    "CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Automatic}"
  )
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    deploy_command+=("DEVELOPER_DIR=$DEVELOPER_DIR")
  fi
  deploy_command+=(/bin/bash "$ROOT_DIR/scripts/deploy-ipad.sh")
  if [[ $# -gt 0 ]]; then
    deploy_command+=("$@")
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    /bin/bash "$DEVICE_GUI_HANDOFF_BIN" "${deploy_command[@]}"
  else
    "${deploy_command[@]}"
  fi
}

print_lease_status() {
  local record kind device_id device_name device_transport found=0
  while IFS=$'\t' read -r kind device_id device_name device_transport; do
    [[ -n "$device_id" ]] || continue
    found=1
    ios_lease_print_status "$kind" "$device_id" "$device_name"
    [[ "$kind" == "device" && -n "$device_transport" ]] \
      && printf '  connection:  %s\n' "$device_transport"
  done < <(observable_device_records)
  [[ "$found" -eq 1 ]] || echo "当前没有可观察的 iOS 真机或 Simulator。"
}

command_name="${1:-build}"
if [[ $# -gt 0 ]]; then
  shift
fi
lease_command="bash ./scripts/ios-dev.sh $command_name"
[[ $# -gt 0 ]] && lease_command="$lease_command $*"

case "$command_name" in
  test-destination|destination|prepare)
    require_command "$XCRUN_BIN"
    require_command ruby
    select_fixed_test_target
    printf '%s\n' "$SELECTED_DESTINATION"
    ;;
  target)
    require_command "$XCRUN_BIN"
    require_command "$IOS_DEVICE_LEASE_PS_BIN"
    require_command ruby
    select_available_build_target
    printf '%s: %s (%s)\n' "$SELECTED_KIND" "$SELECTED_NAME" "$SELECTED_ID"
    [[ "$SELECTED_KIND" == "device" ]] && printf 'Connection: %s\n' "$SELECTED_TRANSPORT"
    printf 'Policy: daily build/run\n'
    printf 'Reason: %s\n' "$SELECTED_REASON"
    printf 'DerivedData: %s\n' "$SELECTED_DERIVED_DATA"
    ;;
  test-derived-data-path|derived-data-path)
    require_command "$XCRUN_BIN"
    require_command ruby
    select_fixed_test_target
    printf '%s\n' "$SELECTED_DERIVED_DATA"
    ;;
  leases|lease-status)
    require_command "$XCRUN_BIN"
    require_command "$IOS_DEVICE_LEASE_PS_BIN"
    require_command ruby
    print_lease_status
    ;;
  build)
    require_command "$XCODEBUILD_BIN"
    require_command "$XCRUN_BIN"
    require_command "$IOS_DEVICE_LEASE_PS_BIN"
    require_command ruby
    select_and_acquire_build_target "$lease_command"
    ensure_tailcat_mobile
    if [[ "$SELECTED_KIND" == "device" ]]; then
      run_device_action build "$@"
    else
      run_xcodebuild build "$@"
    fi
    ;;
  build-for-testing|test)
    require_command "$XCODEBUILD_BIN"
    require_command "$XCRUN_BIN"
    require_command "$IOS_DEVICE_LEASE_PS_BIN"
    require_command ruby
    acquire_fixed_test_target "$lease_command"
    ensure_tailcat_mobile
    run_xcodebuild "$command_name" "$@"
    ;;
  run)
    require_command "$XCODEBUILD_BIN"
    require_command "$XCRUN_BIN"
    require_command "$IOS_DEVICE_LEASE_PS_BIN"
    require_command ruby
    select_and_acquire_build_target "$lease_command"
    ensure_tailcat_mobile
    if [[ "$SELECTED_KIND" == "device" ]]; then
      run_device_action run "$@"
      exit 0
    fi

    if ! simulator_is_booted "$SELECTED_ID"; then
      "$XCRUN_BIN" simctl boot "$SELECTED_ID"
    fi
    open_simulator_ui
    "$XCRUN_BIN" simctl bootstatus "$SELECTED_ID" -b
    run_xcodebuild build "$@"

    app_path="$SELECTED_DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/MimiRemote.app"
    if [[ ! -d "$app_path" ]]; then
      echo "构建成功但找不到 App：$app_path" >&2
      exit 1
    fi
    "$XCRUN_BIN" simctl install "$SELECTED_ID" "$app_path"
    "$XCRUN_BIN" simctl launch --terminate-running-process "$SELECTED_ID" "$BUNDLE_ID"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "不支持的操作：$command_name" >&2
    usage >&2
    exit 2
    ;;
esac
