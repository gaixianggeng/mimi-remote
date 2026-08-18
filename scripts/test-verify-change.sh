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
trap 'rm -rf "$test_root"' EXIT

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
assert_contains "$ios_output" "ios-dev.sh build-for-testing"
assert_contains "$ios_output" "docs=false"
assert_contains "$ios_output" "check-source-size.sh"
assert_not_contains "$ios_output" "go test"
assert_not_contains "$ios_output" "cargo test"

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
assert_not_contains "$ios_full_output" "test-ios-localization-smoke.sh"
assert_not_contains "$ios_full_output" "ios-dev.sh build-for-testing"

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
assert_contains "$device_control_output" "test-ios-device-management.sh"
assert_not_contains "$device_control_output" "ios-dev.sh build-for-testing"

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
assert_contains "$contract_output" "ios-dev.sh build-for-testing"
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
assert_contains "$collection_output" "ios-dev.sh build-for-testing"
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

rm -rf "$test_root"
trap - EXIT

echo "分层验证自测通过：docs/iOS/Go/Rust/contract/release/unknown、Gate 去重与四类 Git 变更来源均符合预期。"
