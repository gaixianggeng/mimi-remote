#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "分层验证自测失败：$1" >&2
  exit 1
}

for command_name in bash chmod cp git grep mkdir mktemp printf rm; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-verify-change-test.XXXXXX")"
runner_pid=""
unrelated_pid=""
cleanup() {
  [[ -z "$runner_pid" ]] || kill -TERM "$runner_pid" 2>/dev/null || true
  [[ -z "$unrelated_pid" ]] || kill -TERM "$unrelated_pid" 2>/dev/null || true
  [[ -z "$runner_pid" ]] || wait "$runner_pid" 2>/dev/null || true
  [[ -z "$unrelated_pid" ]] || wait "$unrelated_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

assert_contains() {
  local output="$1"
  local expected="$2"
  printf '%s\n' "$output" | grep -Fq -- "$expected" \
    || fail "输出缺少：${expected}"
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  if printf '%s\n' "$output" | grep -Fq -- "$unexpected"; then
    fail "输出不应包含：${unexpected}"
  fi
}

assert_plan() {
  local case_name="$1"
  shift
  local path_file="$test_root/${case_name}.paths"
  : > "$path_file"
  printf '%s\0' "$@" > "$path_file"
  bash ./scripts/verify-change.sh --plan --paths-file "$path_file"
}

assert_full_plan() {
  local case_name="$1"
  shift
  local path_file="$test_root/${case_name}.paths"
  : > "$path_file"
  printf '%s\0' "$@" > "$path_file"
  bash ./scripts/verify-change.sh --plan --full --paths-file "$path_file"
}

docs_output="$(assert_plan docs_only CONTRIBUTING.md docs/support.md)"
assert_contains "$docs_output" "判定：纯文档/静态内容"
assert_contains "$docs_output" "PR Gate scope：go=false, ios=false, rust=false, macos=false, docs=true"
assert_contains "$docs_output" "bash ./scripts/check-docs-static.sh"
assert_not_contains "$docs_output" "ios-dev.sh build-for-testing"
assert_not_contains "$docs_output" "ios-dev.sh target"
assert_not_contains "$docs_output" "ios-dev.sh leases"
assert_not_contains "$docs_output" "go test"
assert_not_contains "$docs_output" "cargo test"
assert_contains "$docs_output" "Go：没有直接 Go 产品路径"
assert_contains "$docs_output" "iOS：没有直接 iOS 产品路径"

nested_docs_output="$(assert_plan nested_docs ios/MimiRemote/README.md bridges/claude/README.md)"
assert_contains "$nested_docs_output" "判定：纯文档/静态内容"
assert_not_contains "$nested_docs_output" "ios-dev.sh build-for-testing"
assert_not_contains "$nested_docs_output" "cargo test"

ios_output="$(assert_plan ios_only ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift)"
assert_contains "$ios_output" "iOS quick 只编译 App，不编译或运行 XCTest"
assert_contains "$ios_output" "IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID= IOS_SIMULATOR_NAME='iPad Pro 13-inch (M5)' bash ./scripts/ios-dev.sh build"
assert_contains "$ios_output" "当前：quick；只在最后一次代码修改后执行一次"
assert_contains "$ios_output" "自动高风险信号：未检测到"
assert_contains "$ios_output" "docs=false"
assert_contains "$ios_output" "check-source-size.sh"
assert_not_contains "$ios_output" "ios-dev.sh build-for-testing"
assert_not_contains "$ios_output" "ios-dev.sh target"
assert_not_contains "$ios_output" "ios-dev.sh leases"
assert_not_contains "$ios_output" "go test"
assert_not_contains "$ios_output" "cargo test"

ios_execution_paths="$test_root/ios-execution.paths"
ios_execution_xcodebuild_log="$test_root/ios-execution-xcodebuild.log"
ios_execution_tailcat_log="$test_root/ios-execution-tailcat.log"
ios_execution_lease_root="$test_root/ios-execution-leases"
printf '%s\0' ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift \
  > "$ios_execution_paths"
: > "$ios_execution_xcodebuild_log"
: > "$ios_execution_tailcat_log"
ios_execution_output="$(
  IOS_XCRUN_BIN="$ROOT_DIR/scripts/testdata/ios-device-management/fake-xcrun.sh" \
  IOS_XCODEBUILD_BIN="$ROOT_DIR/scripts/testdata/ios-device-management/fake-xcodebuild.sh" \
  IOS_TAILCAT_BUILD_SCRIPT="$ROOT_DIR/scripts/testdata/ios-device-management/fake-tailcat-mobile-build.sh" \
  IOS_TEST_SIMULATORS_JSON="$ROOT_DIR/scripts/testdata/ios-device-management/simulators.json" \
  IOS_TEST_PHYSICAL_JSON="$ROOT_DIR/scripts/testdata/ios-device-management/no-physical-devices.json" \
  IOS_TEST_XCODEBUILD_LOG="$ios_execution_xcodebuild_log" \
  IOS_TEST_TAILCAT_BUILD_LOG="$ios_execution_tailcat_log" \
  IOS_DEVICE_LEASE_ROOT="$ios_execution_lease_root" \
  bash ./scripts/verify-change.sh --paths-file "$ios_execution_paths"
)"
assert_contains "$ios_execution_output" "iOS quick 只编译 App，不编译或运行 XCTest"
assert_contains "$(<"$ios_execution_xcodebuild_log")" \
  "-destination platform=iOS Simulator,id=M5-27-UDID"
assert_contains "$(<"$ios_execution_xcodebuild_log")" \
  "CODE_SIGNING_ALLOWED=NO build"
assert_not_contains "$(<"$ios_execution_xcodebuild_log")" "build-for-testing"
assert_contains "$(<"$ios_execution_tailcat_log")" "build"
[[ ! -d "$ios_execution_lease_root/M5-27-UDID.lease" ]] \
  || fail "iOS quick 结束后必须释放固定 Simulator 租约。"

tailcat_output="$(assert_plan tailcat experiments/tailcat/mobile/tailcatmobile/tailcatmobile.go)"
assert_contains "$tailcat_output" "PR Gate scope：go=false, ios=true"
assert_contains "$tailcat_output" "(cd experiments/tailcat && go test ./... -count=1)"
assert_contains "$tailcat_output" "iOS quick 只编译 App，不编译或运行 XCTest"
assert_not_contains "$tailcat_output" "ios-dev.sh build-for-testing"
assert_not_contains "$tailcat_output" "Go 受影响范围使用完整回归"

go_output="$(assert_plan go_only internal/httpapi/router.go)"
assert_contains "$go_output" "go test ./internal/httpapi -count=1"
assert_not_contains "$go_output" "ios-dev.sh build-for-testing"

go_fixture_output="$(assert_plan go_fixture internal/httpapi/testdata/request.json)"
assert_contains "$go_fixture_output" "go test ./internal/httpapi -count=1"

rust_leaf_output="$(assert_plan rust_leaf bridges/claude/crates/claude-bridge/src/lib.rs)"
assert_contains "$rust_leaf_output" "-p alleycat-claude-bridge"
assert_not_contains "$rust_leaf_output" "-p alleycat-bridge-core"
assert_not_contains "$rust_leaf_output" "-p alleycat-codex-proto"

rust_shared_output="$(assert_plan rust_shared bridges/claude/crates/codex-proto/src/lib.rs)"
assert_contains "$rust_shared_output" "-p alleycat-codex-proto"
assert_contains "$rust_shared_output" "-p alleycat-bridge-core"
assert_contains "$rust_shared_output" "-p alleycat-claude-bridge"

ios_full_output="$(assert_full_plan ios_full ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift)"
assert_contains "$ios_full_output" "test-conversation-regressions.sh"
assert_contains "$ios_full_output" "--ios-only"
assert_contains "$ios_full_output" "当前：full；交付报告必须说明命中的高风险条件"
assert_not_contains "$ios_full_output" "test-ios-localization-smoke.sh"
assert_not_contains "$ios_full_output" "ios-dev.sh build-for-testing"
assert_not_contains "$ios_full_output" "ios-dev.sh target"
assert_not_contains "$ios_full_output" "ios-dev.sh leases"
assert_not_contains "$ios_full_output" "bash ./scripts/check-public-repo-safety.sh"
assert_not_contains "$ios_full_output" "CODE_SIGNING_ALLOWED=NO build"
assert_contains "$ios_full_output" "bash ./scripts/check-pr-gate.sh"
assert_contains "$ios_full_output" "专项缺项："
assert_contains "$ios_full_output" "不因语言数量自动升级 full"
assert_contains "$ios_full_output" "等待时保持 Verify，成功和失败均回原任务收尾"

verify_full_output="$(assert_full_plan verify_full scripts/verify-change.sh)"
assert_contains "$verify_full_output" "bash ./scripts/check-pr-gate.sh"
assert_not_contains "$verify_full_output" "分层验证入口或说明变化必须通过无设备自测"

mixed_full_output="$(assert_full_plan mixed_full internal/httpapi/router.go ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift)"
assert_contains "$mixed_full_output" "go test ./... -count=1"
assert_contains "$mixed_full_output" "test-conversation-regressions.sh --ios-only"

rust_full_output="$(assert_full_plan rust_full bridges/claude/crates/claude-bridge/src/lib.rs)"
assert_contains "$rust_full_output" "-p alleycat-codex-proto"
assert_contains "$rust_full_output" "-p alleycat-bridge-core"
assert_contains "$rust_full_output" "-p alleycat-claude-bridge"

security_output="$(assert_plan security_control scripts/check-public-repo-safety.sh)"
assert_contains "$security_output" "bash ./scripts/check-public-repo-safety.sh"

security_self_test_output="$(assert_plan security_self_test scripts/test-public-repo-safety.sh)"
assert_contains "$security_self_test_output" "bash ./scripts/check-public-repo-safety.sh"

security_workflow_output="$(assert_plan security_workflow .github/workflows/public-repo-safety.yml)"
assert_contains "$security_workflow_output" "bash ./scripts/check-public-repo-safety.sh"
assert_not_contains "$security_workflow_output" "bash ./scripts/check-pr-gate.sh"

security_verify_output="$(assert_plan security_verify scripts/check-public-repo-safety.sh scripts/verify-change.sh)"
assert_contains "$security_verify_output" "bash ./scripts/check-public-repo-safety.sh"
assert_not_contains "$security_verify_output" "分层验证入口或说明变化必须通过无设备自测"
security_full_output="$(assert_full_plan security_full scripts/check-public-repo-safety.sh)"
assert_contains "$security_full_output" "bash ./scripts/check-public-repo-safety.sh"
assert_not_contains "$security_full_output" "bash ./scripts/check-pr-gate.sh"

privacy_output="$(assert_plan ios_privacy ios/MimiRemote/Sources/Resources/PrivacyInfo.xcprivacy)"
assert_contains "$privacy_output" "check-ios-network-security.sh"
assert_contains "$privacy_output" "check-ios-privacy-manifest.sh"

ruby_output="$(assert_plan ruby_control scripts/distribute_internal_build.rb)"
assert_contains "$ruby_output" "ruby -c -- scripts/distribute_internal_build.rb"

python_output="$(assert_plan python_control scripts/prepare-ios-store-screenshots.py)"
assert_contains "$python_output" "Python 脚本先做无产物语法检查"

powershell_output="$(assert_plan powershell_control scripts/check-windows-installer.ps1)"
assert_contains "$powershell_output" "延后到 Windows CI"

device_control_output="$(assert_plan device_control scripts/ios-dev.sh)"
assert_contains "$device_control_output" "test-tailcat-mobile-build.sh"
assert_contains "$device_control_output" "test-ios-device-management.sh"
assert_contains "$device_control_output" "test-ios-device-gui-handoff-macos.sh"
assert_not_contains "$device_control_output" "ios-dev.sh build-for-testing"

gui_handoff_control_output="$(assert_plan gui_handoff_control scripts/ios-device-gui-handoff-macos.sh)"
assert_contains "$gui_handoff_control_output" "test-ios-device-gui-handoff-macos.sh"

asc_control_output="$(assert_plan asc_control scripts/ios_asc_cli.sh)"
assert_contains "$asc_control_output" "test-ios-asc-cli.sh"

critical_control_output="$(assert_plan critical_control scripts/test-conversation-regressions.sh)"
assert_contains "$critical_control_output" "check-critical-regressions.sh"
assert_not_contains "$critical_control_output" "ios-dev.sh build-for-testing"

linear_control_output="$(assert_plan linear_control config/automations/mimi-linear-issue.prompt.md)"
assert_contains "$linear_control_output" "check-linear-polling-safety.sh"

restart_control_output="$(assert_plan restart_control scripts/restart-agentd-dev-macos.sh)"
assert_contains "$restart_control_output" "restart-agentd-dev-macos.sh --self-test"

contract_output="$(assert_plan contract contracts/mimi-protocol/contract.json)"
assert_contains "$contract_output" "check-mimi-protocol-contract.sh"
assert_contains "$contract_output" "iOS quick 只编译 App，不编译或运行 XCTest"
assert_contains "$contract_output" "自动高风险信号：检测到 Go/iOS 共享协议路径"
assert_not_contains "$contract_output" "ios-dev.sh build-for-testing"
assert_not_contains "$contract_output" "go test ./... -count=1"

contract_full_output="$(assert_full_plan contract_full contracts/mimi-protocol/contract.json)"
assert_contains "$contract_full_output" "go test ./... -count=1"

release_output="$(assert_plan release_control .github/workflows/release.yml)"
assert_contains "$release_output" "判定：CI/脚本/发布控制面"
assert_contains "$release_output" "bash ./scripts/check-pr-gate.sh"
assert_contains "$release_output" "check-nightly-release.sh --self-test"
assert_not_contains "$release_output" "check-nightly-release.sh --check"
assert_not_contains "$release_output" "ios-dev.sh build-for-testing"

release_checker_output="$(assert_plan release_checker scripts/check-nightly-release.sh)"
assert_contains "$release_checker_output" "check-nightly-release.sh --check"
assert_contains "$release_checker_output" "check-nightly-release.sh --self-test"

release_generator_output="$(assert_plan release_generator scripts/generate-nightly-what-to-test.rb)"
assert_contains "$release_generator_output" "ruby -c -- scripts/generate-nightly-what-to-test.rb"
assert_contains "$release_generator_output" "check-nightly-release.sh --check"
assert_contains "$release_generator_output" "check-nightly-release.sh --self-test"

release_config_output="$(assert_plan release_config config/release/ios-asc-cli.env)"
assert_contains "$release_config_output" "check-nightly-release.sh --check"

unknown_output="$(assert_plan unknown assets/example.bin)"
assert_contains "$unknown_output" "没有验证映射"
unknown_paths_file="$test_root/unknown-execution.paths"
printf '%s\0' assets/example.bin > "$unknown_paths_file"
if bash ./scripts/verify-change.sh --paths-file "$unknown_paths_file" >/dev/null 2>&1; then
  fail "未映射路径在执行模式下必须 fail-closed。"
fi

gate_output="$(assert_plan gate_dedup scripts/check-pr-gate.sh scripts/verify-change.sh)"
assert_contains "$gate_output" "bash ./scripts/check-pr-gate.sh"
assert_not_contains "$gate_output" "分层验证入口或说明变化必须通过无设备自测"

# 在临时仓库同时制造 committed/staged/unstaged/untracked 四类变化，证明默认收集链路
# 不依赖当前工作区状态，也不会启动任何编译、测试或 Simulator。
repo_root="$test_root/repository"
mkdir -p "$repo_root/scripts"
cp scripts/verify-change.sh scripts/ci-pr-scope.sh "$repo_root/scripts/"
chmod +x "$repo_root/scripts/verify-change.sh" "$repo_root/scripts/ci-pr-scope.sh"
git -C "$repo_root" init -q
git -C "$repo_root" config user.name "Mimi Verify Test"
git -C "$repo_root" config user.email "verify-test@example.invalid"
printf '# baseline\n' > "$repo_root/README.md"
git -C "$repo_root" add .
git -C "$repo_root" commit -q -m baseline

mkdir -p "$repo_root/internal/httpapi"
printf 'package httpapi\n' > "$repo_root/internal/httpapi/committed.go"
git -C "$repo_root" add internal/httpapi/committed.go
git -C "$repo_root" commit -q -m committed

mkdir -p "$repo_root/ios/MimiRemote/Sources" "$repo_root/bridges/claude"
printf 'struct Staged {}\n' > "$repo_root/ios/MimiRemote/Sources/Staged.swift"
git -C "$repo_root" add ios/MimiRemote/Sources/Staged.swift
printf 'unstaged\n' >> "$repo_root/README.md"
printf 'fn main() {}\n' > "$repo_root/bridges/claude/untracked.rs"

collection_output="$(cd "$repo_root" && bash ./scripts/verify-change.sh --plan --base HEAD~1)"
assert_contains "$collection_output" "committed=1, staged=1, unstaged=1, untracked=1"
assert_contains "$collection_output" "internal/httpapi/committed.go"
assert_contains "$collection_output" "ios/MimiRemote/Sources/Staged.swift"
assert_contains "$collection_output" "bridges/claude/untracked.rs"
assert_contains "$collection_output" "go test ./internal/httpapi -count=1"
assert_contains "$collection_output" "iOS quick 只编译 App，不编译或运行 XCTest"
assert_contains "$collection_output" "自动高风险信号：检测到多个产品栈"
assert_not_contains "$collection_output" "ios-dev.sh build-for-testing"
assert_contains "$collection_output" "cargo test --locked"

# base 与 HEAD 都存在但没有共同祖先时，git diff 必须显式失败；不能把退出码
# 吞掉后误报为“没有发现需要验证的变更”。
empty_tree="$(git -C "$repo_root" mktree </dev/null)"
unrelated_commit="$(printf 'unrelated\n' | git -C "$repo_root" commit-tree "$empty_tree")"
collection_failure_output="$test_root/collection-failure.output"
if (cd "$repo_root" && bash ./scripts/verify-change.sh --plan --base "$unrelated_commit") \
  >"$collection_failure_output" 2>&1; then
  fail "无 merge-base 时必须传播 committed 路径收集失败。"
fi
assert_contains "$(<"$collection_failure_output")" "无法收集 committed 变更路径。"

# 执行层用独立临时仓库与 fake 工具，覆盖失败汇总和真实进程取消，绝不启动编译器。
execution_root="$test_root/execution-repository"
mkdir -p "$execution_root/scripts" "$execution_root/bin" "$execution_root/internal/example"
cp scripts/verify-change.sh scripts/ci-pr-scope.sh "$execution_root/scripts/"
printf 'package example\n' > "$execution_root/internal/example/example.go"
cat > "$execution_root/scripts/check-source-size.sh" <<'SH'
#!/usr/bin/env bash
printf 'preflight\n' >> "$VERIFY_TEST_CALLS"
exit "${VERIFY_TEST_PREFLIGHT_EXIT:-0}"
SH
cat > "$execution_root/bin/go" <<'SH'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "$VERIFY_TEST_CALLS"
printf 'go-log-first-line\n'
for ((line=0; line<60; line++)); do printf 'go-log-line-%s\n' "$line"; done
exit "${VERIFY_TEST_GO_EXIT:-0}"
SH
cat > "$execution_root/bin/cargo" <<'SH'
#!/usr/bin/env bash
printf 'cargo %s\n' "$*" >> "$VERIFY_TEST_CALLS"
printf 'quiet-cargo-success\n'
[[ "$1" != fmt ]] || exit "${VERIFY_TEST_FMT_EXIT:-0}"
exit 0
SH
cat > "$execution_root/scripts/ios-dev.sh" <<'SH'
#!/usr/bin/env bash
printf 'ios %s\n' "$*" >> "$VERIFY_TEST_CALLS"
if [[ -n "${VERIFY_TEST_HOLD:-}" ]]; then
  mkdir "$VERIFY_TEST_HOLD.lease"
  trap 'rm -rf "$VERIFY_TEST_HOLD.lease"' EXIT
  trap 'exit 143' TERM
  sleep 300 &
  child=$!
  printf '%s %s\n' "$$" "$child" > "$VERIFY_TEST_HOLD"
  wait "$child"
fi
exit "${VERIFY_TEST_IOS_EXIT:-0}"
SH
chmod +x "$execution_root/bin/go" "$execution_root/bin/cargo"
git -C "$execution_root" init -q
git -C "$execution_root" config user.name "Mimi Verify Test"
git -C "$execution_root" config user.email "verify-test@example.invalid"
git -C "$execution_root" add .
git -C "$execution_root" commit -qm baseline
execution_paths="$test_root/execution.paths"
printf '%s\0' internal/example/example.go ios/MimiRemote/Sources/Example.swift \
  bridges/claude/crates/claude-bridge/src/lib.rs > "$execution_paths"
execution_calls="$test_root/execution.calls"
execution_output="$test_root/execution.output"

run_execution_case() {
  : > "$execution_calls"
  execution_code=0
  (cd "$execution_root" && env PATH="$execution_root/bin:$PATH" TMPDIR="$test_root" \
    VERIFY_TEST_CALLS="$execution_calls" "$@" \
    bash ./scripts/verify-change.sh --paths-file "$execution_paths") \
    > "$execution_output" 2>&1 || execution_code=$?
  execution_summary="$(sed -n 's/^结果汇总：//p' "$execution_output")"
  [[ -f "$execution_summary" ]] || fail "执行后必须留下结果汇总。"
}

run_execution_case VERIFY_TEST_GO_EXIT=7
[[ "$execution_code" -eq 7 ]] || fail "独立检查失败必须保留非零退出码。"
assert_contains "$(<"$execution_calls")" "ios build"
assert_contains "$(<"$execution_calls")" "cargo test --locked"
assert_contains "$(<"$execution_summary")" "失败 |"
assert_contains "$(<"$execution_summary")" "exit=7"
assert_contains "$(<"$execution_summary")" "通过 |"
assert_not_contains "$(<"$execution_output")" "go-log-first-line"
assert_not_contains "$(<"$execution_output")" "quiet-cargo-success"
assert_contains "$(<"$execution_output")" "go-log-line-59"
assert_contains "$(<"${execution_summary%/*}/3.log")" "go-log-first-line"
assert_contains "$(<"${execution_summary%/*}/plan.txt")" "PR Gate scope："

run_execution_case VERIFY_TEST_PREFLIGHT_EXIT=1
[[ "$execution_code" -eq 1 ]] || fail "前置失败不能算验证通过。"
assert_contains "$(<"$execution_summary")" "阻塞（前置检查失败）"
assert_not_contains "$(<"$execution_calls")" "go test ./internal/example"
assert_not_contains "$(<"$execution_calls")" "ios build"
assert_contains "$(<"$execution_calls")" "cargo test --locked"

run_execution_case VERIFY_TEST_FMT_EXIT=8
[[ "$execution_code" -eq 8 ]] || fail "Rust 前置失败不能算通过。"
assert_not_contains "$(<"$execution_calls")" "cargo test"
assert_contains "$(<"$execution_calls")" "go test ./internal/example"
assert_contains "$(<"$execution_calls")" "ios build"

run_execution_case VERIFY_TEST_IOS_EXIT=75
[[ "$execution_code" -eq 75 ]] || fail "设备阻塞必须保留退出码 75。"
assert_contains "$(<"$execution_summary")" "阻塞 |"
assert_contains "$(<"$execution_calls")" "cargo test --locked"

run_execution_case VERIFY_TEST_GO_EXIT=75 VERIFY_TEST_IOS_EXIT=9
[[ "$execution_code" -eq 9 ]] || fail "已有阻塞不能掩盖另一独立检查的真实失败。"
assert_contains "$(<"$execution_summary")" "阻塞 |"
assert_contains "$(<"$execution_summary")" "失败 |"

run_execution_case VERIFY_TEST_GO_EXIT=124
[[ "$execution_code" -eq 124 ]] || fail "子命令超时不能算通过。"
assert_contains "$(<"$execution_summary")" "超时 |"

run_execution_case VERIFY_TEST_GO_EXIT=130
[[ "$execution_code" -eq 130 ]] || fail "子命令取消必须使整轮取消。"
assert_contains "$(<"$execution_summary")" "取消 |"
assert_contains "$(<"$execution_summary")" "未运行 |"
assert_not_contains "$(<"$execution_calls")" "ios build"

# 同一 HEAD 下再次执行仍真正调用工具；这些日志不是自动跳过检查的缓存。
run_execution_case VERIFY_TEST_GO_EXIT=0
[[ "$execution_code" -eq 0 ]] || fail "全部检查通过应返回零。"
assert_contains "$(<"$execution_calls")" "go test ./internal/example"
assert_not_contains "$(<"$execution_output")" "go-log-line-59"
assert_not_contains "$(<"$execution_summary")" "未运行 |"

hold_file="$test_root/held-check.pids"
: > "$execution_calls"
sleep 300 &
unrelated_pid=$!
(cd "$execution_root" && exec env PATH="$execution_root/bin:$PATH" TMPDIR="$test_root" \
  VERIFY_TEST_CALLS="$execution_calls" VERIFY_TEST_HOLD="$hold_file" \
  bash ./scripts/verify-change.sh --paths-file "$execution_paths") > "$execution_output" 2>&1 &
runner_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ ! -s "$hold_file" ]] || break
  sleep 0.05
done
[[ -s "$hold_file" ]] || fail "取消测试未进入正在运行的检查。"
read -r held_pid held_child_pid < "$hold_file"
kill -TERM "$runner_pid"
execution_code=0
wait "$runner_pid" || execution_code=$?
runner_pid=""
[[ "$execution_code" -eq 143 ]] || fail "取消入口必须返回 143。"
execution_summary="$(sed -n 's/^结果汇总：//p' "$execution_output")"
[[ -f "$execution_summary" ]] || fail "取消后必须保留汇总。"
assert_contains "$(<"$execution_summary")" "取消 |"
assert_contains "$(<"$execution_summary")" "未运行 |"
[[ ! -d "$hold_file.lease" ]] || fail "取消后目标入口必须完成租约清理。"
if kill -0 "$held_pid" 2>/dev/null || kill -0 "$held_child_pid" 2>/dev/null; then
  fail "取消后本轮检查仍有子进程存活。"
fi
kill -0 "$unrelated_pid" 2>/dev/null || fail "取消误伤了不属于本轮检查的进程。"
kill -TERM "$unrelated_pid"
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=""

echo "分层验证自测通过：范围与来源、full 覆盖边界、失败汇总、有限日志、阻塞、取消和进程清理均符合预期。"
