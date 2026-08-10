#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/scripts/testdata/ios-device-management"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-ios-device-management.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

export IOS_XCRUN_BIN="$FIXTURE_DIR/fake-xcrun.sh"
export IOS_XCODEBUILD_BIN="$FIXTURE_DIR/fake-xcodebuild.sh"
export IOS_DEVICE_LEASE_ROOT="$TEMP_DIR/leases"
export IOS_TEST_SIMULATORS_JSON="$FIXTURE_DIR/simulators.json"
export IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/physical-devices.json"
export IOS_TEST_XCODEBUILD_LOG="$TEMP_DIR/xcodebuild.log"
unset IOS_TEST_DESTINATION IOS_SIMULATOR_ID IOS_SIMULATOR_NAME IOS_DEVICE_ID IOS_DEVICE_NAME IOS_TARGET_MODE

fail() {
  echo "iOS 设备管理测试失败：$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "${label}：期望 '$expected'，实际 '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "${label}：缺少 '$needle'"
}

write_lease_metadata() {
  local device_id="$1"
  local owner_pid="$2"
  local pid_start="$3"
  local lease_dir="$IOS_DEVICE_LEASE_ROOT/$device_id.lease"
  mkdir -p "$lease_dir"
  {
    printf 'pid\t%s\n' "$owner_pid"
    printf 'pid_start\t%s\n' "$pid_start"
    printf 'task\tfixture-task\n'
    printf 'worktree\t%s\n' "$ROOT_DIR"
    printf 'command\tfixture command\n'
    printf 'derived_data\t%s/build/%s\n' "$TEMP_DIR" "$device_id"
    printf 'started_at\t2026-07-30T00:00:00Z\n'
    printf 'kind\tdevice\n'
    printf 'device_id\t%s\n' "$device_id"
    printf 'device_name\tfixture\n'
  } > "$lease_dir/metadata"
}

destination="$(bash "$ROOT_DIR/scripts/ios-dev.sh" destination)"
assert_equal "platform=iOS Simulator,id=M5-27-UDID" "$destination" \
  "固定测试目标必须选择最新 Runtime 上的精确 M5 iPad"

m5_26_target="$(
  IOS_TARGET_MODE=simulator \
  IOS_SIMULATOR_ID="M5-26-UDID" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
m5_27_target="$(
  IOS_TARGET_MODE=simulator \
  IOS_SIMULATOR_ID="M5-27-UDID" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
m5_26_derived="$(printf '%s\n' "$m5_26_target" | awk -F 'DerivedData: ' '/^DerivedData:/ { print $2 }')"
m5_27_derived="$(printf '%s\n' "$m5_27_target" | awk -F 'DerivedData: ' '/^DerivedData:/ { print $2 }')"
assert_contains "$m5_26_derived" "dev-simulator-derived/M5-26-UDID" \
  "旧 Runtime 的同名 M5 必须使用自己的 DerivedData"
assert_contains "$m5_27_derived" "dev-simulator-derived/M5-27-UDID" \
  "新 Runtime 的同名 M5 必须使用自己的 DerivedData"
[[ "$m5_26_derived" != "$m5_27_derived" ]] \
  || fail "不同 Runtime 的同名 M5 不得共用 DerivedData"

missing_output="$TEMP_DIR/missing-m5.log"
if IOS_TEST_SIMULATORS_JSON="$FIXTURE_DIR/simulators-without-m5.json" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" destination >"$missing_output" 2>&1; then
  fail "缺少 M5 iPad 时不应成功"
fi
assert_contains "$(cat "$missing_output")" "不会回退到 iPad mini" \
  "缺少固定设备时必须明确拒绝回退"

mini_destination_output="$TEMP_DIR/mini-destination.log"
if IOS_TEST_DESTINATION="platform=iOS Simulator,id=MINI-27-UDID" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" destination >"$mini_destination_output" 2>&1; then
  fail "IOS_TEST_DESTINATION 指向 iPad mini 时不应成功"
fi
assert_contains "$(cat "$mini_destination_output")" "指定 UDID 不是可用的 iPad Pro 13-inch (M5)" \
  "CI 传入的 destination 必须再次校验设备名称"

target_output="$(bash "$ROOT_DIR/scripts/ios-dev.sh" target)"
assert_contains "$target_output" "device: iPad Pro (PHYSICAL-PRO-UDID)" \
  "普通 build/run 默认优先 USB iPad Pro"
assert_contains "$target_output" "Connection: wired" \
  "新版 devicectl 字段必须能识别 wired 真机"
assert_contains "$target_output" "dev-device-derived/PHYSICAL-PRO-UDID" \
  "真机 DerivedData 必须按 UDID 隔离"

wireless_id_target="$(
  IOS_TARGET_MODE=device \
  IOS_DEVICE_ID="NETWORK-PRO-UDID" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
assert_contains "$wireless_id_target" "device: iPad Pro (NETWORK-PRO-UDID)" \
  "IOS_DEVICE_ID 必须能明确选择新字段格式的本地网络真机"
assert_contains "$wireless_id_target" "Connection: localNetwork" \
  "本地网络真机必须显示连接方式"
assert_contains "$wireless_id_target" "dev-device-derived/NETWORK-PRO-UDID" \
  "无线真机必须和有线真机一样按 UDID 隔离 DerivedData"

wireless_name_target="$(
  IOS_DEVICE_NAME="Network iPhone" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
assert_contains "$wireless_name_target" "device: Network iPhone (NETWORK-ONLY-UDID)" \
  "IOS_DEVICE_NAME 必须能明确选择旧字段格式的本地网络真机"
assert_contains "$wireless_name_target" "Connection: localNetwork" \
  "旧版 devicectl 字段必须能识别本地网络真机"

unreachable_output="$TEMP_DIR/unreachable-device.log"
set +e
IOS_TARGET_MODE=device \
IOS_DEVICE_ID="OFFLINE-PAIRED-UDID" \
bash "$ROOT_DIR/scripts/ios-dev.sh" target >"$unreachable_output" 2>&1
unreachable_status=$?
set -e
assert_equal "4" "$unreachable_status" \
  "明确选择不可达的无线真机时必须失败"
assert_contains "$(cat "$unreachable_output")" "真机不可达或未配对" \
  "指定真机不可达时必须输出可操作原因"

lease_inventory="$(bash "$ROOT_DIR/scripts/ios-dev.sh" leases)"
assert_contains "$lease_inventory" "Network iPhone (NETWORK-ONLY-UDID)" \
  "leases 必须展示可达的无线真机"
assert_contains "$lease_inventory" "connection:  localNetwork" \
  "leases 必须标记无线真机连接方式"

: > "$TEMP_DIR/wireless-build-xcodebuild.log"
wireless_build_output="$(
  IOS_TARGET_MODE=device \
  IOS_DEVICE_ID="NETWORK-PRO-UDID" \
  IOS_DEVICE_DERIVED_DATA_PATH="$TEMP_DIR/wireless-derived" \
  IOS_TEST_XCODEBUILD_LOG="$TEMP_DIR/wireless-build-xcodebuild.log" \
  IOS_TEST_CREATE_APP=1 \
  bash "$ROOT_DIR/scripts/ios-dev.sh" build
)"
assert_contains "$wireless_build_output" "使用已租用本地网络真机：iPad Pro (NETWORK-PRO-UDID)" \
  "显式无线 build 必须进入真机部署链路"
assert_contains "$(cat "$TEMP_DIR/wireless-build-xcodebuild.log")" \
  "-destination platform=iOS,id=NETWORK-PRO-UDID" \
  "无线 build 必须把选中 UDID 传入 xcodebuild"
assert_contains "$(cat "$TEMP_DIR/wireless-build-xcodebuild.log")" \
  "-derivedDataPath $TEMP_DIR/wireless-derived" \
  "无线 build 必须使用该 UDID 的独立 DerivedData"
[[ ! -d "$IOS_DEVICE_LEASE_ROOT/NETWORK-PRO-UDID.lease" ]] \
  || fail "无线 build 结束后必须释放按 UDID 建立的租约"

duplicate_target="$(
  IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/duplicate-device-transports.json" \
  IOS_TARGET_MODE=device \
  IOS_DEVICE_ID="SHARED-TRANSPORT-UDID" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
assert_contains "$duplicate_target" "Connection: wired" \
  "同一 UDID 同时报告 wired/localNetwork 时必须去重并优先 wired"
assert_contains "$duplicate_target" "dev-device-derived/SHARED-TRANSPORT-UDID" \
  "同一 UDID 不得按 transport 拆分 DerivedData"
duplicate_inventory="$(
  IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/duplicate-device-transports.json" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" leases
)"
assert_equal "1" "$(printf '%s\n' "$duplicate_inventory" | awk 'index($0, "SHARED-TRANSPORT-UDID") { count += 1 } END { print count + 0 }')" \
  "leases 必须将同一 UDID 的两种 transport 去重为一台设备"

owner_start="$(/bin/ps -p "$$" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
write_lease_metadata "SHARED-TRANSPORT-UDID" "$$" "$owner_start"
duplicate_busy_output="$TEMP_DIR/duplicate-transport-busy.log"
set +e
IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/duplicate-device-transports.json" \
IOS_TARGET_MODE=device \
IOS_DEVICE_ID="SHARED-TRANSPORT-UDID" \
bash "$ROOT_DIR/scripts/ios-dev.sh" target >"$duplicate_busy_output" 2>&1
duplicate_busy_status=$?
set -e
assert_equal "75" "$duplicate_busy_status" \
  "同一 UDID 的 wired/localNetwork 必须共用一份租约"
assert_contains "$(cat "$duplicate_busy_output")" "SHARED-TRANSPORT-UDID" \
  "transport 共用租约时必须输出占用设备"
rm -f "$IOS_DEVICE_LEASE_ROOT/SHARED-TRANSPORT-UDID.lease/metadata"
rmdir "$IOS_DEVICE_LEASE_ROOT/SHARED-TRANSPORT-UDID.lease"

write_lease_metadata "PHYSICAL-PRO-UDID" "$$" "$owner_start"
target_output="$(bash "$ROOT_DIR/scripts/ios-dev.sh" target 2>"$TEMP_DIR/skip-live.log")"
assert_contains "$target_output" "device: iPad mini (PHYSICAL-MINI-UDID)" \
  "主力真机已有活租约时必须选择下一台空闲 USB 真机"
assert_contains "$(cat "$TEMP_DIR/skip-live.log")" "跳过占用设备：iPad Pro" \
  "跳过租约设备时必须输出可见原因"
write_lease_metadata "PHYSICAL-MINI-UDID" "$$" "$owner_start"
wireless_fallback_target="$(bash "$ROOT_DIR/scripts/ios-dev.sh" target 2>"$TEMP_DIR/wireless-fallback.log")"
assert_contains "$wireless_fallback_target" "device: iPad Pro (NETWORK-PRO-UDID)" \
  "所有 wired 真机忙时必须先回退本地网络真机"
assert_contains "$wireless_fallback_target" "Connection: localNetwork" \
  "本地网络回退必须可观测"
write_lease_metadata "NETWORK-PRO-UDID" "$$" "$owner_start"
write_lease_metadata "NETWORK-ONLY-UDID" "$$" "$owner_start"
simulator_fallback_target="$(bash "$ROOT_DIR/scripts/ios-dev.sh" target 2>"$TEMP_DIR/simulator-fallback.log")"
assert_contains "$simulator_fallback_target" "simulator: iPad Pro 13-inch (M5) (M5-27-UDID)" \
  "wired 和 localNetwork 真机都忙时必须回退固定 M5 Simulator"
assert_contains "$simulator_fallback_target" "dev-simulator-derived/M5-27-UDID" \
  "真机全部忙时 Simulator fallback 仍必须按 UDID 隔离 DerivedData"
rm -f "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-PRO-UDID.lease/metadata"
rmdir "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-PRO-UDID.lease"
rm -f "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-MINI-UDID.lease/metadata"
rmdir "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-MINI-UDID.lease"
rm -f "$IOS_DEVICE_LEASE_ROOT/NETWORK-PRO-UDID.lease/metadata"
rmdir "$IOS_DEVICE_LEASE_ROOT/NETWORK-PRO-UDID.lease"
rm -f "$IOS_DEVICE_LEASE_ROOT/NETWORK-ONLY-UDID.lease/metadata"
rmdir "$IOS_DEVICE_LEASE_ROOT/NETWORK-ONLY-UDID.lease"

mkdir "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-PRO-UDID.lease"
acquiring_target="$(bash "$ROOT_DIR/scripts/ios-dev.sh" target 2>"$TEMP_DIR/acquiring.log")"
assert_contains "$acquiring_target" "device: iPad mini (PHYSICAL-MINI-UDID)" \
  "原子目录刚创建但 metadata 尚未落盘时必须视为占用"
[[ -d "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-PRO-UDID.lease" ]] \
  || fail "其他进程不得清理仍在建立中的租约"
rmdir "$IOS_DEVICE_LEASE_ROOT/PHYSICAL-PRO-UDID.lease"

ps_fixture="$TEMP_DIR/external-ps.txt"
printf '%s\n' \
  "4242 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -destination platform=iOS,id=PHYSICAL-PRO-UDID -derivedDataPath /tmp/external-build build" \
  > "$ps_fixture"
external_target="$(
  IOS_DEVICE_LEASE_PS_BIN="$FIXTURE_DIR/fake-ps.sh" \
  IOS_TEST_PS_OUTPUT_FILE="$ps_fixture" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target 2>"$TEMP_DIR/external-target.log"
)"
assert_contains "$external_target" "device: iPad mini (PHYSICAL-MINI-UDID)" \
  "外部 xcodebuild 使用主力真机时必须选择下一台设备"
external_status="$(
  IOS_DEVICE_LEASE_PS_BIN="$FIXTURE_DIR/fake-ps.sh" \
  IOS_TEST_PS_OUTPUT_FILE="$ps_fixture" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" leases
)"
assert_contains "$external_status" "external" "只读状态必须显示外部 xcodebuild"
assert_contains "$external_status" "pid:" "只读状态必须显示外部进程信息"

export IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/no-physical-devices.json"
stale_dir="$IOS_DEVICE_LEASE_ROOT/M5-27-UDID.lease"
write_lease_metadata "M5-27-UDID" "999999" "Mon Jan  1 00:00:00 2001"
stale_status="$(bash "$ROOT_DIR/scripts/ios-dev.sh" leases)"
assert_contains "$stale_status" "stale" "只读状态必须展示过期租约"
[[ -d "$stale_dir" ]] || fail "只读 leases 命令不得清理过期租约"
bash "$ROOT_DIR/scripts/ios-dev.sh" build >"$TEMP_DIR/stale-build.log" 2>&1
[[ ! -d "$stale_dir" ]] || fail "死 PID 租约应在成功构建后清理并释放"
assert_contains "$(cat "$IOS_TEST_XCODEBUILD_LOG")" "platform=iOS Simulator,id=M5-27-UDID" \
  "清理过期租约后仍必须使用固定 M5 fallback"

: > "$IOS_TEST_XCODEBUILD_LOG"
holder_started="$TEMP_DIR/holder-started"
IOS_TEST_XCODEBUILD_SLEEP_SECONDS=3 \
IOS_TEST_XCODEBUILD_STARTED="$holder_started" \
bash "$ROOT_DIR/scripts/ios-dev.sh" build >"$TEMP_DIR/holder.log" 2>&1 &
holder_pid=$!

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$holder_started" ]] && break
  sleep 0.1
done
[[ -f "$holder_started" ]] || {
  wait "$holder_pid" || true
  fail "未观察到持有租约的模拟构建"
}

lease_status="$(bash "$ROOT_DIR/scripts/ios-dev.sh" leases)"
assert_contains "$lease_status" "leased" "运行中必须显示设备租约"
assert_contains "$lease_status" "task:" "租约必须记录 Codex Task"
assert_contains "$lease_status" "worktree:" "租约必须记录 Worktree"
assert_contains "$lease_status" "command:" "租约必须记录命令"
assert_contains "$lease_status" "derived_data:" "租约必须记录 DerivedData"
assert_contains "$lease_status" "started_at:" "租约必须记录开始时间"

busy_output="$TEMP_DIR/busy-test.log"
set +e
bash "$ROOT_DIR/scripts/ios-dev.sh" test -only-testing:MimiRemoteTests/ConversationSnapshotTests \
  >"$busy_output" 2>&1
busy_status=$?
set -e
assert_equal "75" "$busy_status" "固定快照设备忙时必须明确失败"
assert_contains "$(cat "$busy_output")" "未切换到其他测试设备" \
  "快照测试忙时不得改用 iPad mini"

wait "$holder_pid"
[[ ! -d "$IOS_DEVICE_LEASE_ROOT/M5-27-UDID.lease" ]] || fail "进程正常结束后必须释放租约"

reuse_derived_data="$TEMP_DIR/reuse-derived"
: > "$IOS_TEST_XCODEBUILD_LOG"
reuse_missing_output="$TEMP_DIR/reuse-missing.log"
set +e
IOS_DERIVED_DATA_PATH="$reuse_derived_data" \
bash "$ROOT_DIR/scripts/ios-dev.sh" test-without-building \
  -only-testing:MimiRemoteTests/LocalizationTests >"$reuse_missing_output" 2>&1
reuse_missing_status=$?
set -e
assert_equal "3" "$reuse_missing_status" \
  "缺少 build-for-testing 产物时 test-without-building 必须失败"
assert_contains "$(cat "$reuse_missing_output")" "请先对同一 destination 和 DerivedData 执行 build-for-testing" \
  "复用产物缺失时必须给出可操作提示"
[[ ! -s "$IOS_TEST_XCODEBUILD_LOG" ]] \
  || fail "复用产物缺失时不得调用 xcodebuild 或静默重新编译"

IOS_DERIVED_DATA_PATH="$reuse_derived_data" \
IOS_TEST_CREATE_TEST_PRODUCTS=1 \
bash "$ROOT_DIR/scripts/ios-dev.sh" build-for-testing -quiet
IOS_DERIVED_DATA_PATH="$reuse_derived_data" \
bash "$ROOT_DIR/scripts/ios-dev.sh" test-without-building \
  -only-testing:MimiRemoteTests/LocalizationTests
reuse_xcodebuild_log="$(cat "$IOS_TEST_XCODEBUILD_LOG")"
assert_contains "$reuse_xcodebuild_log" "build-for-testing" \
  "复用链路必须先执行 build-for-testing"
assert_contains "$reuse_xcodebuild_log" "test-without-building" \
  "复用链路必须执行 test-without-building"
assert_equal "2" "$(printf '%s\n' "$reuse_xcodebuild_log" | grep -Fc -- "-destination platform=iOS Simulator,id=M5-27-UDID")" \
  "构建与复用测试必须使用同一固定 M5 destination"
assert_equal "2" "$(printf '%s\n' "$reuse_xcodebuild_log" | grep -Fc -- "-derivedDataPath $reuse_derived_data")" \
  "构建与复用测试必须使用同一 DerivedData"
[[ ! -d "$IOS_DEVICE_LEASE_ROOT/M5-27-UDID.lease" ]] \
  || fail "复用测试结束后必须释放固定 M5 租约"

: > "$IOS_TEST_XCODEBUILD_LOG"
IOS_DERIVED_DATA_PATH="$reuse_derived_data" \
bash "$ROOT_DIR/scripts/test-ios-localization-smoke.sh"
assert_equal "test" "$(awk 'END { print $NF }' "$IOS_TEST_XCODEBUILD_LOG")" \
  "直接运行测试脚本时必须保留自行构建并测试的默认行为"
invalid_action_output="$TEMP_DIR/invalid-test-action.log"
set +e
IOS_TEST_ACTION=build \
IOS_DERIVED_DATA_PATH="$reuse_derived_data" \
bash "$ROOT_DIR/scripts/test-ios-localization-smoke.sh" >"$invalid_action_output" 2>&1
invalid_action_status=$?
set -e
assert_equal "2" "$invalid_action_status" "测试脚本必须拒绝非白名单 IOS_TEST_ACTION"
assert_contains "$(cat "$invalid_action_output")" "只支持 test 或 test-without-building" \
  "非法测试 action 必须给出明确提示"

m5_26_started="$TEMP_DIR/m5-26-started"
m5_27_started="$TEMP_DIR/m5-27-started"
IOS_TARGET_MODE=simulator \
IOS_SIMULATOR_ID="M5-26-UDID" \
IOS_TEST_XCODEBUILD_LOG="$TEMP_DIR/m5-26-xcodebuild.log" \
IOS_TEST_XCODEBUILD_SLEEP_SECONDS=2 \
IOS_TEST_XCODEBUILD_STARTED="$m5_26_started" \
bash "$ROOT_DIR/scripts/ios-dev.sh" build >"$TEMP_DIR/m5-26-build.log" 2>&1 &
m5_26_pid=$!
IOS_TARGET_MODE=simulator \
IOS_SIMULATOR_ID="M5-27-UDID" \
IOS_TEST_XCODEBUILD_LOG="$TEMP_DIR/m5-27-xcodebuild.log" \
IOS_TEST_XCODEBUILD_SLEEP_SECONDS=2 \
IOS_TEST_XCODEBUILD_STARTED="$m5_27_started" \
bash "$ROOT_DIR/scripts/ios-dev.sh" build >"$TEMP_DIR/m5-27-build.log" 2>&1 &
m5_27_pid=$!

for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$m5_26_started" && -f "$m5_27_started" ]] && break
  sleep 0.1
done
[[ -f "$m5_26_started" && -f "$m5_27_started" ]] || {
  wait "$m5_26_pid" || true
  wait "$m5_27_pid" || true
  fail "未观察到两个 Runtime 的同名 M5 并发持有独立租约"
}

multi_m5_status="$(bash "$ROOT_DIR/scripts/ios-dev.sh" leases)"
assert_contains "$multi_m5_status" "dev-simulator-derived/M5-26-UDID" \
  "M5-26 租约必须记录自己的 DerivedData"
assert_contains "$multi_m5_status" "dev-simulator-derived/M5-27-UDID" \
  "M5-27 租约必须记录自己的 DerivedData"
assert_equal "2" "$(printf '%s\n' "$multi_m5_status" | awk '$1 == "leased" && index($0, "iPad Pro 13-inch (M5)") { count += 1 } END { print count + 0 }')" \
  "两个 Runtime 的同名 M5 必须分别持有租约"

wait "$m5_26_pid"
wait "$m5_27_pid"
[[ ! -d "$IOS_DEVICE_LEASE_ROOT/M5-26-UDID.lease" ]] || fail "M5-26 构建结束后必须释放租约"
[[ ! -d "$IOS_DEVICE_LEASE_ROOT/M5-27-UDID.lease" ]] || fail "M5-27 构建结束后必须释放租约"

simulator_target="$(
  IOS_TARGET_MODE=simulator \
  IOS_SIMULATOR_NAME="iPhone 17 Pro" \
  bash "$ROOT_DIR/scripts/ios-dev.sh" target
)"
assert_contains "$simulator_target" "dev-simulator-derived/IPHONE-27-UDID" \
  "不同 Simulator 必须使用独立 DerivedData"

printf 'iOS 设备选择、固定测试目标、租约、过期恢复和外部 xcodebuild 检查通过。\n'
