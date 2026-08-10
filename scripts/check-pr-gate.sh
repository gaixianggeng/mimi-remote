#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "PR Gate 自检失败：$1" >&2
  exit 1
}

for command_name in bash grep mktemp ruby; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

for script_path in \
  scripts/ci-pr-scope.sh \
  scripts/check-critical-regressions.sh \
  scripts/check-nightly-release.sh \
  scripts/check-release-source.sh \
  scripts/check-pr-gate.sh \
  scripts/verify-change.sh \
  scripts/test-verify-change.sh \
  scripts/test-macos-app.sh; do
  bash -n -- "$script_path"
done

bash ./scripts/test-verify-change.sh
bash ./scripts/check-critical-regressions.sh
bash ./scripts/check-nightly-release.sh
bash ./scripts/check-release-source.sh --self-test

test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-pr-gate-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

assert_scope() {
  local case_name="$1"
  local expected_go="$2"
  local expected_ios="$3"
  local expected_rust="$4"
  local expected_macos="$5"
  shift 5

  local paths_path="$test_root/${case_name}.paths"
  local output_path="$test_root/${case_name}.output"
  printf '%s\0' "$@" > "$paths_path"
  bash ./scripts/ci-pr-scope.sh --paths-file "$paths_path" > "$output_path"

  grep -Fqx "go=$expected_go" "$output_path" \
    || fail "${case_name} 的 Go 分类错误。"
  grep -Fqx "ios=$expected_ios" "$output_path" \
    || fail "${case_name} 的 iOS 分类错误。"
  grep -Fqx "rust=$expected_rust" "$output_path" \
    || fail "${case_name} 的 Rust 分类错误。"
  grep -Fqx "macos=$expected_macos" "$output_path" \
    || fail "${case_name} 的 Mac App 分类错误。"
}

assert_scope go_only true false false false internal/httpapi/router.go
assert_scope ios_only false true false false ios/MimiRemote/Sources/App/MimiRemoteApp.swift
assert_scope rust_only false false true false bridges/claude/crates/claude-bridge/src/main.rs
assert_scope macos_only false false false true macos/MimiRemoteMac/Sources/App/MimiRemoteMacApp.swift
assert_scope macos_runner false false false true scripts/test-macos-app.sh
assert_scope release true false false false scripts/check-release-artifacts.sh
assert_scope release_source true false false false scripts/check-release-source.sh
assert_scope windows_release true false false false scripts/build-windows-installer.ps1
assert_scope ios_release false true false false scripts/ios_testflight_ci.sh
assert_scope ios_asc_pin false true false false config/release/ios-asc-cli.env
assert_scope ios_asc_test false true false false scripts/test-ios-asc-cli.sh
assert_scope mimi_contract true true false false contracts/mimi-protocol/contract.json
assert_scope mimi_contract_generator true true false false internal/protocolcontract/cmd/generate/main.go
assert_scope mimi_contract_checker true false false false scripts/check-mimi-protocol-contract.sh
assert_scope critical_runner true true false false scripts/test-conversation-regressions.sh
assert_scope critical_checker true true false false scripts/check-critical-regressions.sh
assert_scope nightly_checker true true false false scripts/check-nightly-release.sh
assert_scope nightly_docs true true false false docs/nightly-release.md
assert_scope ios_device_lease false true false false scripts/ios-device-lease.sh
assert_scope ios_device_management false true false false scripts/test-ios-device-management.sh
assert_scope ios_device_fixture false true false false scripts/testdata/ios-device-management/simulators.json
assert_scope docs_only false false false false CONTRIBUTING.md
assert_scope workflow true true true true .github/workflows/pr-gate.yml
assert_scope mixed true true true false \
  cmd/agentd/main.go \
  ios/MimiRemote/project.yml \
  Cargo.lock

ruby <<'RUBY'
require "yaml"

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true)
rescue Psych::SyntaxError => error
  abort("PR Gate 自检失败：#{path} YAML 无法解析：#{error.message}")
end

def triggers(workflow, path)
  value = workflow["on"] || workflow[true]
  abort("PR Gate 自检失败：#{path} 缺少 on。") unless value.is_a?(Hash)
  value
end

gate_path = ".github/workflows/pr-gate.yml"
gate = load_workflow(gate_path)
abort("PR Gate 自检失败：workflow 名称必须稳定为 PR Gate。") unless gate["name"] == "PR Gate"

gate_triggers = triggers(gate, gate_path)
abort("PR Gate 自检失败：PR Gate 必须监听所有 pull_request。") unless gate_triggers.key?("pull_request")
pull_request_trigger = gate_triggers["pull_request"]
if pull_request_trigger.is_a?(Hash) && (pull_request_trigger.key?("paths") || pull_request_trigger.key?("paths-ignore"))
  abort("PR Gate 自检失败：PR Gate 顶层禁止 paths/paths-ignore。")
end

unless gate.dig("concurrency", "cancel-in-progress") == true
  abort("PR Gate 自检失败：必须保留 cancel-in-progress。")
end

expected_calls = {
  "codex-protocol" => "./.github/workflows/codex-protocol.yml",
  "repository-safety" => "./.github/workflows/public-repo-safety.yml",
  "go" => "./.github/workflows/go-ci.yml",
  "ios" => "./.github/workflows/ios-ci.yml",
  "rust" => "./.github/workflows/claude-bridge-ci.yml",
  "macos" => "./.github/workflows/macos-ci.yml",
}
jobs = gate.fetch("jobs")
scope_job = jobs.fetch("scope")
expected_scope_outputs = %w[go ios rust macos]
unless scope_job.fetch("outputs").keys.sort == expected_scope_outputs.sort
  abort("PR Gate 自检失败：Change scope 输出集合不完整。")
end
expected_scope_outputs.each do |name|
  unless scope_job.dig("outputs", name).to_s.include?("steps.scope.outputs.#{name}")
    abort("PR Gate 自检失败：Change scope 没有透传 #{name} 输出。")
  end
end

expected_calls.each do |job_id, workflow_path|
  unless jobs.dig(job_id, "uses") == workflow_path
    abort("PR Gate 自检失败：#{job_id} 没有调用 #{workflow_path}。")
  end
end
unless jobs.dig("macos", "if").to_s.include?("needs.scope.outputs.macos")
  abort("PR Gate 自检失败：Mac App job 没有按 macos scope 执行。")
end

final_gate = jobs.fetch("gate")
abort("PR Gate 自检失败：最终 check 名称必须为 PR Gate。") unless final_gate["name"] == "PR Gate"
unless final_gate["if"].to_s.include?("always()")
  abort("PR Gate 自检失败：最终聚合 job 必须在上游失败或跳过时仍执行。")
end
expected_needs = %w[scope codex-protocol repository-safety go ios rust macos]
unless Array(final_gate["needs"]).sort == expected_needs.sort
  abort("PR Gate 自检失败：最终聚合 job 的 needs 不完整。")
end
%w[MACOS_REQUIRED MACOS_RESULT].each do |name|
  unless final_gate.to_s.include?(name)
    abort("PR Gate 自检失败：最终聚合缺少 #{name} 判断。")
  end
end

macos_path = ".github/workflows/macos-ci.yml"
macos_workflow = load_workflow(macos_path)
macos_triggers = triggers(macos_workflow, macos_path)
macos_push_paths = Array(macos_triggers.dig("push", "paths"))
unless macos_push_paths.include?("macos/MimiRemoteMac/**") &&
       macos_push_paths.include?("scripts/test-macos-app.sh")
  abort("PR Gate 自检失败：Mac App CI 的 main push paths 与 PR scope 不一致。")
end
macos_job = macos_workflow.fetch("jobs").fetch("build-and-test")
unless macos_job["runs-on"] == "macos-26" && macos_job["timeout-minutes"] == 20
  abort("PR Gate 自检失败：Mac App CI 必须使用 macOS 26 runner 和 20 分钟超时。")
end
unless macos_job.to_s.include?("bash ./scripts/test-macos-app.sh")
  abort("PR Gate 自检失败：Mac App CI 没有运行统一编译测试入口。")
end
macos_test_script = File.read("scripts/test-macos-app.sh")
%w[xcodebuild CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test].each do |fragment|
  unless macos_test_script.include?(fragment)
    abort("PR Gate 自检失败：Mac App 编译测试入口缺少 #{fragment}。")
  end
end

expected_calls.values.each do |workflow_path|
  called_workflow = load_workflow(workflow_path)
  called_triggers = triggers(called_workflow, workflow_path)
  unless called_triggers.key?("workflow_call")
    abort("PR Gate 自检失败：#{workflow_path} 缺少 workflow_call。")
  end
  if called_triggers.key?("pull_request")
    abort("PR Gate 自检失败：#{workflow_path} 不应绕过 PR Gate 单独监听 pull_request。")
  end
end
RUBY

rm -rf "$test_root"
trap - EXIT

echo "PR Gate 自检通过：触发器、聚合依赖和路径分类均符合预期。"
