#!/usr/bin/env bash
set -euo pipefail

# iOS 构建证据自测：在临时 Git 仓库与 Worktree 中使用 fake xcodebuild/xcrun/go，
# 覆盖复用、各类失效（含构建相关环境变量与工程外引用解析）、失败与中途改动不记录、
# 跨 Worktree 隔离、缓存清理和排队提示。
# 只使用临时目录里的租约与缓存，不接触真实设备、共享 DerivedData 或其他任务的租约。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/scripts/testdata/ios-device-management"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-ios-build-evidence.XXXXXX")"
holder_pid=""
cleanup() {
  if [[ -n "$holder_pid" ]]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "iOS 构建证据测试失败：$1" >&2
  exit 1
}

assert_equal() {
  [[ "$2" == "$1" ]] || fail "${3}：期望 '$1'，实际 '$2'"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "${3}：缺少 '$2'。输出：$1"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "${3}：不应包含 '$2'"
}

unset IOS_TEST_DESTINATION IOS_SIMULATOR_ID IOS_SIMULATOR_NAME IOS_DEVICE_ID IOS_DEVICE_NAME \
  IOS_TARGET_MODE IOS_DERIVED_DATA_PATH IOS_DEVICE_DERIVED_DATA_PATH IOS_BUILD_EVIDENCE_REUSE \
  IOS_DEVICE_LEASE_WAIT_SECONDS IOS_DEVICE_LEASE_PROGRESS_SECONDS PROJECT_PATH SCHEME CONFIGURATION \
  TAILCAT_MOBILE_OUTPUT_DIR TAILCAT_MOBILE_MODULE_DIR GOTOOLCHAIN IOS_TEST_XCODE_VERSION \
  IOS_TEST_SIMULATOR_SDK_VERSION IOS_TEST_GO_VERSION IOS_TEST_XCODEBUILD_EXIT_CODE \
  IOS_TEST_XCODEBUILD_MUTATE_FILE IOS_TEST_XCODEBUILD_SLEEP_SECONDS IOS_TEST_XCODEBUILD_STARTED \
  IOS_TEST_CREATE_APP IOS_TEST_PS_OUTPUT_FILE IOS_TEST_SWIFT_VERSION TOOLCHAINS SDKROOT CC \
  XCODE_XCCONFIG_FILE TAILCAT_MOBILE_TOOL_DIR MIMI_EVIDENCE_FLAG MIMI_UNRELATED_SETTING
# 外部 xcodebuild 扫描改用 fixture：本机其他项目的真实 xcodebuild（例如 generic Simulator
# 构建）会被启发式判为占用所有 Simulator，使结果取决于宿主机状态。-p 查询仍走真实 ps。
export IOS_DEVICE_LEASE_PS_BIN="$FIXTURE_DIR/fake-ps.sh"
export IOS_XCRUN_BIN="$FIXTURE_DIR/fake-xcrun.sh"
export IOS_XCODEBUILD_BIN="$FIXTURE_DIR/fake-xcodebuild.sh"
export IOS_TAILCAT_BUILD_SCRIPT="$FIXTURE_DIR/fake-tailcat-mobile-build.sh"
export TAILCAT_MOBILE_GO_BIN="$FIXTURE_DIR/fake-go.sh"
export IOS_TEST_SIMULATORS_JSON="$FIXTURE_DIR/simulators.json"
export IOS_TEST_PHYSICAL_JSON="$FIXTURE_DIR/no-physical-devices.json"
export IOS_DEVICE_LEASE_ROOT="$TEMP_DIR/leases"
export MIMI_DEVELOPMENT_CACHE_ROOT="$TEMP_DIR/cache"
export IOS_TEST_XCODEBUILD_LOG="$TEMP_DIR/xcodebuild.log"
export IOS_TEST_TAILCAT_BUILD_LOG="$TEMP_DIR/tailcat.log"
# 不全局设置 DEVELOPER_DIR：macOS 的 git shim 依赖它。只在 Xcode 路径用例中临时覆盖。
mkdir -p "$TEMP_DIR/Xcode-next.app/Contents/Developer"
: > "$IOS_TEST_XCODEBUILD_LOG"
: > "$IOS_TEST_TAILCAT_BUILD_LOG"

# 最小 Worktree：工程文件同时引用工程外资源和 $SRCROOT 构建脚本，证明这两类输入会被纳入。
# 工程结构与真实工程一致：Resources 分组下的引用以 ../../../ 指向仓库根目录。
worktree_a="$TEMP_DIR/worktree-a"
mkdir -p "$worktree_a/scripts" "$worktree_a/ios/MimiRemote/MimiRemote.xcodeproj" \
  "$worktree_a/ios/MimiRemote/Sources" "$worktree_a/ios/MimiRemote/Resources" "$worktree_a/docs" \
  "$worktree_a/experiments/tailcat"
cp "$ROOT_DIR/scripts/ios-dev.sh" "$ROOT_DIR/scripts/ios-device-lease.sh" \
  "$ROOT_DIR/scripts/ios-build-evidence.sh" "$ROOT_DIR/scripts/development-cache-path.sh" \
  "$worktree_a/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$worktree_a/scripts/build-tailcat-mobile.sh"
cat > "$worktree_a/ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj" <<'PBXPROJ'
// !$*UTF8*$!
{
  rootObject = PRJ;
  objects = {
    PRJ = {isa = PBXProject; mainGroup = MAIN; projectDirPath = ""; projectRoot = ""; };
    MAIN = {isa = PBXGroup; children = (RES); sourceTree = "<group>"; };
    RES /* Resources */ = {isa = PBXGroup; children = (AAA); path = Resources; sourceTree = "<group>"; };
    AAA /* support.md */ = {isa = PBXFileReference; name = support.md; path = ../../../docs/support.md; sourceTree = "<group>"; };
    BBB /* Tailcat */ = {isa = PBXShellScriptBuildPhase; shellScript = "bash \"$SRCROOT/../../scripts/build-tailcat-mobile.sh\"\n"; };
    CCC = {isa = XCBuildConfiguration; buildSettings = {LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../../Frameworks"); }; };
    /* extra */
  };
}
PBXPROJ
printf 'struct App {}\n' > "$worktree_a/ios/MimiRemote/Sources/App.swift"
# Info.plist 引用的自定义构建设置可以由同名环境变量注入。
printf '<plist><dict><key>Flag</key><string>$(MIMI_EVIDENCE_FLAG)</string></dict></plist>\n' \
  > "$worktree_a/ios/MimiRemote/Resources/Info.plist"
printf '# Support\n' > "$worktree_a/docs/support.md"
printf '# Unrelated\n' > "$worktree_a/docs/unrelated.md"
printf 'module example.invalid/tailcat\n' > "$worktree_a/experiments/tailcat/go.mod"
printf 'ios/MimiRemote/Generated/\n' > "$worktree_a/.gitignore"
git -C "$worktree_a" init -q
git -C "$worktree_a" config user.name "Mimi Evidence Test"
git -C "$worktree_a" config user.email "evidence-test@example.invalid"
git -C "$worktree_a" add .
git -C "$worktree_a" commit -qm baseline

build_count() {
  awk 'END { print NR }' "$IOS_TEST_XCODEBUILD_LOG"
}

run_quick() {
  local worktree="$1"
  local output="$2"
  shift 2
  set +e
  env "$@" IOS_BUILD_EVIDENCE_REUSE=1 IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID= \
    IOS_SIMULATOR_NAME='iPad Pro 13-inch (M5)' \
    bash "$worktree/scripts/ios-dev.sh" build >"$output" 2>&1
  quick_status=$?
  set -e
}

evidence_status() {
  local worktree="$1"
  shift
  set +e
  status_output="$(
    env "$@" IOS_TARGET_MODE="${STATUS_TARGET_MODE:-simulator}" IOS_SIMULATOR_ID="${STATUS_SIMULATOR_ID:-}" \
      IOS_SIMULATOR_NAME='iPad Pro 13-inch (M5)' \
      bash "$worktree/scripts/ios-dev.sh" build-evidence 2>&1
  )"
  status_code=$?
  set -e
}

assert_reusable() {
  evidence_status "$@"
  assert_equal "0" "$status_code" "构建证据应可复用（${status_output}）"
  assert_contains "$status_output" "可复用：" "可复用状态必须说明证据"
}

assert_rebuild() {
  local expected="$1"
  shift
  evidence_status "$@"
  assert_equal "3" "$status_code" "构建证据应失效"
  assert_contains "$status_output" "需要重新构建：" "失效状态必须说明需要重建"
  assert_contains "$status_output" "$expected" "失效原因必须可解释"
}

lease_dir="$IOS_DEVICE_LEASE_ROOT/M5-27-UDID.lease"
write_m5_lease() {
  local owner_pid="$1"
  local owner_start
  owner_start="$(ps -p "$owner_pid" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  mkdir -p "$lease_dir"
  {
    printf 'pid\t%s\n' "$owner_pid"
    printf 'pid_start\t%s\n' "$owner_start"
    printf 'task\tother-worktree-task\n'
    printf 'worktree\t%s/other-worktree\n' "$TEMP_DIR"
    printf 'command\tbash ./scripts/ios-dev.sh test -only-testing:MimiRemoteTests/OtherTests\n'
    printf 'derived_data\t%s/other-derived\n' "$TEMP_DIR"
    printf 'started_at\t2026-01-01T00:00:00Z\n'
    printf 'started_epoch\t%s\n' "$(( $(date '+%s') - 125 ))"
    printf 'kind\tsimulator\n'
    printf 'device_id\tM5-27-UDID\n'
    printf 'device_name\tiPad Pro 13-inch (M5)\n'
  } > "$lease_dir/metadata"
}

release_m5_lease() {
  rm -f "$lease_dir/metadata"
  rmdir "$lease_dir"
}

m5_derived="$(
  IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID=M5-27-UDID \
    bash "$worktree_a/scripts/ios-dev.sh" target | awk -F 'DerivedData: ' '/^DerivedData:/ { print $2 }'
)"
assert_contains "$m5_derived" "$MIMI_DEVELOPMENT_CACHE_ROOT/" "证据所在 DerivedData 必须位于仓库外缓存"

# 1. 没有证据时只说明原因，不占用设备也不构建。
assert_rebuild "没有本 Worktree 在 iPad Pro 13-inch (M5) 上的成功构建证据" "$worktree_a"
assert_equal "0" "$(build_count)" "只读状态不得调用 xcodebuild"
assert_equal "" "$(cat "$IOS_TEST_TAILCAT_BUILD_LOG")" "只读状态不得准备 Tailcat"
[[ ! -d "$lease_dir" ]] || fail "只读状态不得占用设备租约"

# 2. 定向 XCTest 成功后留下证据。
targeted_output="$(bash "$worktree_a/scripts/ios-dev.sh" test -quiet \
  -only-testing:MimiRemoteTests/ExampleTests -testLanguage en)"
assert_contains "$targeted_output" "已记录构建证据：test（-only-testing 1 项）" \
  "成功的定向测试必须记录构建证据"
record_count="$(find "$m5_derived/MimiBuildEvidence" -name '*.record' | awk 'END { print NR }')"
assert_equal "1" "$record_count" "同一 Worktree 只保留一份当前证据"
builds_after_test="$(build_count)"

# 3. 输入一致时 quick 复用：即使固定 M5 被其他任务占用，也不排队、不构建。
write_m5_lease "$$"
run_quick "$worktree_a" "$TEMP_DIR/reuse.log"
assert_equal "0" "$quick_status" "匹配证据必须让 quick 的 App 编译项通过"
assert_contains "$(cat "$TEMP_DIR/reuse.log")" "复用构建证据：本 Worktree 的 test（-only-testing 1 项）" \
  "复用时必须说明使用了哪项证据"
assert_contains "$(cat "$TEMP_DIR/reuse.log")" "未占用设备租约" "复用时必须说明未占用设备"
assert_equal "$builds_after_test" "$(build_count)" "复用证据时不得再次调用 xcodebuild"
assert_equal "$$" "$(awk -F '\t' '$1 == "pid" { print $2 }' "$lease_dir/metadata")" \
  "复用证据不得改动其他任务的租约"
assert_reusable "$worktree_a"
assert_contains "$status_output" "test（-only-testing 1 项）" "--plan 状态必须指出证据来源"

# 4. 未提交改动使证据失效；设备忙且无等待预算时仍是阻塞 75，不能算通过。
printf '// local edit\n' >> "$worktree_a/ios/MimiRemote/Sources/App.swift"
assert_rebuild "ios/MimiRemote/Sources/App.swift" "$worktree_a"
assert_contains "$status_output" "源码/资源/工程文件" "源码变化必须归类说明"
run_quick "$worktree_a" "$TEMP_DIR/stale-busy.log"
assert_equal "75" "$quick_status" "证据失效且设备忙时必须阻塞，而不是通过"
assert_contains "$(cat "$TEMP_DIR/stale-busy.log")" "构建证据不可复用：自上次成功构建后已变化" \
  "回退构建时必须说明证据失效原因"
assert_contains "$(cat "$TEMP_DIR/stale-busy.log")" "Task other-worktree-task，已占用 2m" \
  "设备忙时必须说明占用者和占用时长"
assert_contains "$(cat "$TEMP_DIR/stale-busy.log")" "IOS_DEVICE_LEASE_WAIT_SECONDS=<秒>" \
  "无等待预算时必须提示如何排队"
assert_equal "$builds_after_test" "$(build_count)" "阻塞时不得调用 xcodebuild"
release_m5_lease

# 5. 设置等待预算后排队，占用结束自动继续，并输出进度；不切换设备。
# 占用者直到排队进度出现才退出（最多约 30 秒），断言不依赖机器快慢。
: > "$TEMP_DIR/queued.log"
(
  for _attempt in $(seq 1 300); do
    grep -q '仍在排队' "$TEMP_DIR/queued.log" 2>/dev/null && break
    sleep 0.1
  done
) &
holder_pid=$!
write_m5_lease "$holder_pid"
run_quick "$worktree_a" "$TEMP_DIR/queued.log" IOS_DEVICE_LEASE_WAIT_SECONDS=30 \
  IOS_DEVICE_LEASE_PROGRESS_SECONDS=1
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
queued_log="$(cat "$TEMP_DIR/queued.log")"
assert_equal "0" "$quick_status" "占用结束后排队中的 quick 构建必须继续完成（${queued_log}）"
assert_contains "$queued_log" "设备忙，排队等待租约（最长 30s，不切换设备）" "排队开始时必须说明预算"
assert_contains "$queued_log" "仍在排队：已等待" "排队期间必须输出进度"
assert_contains "$queued_log" "已获得设备租约：iPad Pro 13-inch (M5)" "获得租约时必须说明排队时长"
assert_contains "$queued_log" "platform=iOS Simulator,id=M5-27-UDID" "排队后仍必须使用固定 M5"
assert_contains "$queued_log" "已记录构建证据：build" "quick 自身的成功构建同样记录证据"
assert_equal "$((builds_after_test + 1))" "$(build_count)" "证据失效时必须真正构建"
[[ ! -d "$lease_dir" ]] || fail "构建结束后必须释放租约"

# 6. 提交同一内容不改变指纹：定向测试后提交，再跑 quick 仍可复用。
git -C "$worktree_a" add ios/MimiRemote/Sources/App.swift
git -C "$worktree_a" commit -qm "local edit"
assert_reusable "$worktree_a"

# 7. 未跟踪文件、工程外引用和无关文档。
printf 'struct Extra {}\n' > "$worktree_a/ios/MimiRemote/Sources/Extra.swift"
assert_rebuild "ios/MimiRemote/Sources/Extra.swift" "$worktree_a"
rm "$worktree_a/ios/MimiRemote/Sources/Extra.swift"
assert_reusable "$worktree_a"
printf 'changed\n' >> "$worktree_a/docs/support.md"
assert_rebuild "docs/support.md" "$worktree_a"
git -C "$worktree_a" checkout -q -- docs/support.md
printf 'changed\n' >> "$worktree_a/scripts/build-tailcat-mobile.sh"
assert_rebuild "scripts/build-tailcat-mobile.sh" "$worktree_a"
git -C "$worktree_a" checkout -q -- scripts/build-tailcat-mobile.sh
printf 'changed\n' >> "$worktree_a/docs/unrelated.md"
assert_reusable "$worktree_a"
git -C "$worktree_a" checkout -q -- docs/unrelated.md

# 8. 工具链、目标、Scheme、Tailcat 框架变化都必须重建。
assert_rebuild "Xcode 版本（Xcode 99.0 / Build version 99A1 → Xcode 99.1 / Build version 99A1）" \
  "$worktree_a" IOS_TEST_XCODE_VERSION="Xcode 99.1"
assert_rebuild "Simulator SDK" "$worktree_a" IOS_TEST_SIMULATOR_SDK_VERSION=99.1
assert_rebuild "Go 工具链" "$worktree_a" IOS_TEST_GO_VERSION=go1.100.0
assert_rebuild "Xcode 路径" "$worktree_a" DEVELOPER_DIR="$TEMP_DIR/Xcode-next.app/Contents/Developer"
assert_rebuild "Scheme（MimiRemote → Other）" "$worktree_a" SCHEME=Other
mkdir -p "$worktree_a/ios/MimiRemote/Generated"
printf 'new-tailcat-fingerprint\n' > "$worktree_a/ios/MimiRemote/Generated/.tailcat-mobile-fingerprint"
assert_rebuild "Tailcat 框架" "$worktree_a"
rm -rf "$worktree_a/ios/MimiRemote/Generated"
STATUS_SIMULATOR_ID=M5-26-UDID assert_rebuild "没有本 Worktree" "$worktree_a"
STATUS_TARGET_MODE=auto assert_rebuild "只有显式 Simulator 构建可以复用" "$worktree_a"
assert_reusable "$worktree_a"

# 同版本工具换路径，或同一路径的包装脚本换内容，都不能沿用原工具的构建证据。
cp "$IOS_XCODEBUILD_BIN" "$TEMP_DIR/alternate-xcodebuild"
cp "$IOS_XCRUN_BIN" "$TEMP_DIR/alternate-xcrun"
assert_rebuild "xcodebuild 执行文件" "$worktree_a" IOS_XCODEBUILD_BIN="$TEMP_DIR/alternate-xcodebuild"
assert_rebuild "xcrun 执行文件" "$worktree_a" IOS_XCRUN_BIN="$TEMP_DIR/alternate-xcrun"
IOS_XCODEBUILD_BIN="$TEMP_DIR/alternate-xcodebuild" bash "$worktree_a/scripts/ios-dev.sh" build-for-testing >/dev/null
assert_reusable "$worktree_a" IOS_XCODEBUILD_BIN="$TEMP_DIR/alternate-xcodebuild"
printf '\n# changed wrapper settings\n' >> "$TEMP_DIR/alternate-xcodebuild"
assert_rebuild "xcodebuild 执行文件" "$worktree_a" IOS_XCODEBUILD_BIN="$TEMP_DIR/alternate-xcodebuild"
bash "$worktree_a/scripts/ios-dev.sh" build-for-testing >/dev/null
assert_reusable "$worktree_a"

# 8b. ios-dev.sh 不清理环境，xcodebuild 与工程脚本继承全部变量：工具链选择、编译器、
#     Tailcat 构建脚本读取的变量和工程引用的自定义设置变化都必须重建；无关变量与 PATH 不影响。
assert_rebuild "Swift 工具链（TOOLCHAINS）" "$worktree_a" TOOLCHAINS=org.swift.fake
assert_contains "$status_output" "构建相关环境变量（TOOLCHAINS）" "TOOLCHAINS 变化必须点名"
assert_rebuild "无法确认工具链或构建环境：无法解析 TOOLCHAINS=missing 对应的 Swift 工具链" \
  "$worktree_a" TOOLCHAINS=missing
assert_rebuild "构建相关环境变量（CPATH）" "$worktree_a" CPATH="$TEMP_DIR/include"
assert_rebuild "构建相关环境变量（CC）" "$worktree_a" CC=/usr/bin/false
assert_rebuild "构建相关环境变量（TAILCAT_MOBILE_TOOL_DIR）" "$worktree_a" \
  TAILCAT_MOBILE_TOOL_DIR="$TEMP_DIR/other-tools"
assert_rebuild "构建相关环境变量（MIMI_EVIDENCE_FLAG）" "$worktree_a" MIMI_EVIDENCE_FLAG=1
assert_rebuild "环境变量 XCODE_XCCONFIG_FILE 会覆盖工程构建设置" "$worktree_a" \
  XCODE_XCCONFIG_FILE="$TEMP_DIR/override.xcconfig"
assert_reusable "$worktree_a" MIMI_UNRELATED_SETTING=1 TAILCAT_MOBILE_LOCK_WAIT_SECONDS=5 \
  PATH="$PATH:$TEMP_DIR/extra-bin"

# 8c. 带 TOOLCHAINS 和注入设置的构建按同一环境复用；同一标识下工具链升级或取值变化都重建。
#     证据只保存环境变量值的哈希，不保存原值。
toolchain_output="$(TOOLCHAINS=org.swift.fake MIMI_EVIDENCE_FLAG=evidence-secret-value \
  bash "$worktree_a/scripts/ios-dev.sh" build-for-testing)"
assert_contains "$toolchain_output" "已记录构建证据：build-for-testing" "带构建环境的成功构建必须记录证据"
a_record="$(grep -l "^worktree	$(cd "$worktree_a" && pwd -P)$" "$m5_derived/MimiBuildEvidence/"*.record)"
assert_contains "$(cat "$a_record")" "TOOLCHAINS=org.swift.fake" "证据必须记录 TOOLCHAINS 标识"
assert_not_contains "$(cat "$a_record")" "evidence-secret-value" "证据不得保存环境变量原值"
assert_reusable "$worktree_a" TOOLCHAINS=org.swift.fake MIMI_EVIDENCE_FLAG=evidence-secret-value
assert_rebuild "Swift 工具链（TOOLCHAINS）" "$worktree_a" TOOLCHAINS=org.swift.fake \
  MIMI_EVIDENCE_FLAG=evidence-secret-value IOS_TEST_SWIFT_VERSION=10.0
assert_rebuild "构建相关环境变量（MIMI_EVIDENCE_FLAG）" "$worktree_a" TOOLCHAINS=org.swift.fake \
  MIMI_EVIDENCE_FLAG=other-value
assert_rebuild "构建相关环境变量（MIMI_EVIDENCE_FLAG、TOOLCHAINS）" "$worktree_a"
xcconfig_output="$(XCODE_XCCONFIG_FILE="$TEMP_DIR/override.xcconfig" \
  bash "$worktree_a/scripts/ios-dev.sh" build-for-testing)"
assert_contains "$xcconfig_output" "构建证据：本次不记录（无法确认工具链或构建环境：环境变量 XCODE_XCCONFIG_FILE" \
  "XCODE_XCCONFIG_FILE 覆盖设置时不得记录证据"
bash "$worktree_a/scripts/ios-dev.sh" build-for-testing >/dev/null
assert_reusable "$worktree_a"

# 9. 失败、改变构建的参数和构建中途改动都不记录，也不覆盖之前的成功证据。
printf '// broken edit\n' >> "$worktree_a/ios/MimiRemote/Sources/App.swift"
set +e
IOS_TEST_XCODEBUILD_EXIT_CODE=65 bash "$worktree_a/scripts/ios-dev.sh" test \
  -only-testing:MimiRemoteTests/ExampleTests >"$TEMP_DIR/failed.log" 2>&1
failed_status=$?
set -e
assert_equal "65" "$failed_status" "失败的测试必须保留退出码"
assert_not_contains "$(cat "$TEMP_DIR/failed.log")" "已记录构建证据" "失败构建不得记录证据"
assert_rebuild "ios/MimiRemote/Sources/App.swift" "$worktree_a"
coverage_output="$(bash "$worktree_a/scripts/ios-dev.sh" test -enableCodeCoverage YES)"
assert_contains "$coverage_output" "构建证据：本次不记录（参数 -enableCodeCoverage 可能改变构建结果）" \
  "改变构建的参数不得留下证据"
assert_rebuild "ios/MimiRemote/Sources/App.swift" "$worktree_a"
git -C "$worktree_a" checkout -q -- ios/MimiRemote/Sources/App.swift
assert_reusable "$worktree_a"
mutating_output="$(
  IOS_TEST_XCODEBUILD_MUTATE_FILE="$worktree_a/ios/MimiRemote/Sources/App.swift" \
    bash "$worktree_a/scripts/ios-dev.sh" build-for-testing
)"
assert_contains "$mutating_output" "构建证据：未记录（构建期间源码/资源/工程文件发生变化）" \
  "构建中途改动输入不得记录证据"
assert_rebuild "ios/MimiRemote/Sources/App.swift" "$worktree_a"
git -C "$worktree_a" checkout -q -- ios/MimiRemote/Sources/App.swift
assert_reusable "$worktree_a"

# 10. 工程外引用按分组层级和 sourceTree 解析，不按“去掉前导 ../ 后相对仓库根目录”猜测；
#     无法唯一确定时不复用并说明原因。
project_file="$worktree_a/ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj"
cp "$project_file" "$TEMP_DIR/project.pbxproj.backup"
# $1 追加到 Resources 分组的 children，$2 是追加的对象定义。
with_extra_references() {
  cp "$TEMP_DIR/project.pbxproj.backup" "$project_file"
  EXTRA_CHILDREN="$1" EXTRA_OBJECTS="$2" ruby -i -pe '
    sub("children = (AAA);", "children = (AAA, #{ENV.fetch("EXTRA_CHILDREN")});")
    sub("/* extra */", ENV.fetch("EXTRA_OBJECTS"))
  ' "$project_file"
}
with_extra_references EXTRA \
  'EXTRA = {isa = PBXFileReference; path = "../../../docs/missing.md"; sourceTree = "<group>"; };'
assert_rebuild "无法确认构建输入：工程引用的外部路径无法解析：../../../docs/missing.md" "$worktree_a"
with_extra_references EXTRA 'EXTRA = {isa = PBXFileReference; path = shared.md; sourceTree = CUSTOM_ROOT; };'
assert_rebuild "工程引用使用了无法确认的 sourceTree：CUSTOM_ROOT" "$worktree_a"
with_extra_references EXTRA \
  'EXTRA = {isa = PBXShellScriptBuildPhase; shellScript = "bash \"$SRCROOT/../$(TOOLS_DIR)/run.sh\"\n"; };'
assert_rebuild "工程引用含变量或通配符，无法确认：\$SRCROOT/../\$(TOOLS_DIR" "$worktree_a"
# 分组目录是符号链接时，文件系统解析出的文件与按路径字面计算的不同，不能确定 Xcode 读哪一个。
mkdir -p "$worktree_a/docs/nested"
ln -s ../../../docs/nested "$worktree_a/ios/MimiRemote/Resources/Linked"
printf 'shadow\n' > "$worktree_a/ios/MimiRemote/Resources/support.md"
with_extra_references EXTRA \
  'EXTRA = {isa = PBXGroup; children = (EXTRAFILE); path = Linked; sourceTree = "<group>"; }; EXTRAFILE = {isa = PBXFileReference; path = ../support.md; sourceTree = "<group>"; };'
assert_rebuild "工程引用的外部路径经过符号链接，无法确认实际文件：../support.md" "$worktree_a"
rm -rf "$worktree_a/ios/MimiRemote/Resources/Linked" "$worktree_a/ios/MimiRemote/Resources/support.md" \
  "$worktree_a/docs/nested"
cp "$TEMP_DIR/project.pbxproj.backup" "$project_file"
assert_reusable "$worktree_a"

# 10a. pbxproj 解析器不可用或失败（例如 Linux 主机没有 plutil）时不复用，并说明原因。
mkdir -p "$TEMP_DIR/broken-plutil-bin"
printf '#!/usr/bin/env bash\necho "plutil unavailable" >&2\nexit 1\n' \
  > "$TEMP_DIR/broken-plutil-bin/plutil"
chmod +x "$TEMP_DIR/broken-plutil-bin/plutil"
assert_rebuild "无法确认构建输入：无法解析 project.pbxproj：plutil unavailable" "$worktree_a" \
  PATH="$TEMP_DIR/broken-plutil-bin:$PATH"
assert_reusable "$worktree_a"

# 10b. 引用实际指向 ios/Shared，而仓库根目录恰好也有 Shared：必须为 ios/Shared 算指纹。
#      工程外分组下的普通子路径、以 SRCROOT 为基准的构建设置也必须纳入。
mkdir -p "$worktree_a/ios/Shared" "$worktree_a/Shared" "$worktree_a/docs/group" "$worktree_a/config"
printf 'real\n' > "$worktree_a/ios/Shared/notes.md"
printf 'decoy\n' > "$worktree_a/Shared/notes.md"
printf 'inner\n' > "$worktree_a/docs/group/inner.md"
printf '<plist/>\n' > "$worktree_a/config/Extra-Info.plist"
with_extra_references "EXTRA, EXTRAGROUP" \
  'EXTRA = {isa = PBXFileReference; path = ../../Shared/notes.md; sourceTree = "<group>"; }; EXTRAGROUP = {isa = PBXGroup; children = (EXTRAINNER); path = ../../../docs/group; sourceTree = "<group>"; }; EXTRAINNER = {isa = PBXFileReference; path = inner.md; sourceTree = "<group>"; }; EXTRACFG = {isa = XCBuildConfiguration; buildSettings = {INFOPLIST_FILE = ../../config/Extra-Info.plist; }; };'
git -C "$worktree_a" add -A
git -C "$worktree_a" commit -qm "external references"
bash "$worktree_a/scripts/ios-dev.sh" build-for-testing >/dev/null
assert_reusable "$worktree_a"
printf 'changed\n' >> "$worktree_a/Shared/notes.md"
assert_reusable "$worktree_a"
git -C "$worktree_a" checkout -q -- Shared/notes.md
printf 'changed\n' >> "$worktree_a/ios/Shared/notes.md"
assert_rebuild "ios/Shared/notes.md" "$worktree_a"
git -C "$worktree_a" checkout -q -- ios/Shared/notes.md
printf 'changed\n' >> "$worktree_a/docs/group/inner.md"
assert_rebuild "docs/group/inner.md" "$worktree_a"
git -C "$worktree_a" checkout -q -- docs/group/inner.md
printf 'changed\n' >> "$worktree_a/config/Extra-Info.plist"
assert_rebuild "config/Extra-Info.plist" "$worktree_a"
git -C "$worktree_a" checkout -q -- config/Extra-Info.plist
assert_reusable "$worktree_a"
git -C "$worktree_a" reset -q --hard HEAD~1
bash "$worktree_a/scripts/ios-dev.sh" build-for-testing >/dev/null
assert_reusable "$worktree_a"

# 11. 另一个 Worktree 共用同一 DerivedData，但不继承 A 的证据；B 构建覆盖共享产物
#     后，A 的编译结论仍按 A 自己的输入判断。
worktree_b="$TEMP_DIR/worktree-b"
git -C "$worktree_a" worktree add -q --detach "$worktree_b" HEAD
b_derived="$(
  IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID=M5-27-UDID \
    bash "$worktree_b/scripts/ios-dev.sh" target | awk -F 'DerivedData: ' '/^DerivedData:/ { print $2 }'
)"
assert_equal "$m5_derived" "$b_derived" "同仓库 Worktree 必须共用同一 M5 DerivedData"
assert_rebuild "没有本 Worktree" "$worktree_b"
builds_before_b="$(build_count)"
run_quick "$worktree_b" "$TEMP_DIR/worktree-b.log"
assert_equal "0" "$quick_status" "B 的 quick 必须正常构建"
assert_contains "$(cat "$TEMP_DIR/worktree-b.log")" "构建证据不可复用：没有本 Worktree" \
  "B 不得继承 A 的证据"
assert_equal "$((builds_before_b + 1))" "$(build_count)" "B 必须真正构建"
assert_reusable "$worktree_b"
assert_reusable "$worktree_a"
record_count="$(find "$m5_derived/MimiBuildEvidence" -name '*.record' | awk 'END { print NR }')"
assert_equal "2" "$record_count" "每个 Worktree 必须使用独立证据文件"

# 12. 证据格式不符或 DerivedData 被清理时必须重建。
a_record="$(grep -l "^worktree	$(cd "$worktree_a" && pwd -P)$" "$m5_derived/MimiBuildEvidence/"*.record)"
sed 's/^schema	[0-9][0-9]*$/schema	0/' "$a_record" > "$a_record.tmp"
mv "$a_record.tmp" "$a_record"
assert_rebuild "证据格式已变化" "$worktree_a"
rm -rf "$m5_derived"
assert_rebuild "没有本 Worktree" "$worktree_a"
assert_rebuild "没有本 Worktree" "$worktree_b"
builds_before_cleanup_rebuild="$(build_count)"
run_quick "$worktree_a" "$TEMP_DIR/after-cleanup.log"
assert_equal "0" "$quick_status" "清理缓存后 quick 必须重新构建并通过"
assert_equal "$((builds_before_cleanup_rebuild + 1))" "$(build_count)" "清理缓存后必须重新构建"
assert_reusable "$worktree_a"

printf 'iOS 构建证据的复用、失效（含构建环境与工程外引用）、失败不记录、跨 Worktree 隔离、缓存清理和排队提示检查通过。\n'
