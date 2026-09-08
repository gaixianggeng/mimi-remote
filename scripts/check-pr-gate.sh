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
  scripts/check-docs-static.sh \
  scripts/check-critical-regressions.sh \
  scripts/check-nightly-release.sh \
  scripts/check-release-source.sh \
  scripts/check-public-repo-safety.sh \
  scripts/test-public-repo-safety.sh \
  scripts/check-pr-gate.sh \
  scripts/verify-change.sh \
  scripts/test-verify-change.sh \
  scripts/test-macos-app.sh \
  macos/MimiRemoteMac/Scripts/embed-agentd.sh; do
  bash -n -- "$script_path"
done

bash ./scripts/test-verify-change.sh
bash ./scripts/check-critical-regressions.sh
bash ./scripts/check-nightly-release.sh
bash ./scripts/check-release-source.sh --self-test
bash ./scripts/test-public-repo-safety.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-pr-gate-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

assert_scope() {
  local case_name="$1"
  local expected_go="$2"
  local expected_ios="$3"
  local expected_rust="$4"
  local expected_macos="$5"
  local expected_docs="$6"
  shift 6

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
  grep -Fqx "docs=$expected_docs" "$output_path" \
    || fail "${case_name} 的 Docs/static 分类错误。"
}

assert_scope go_only true false false false false internal/httpapi/router.go
assert_scope ios_only false true false false false ios/MimiRemote/Sources/App/MimiRemoteApp.swift
assert_scope rust_only false false true false false bridges/claude/crates/claude-bridge/src/main.rs
assert_scope macos_only false false false true false macos/MimiRemoteMac/Sources/App/MimiRemoteMacApp.swift
assert_scope macos_runner false false false true false scripts/test-macos-app.sh
assert_scope release true false false false false scripts/check-release-artifacts.sh
assert_scope release_source true false false false false scripts/check-release-source.sh
assert_scope windows_release true false false false false scripts/build-windows-installer.ps1
assert_scope ios_release false true false false false scripts/ios_testflight_ci.sh
assert_scope ios_asc_pin false true false false false config/release/ios-asc-cli.env
assert_scope ios_asc_test false true false false false scripts/test-ios-asc-cli.sh
assert_scope mimi_contract true true false false false contracts/mimi-protocol/contract.json
assert_scope mimi_contract_generator true true false false false internal/protocolcontract/cmd/generate/main.go
assert_scope mimi_contract_checker true false false false false scripts/check-mimi-protocol-contract.sh
assert_scope critical_runner true true false false false scripts/test-conversation-regressions.sh
assert_scope critical_checker true true false false false scripts/check-critical-regressions.sh
assert_scope nightly_checker true true false false true scripts/check-nightly-release.sh
assert_scope packaging_checker true false false false true scripts/check-packaging.sh
assert_scope app_store_checker false true false false true scripts/check-app-store-metadata.sh
assert_scope nightly_docs false false false false true docs/nightly-release.md
assert_scope app_store_docs false false false false true docs/app-store/en-US/description.txt
assert_scope docs_runner false false false false true scripts/check-docs-static.sh
assert_scope ios_device_lease false true false false false scripts/ios-device-lease.sh
assert_scope ios_device_gui_handoff false true false false false scripts/ios-device-gui-handoff-macos.sh
assert_scope ios_device_management false true false false false scripts/test-ios-device-management.sh
assert_scope ios_device_fixture false true false false false scripts/testdata/ios-device-management/simulators.json
assert_scope tailcat_source false true false false false experiments/tailcat/mobile/tailcatmobile/tailcatmobile.go
assert_scope tailcat_builder false true false false false scripts/build-tailcat-mobile.sh
assert_scope tailcat_fixture false true false false false scripts/testdata/tailcat-mobile/fake-go.sh
assert_scope docs_only false false false false true CONTRIBUTING.md
assert_scope workflow true true true true true .github/workflows/pr-gate.yml
assert_scope mixed true true true false true \
  cmd/agentd/main.go \
  ios/MimiRemote/project.yml \
  Cargo.lock \
  docs/support.md

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
  "docs" => "./.github/workflows/docs-ci.yml",
}
jobs = gate.fetch("jobs")
scope_job = jobs.fetch("scope")
expected_scope_outputs = %w[go ios rust macos docs]
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
repository_safety_call = jobs.fetch("repository-safety")
unless repository_safety_call.dig("with", "mode") == "pull-request" &&
       repository_safety_call.dig("with", "base_sha").to_s.include?("github.event.pull_request.base.sha") &&
       repository_safety_call.dig("with", "head_sha").to_s.include?("github.event.pull_request.head.sha")
  abort("PR Gate 自检失败：Repository safety 必须显式传入 PR mode/base/head。")
end
unless jobs.dig("macos", "if").to_s.include?("needs.scope.outputs.macos")
  abort("PR Gate 自检失败：Mac App job 没有按 macos scope 执行。")
end
unless jobs.dig("docs", "if").to_s.include?("needs.scope.outputs.docs")
  abort("PR Gate 自检失败：Docs/static job 没有按 docs scope 执行。")
end

final_gate = jobs.fetch("gate")
abort("PR Gate 自检失败：最终 check 名称必须为 PR Gate。") unless final_gate["name"] == "PR Gate"
unless final_gate["if"].to_s.include?("always()")
  abort("PR Gate 自检失败：最终聚合 job 必须在上游失败或跳过时仍执行。")
end
expected_needs = %w[scope codex-protocol repository-safety go ios rust macos docs]
unless Array(final_gate["needs"]).sort == expected_needs.sort
  abort("PR Gate 自检失败：最终聚合 job 的 needs 不完整。")
end
%w[MACOS_REQUIRED MACOS_RESULT DOCS_REQUIRED DOCS_RESULT].each do |name|
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
unless macos_job["runs-on"] == "macos-26" && macos_job["timeout-minutes"] == 15
  abort("PR Gate 自检失败：Mac App CI 必须使用 macOS 26 runner 和 15 分钟超时。")
end
unless macos_job.to_s.include?("bash ./scripts/test-macos-app.sh")
  abort("PR Gate 自检失败：Mac App CI 没有运行统一编译测试入口。")
end
macos_test_script = File.read("scripts/test-macos-app.sh")
%w[xcodebuild -showBuildTimingSummary MACOS_EMBED_CACHE_DIR CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test].each do |fragment|
  unless macos_test_script.include?(fragment)
    abort("PR Gate 自检失败：Mac App 编译测试入口缺少 #{fragment}。")
  end
end
if macos_test_script.match?(/^\s*-quiet\s*$/)
  abort("PR Gate 自检失败：Mac App 编译测试入口不得隐藏 Xcode 阶段日志。")
end
embed_script = File.read("macos/MimiRemoteMac/Scripts/embed-agentd.sh")
%w[MACOS_EMBED_CACHE_DIR --target-dir --locked --release].each do |fragment|
  unless embed_script.include?(fragment)
    abort("PR Gate 自检失败：Mac App 内嵌构建脚本缺少 #{fragment}。")
  end
end
unless macos_workflow.to_s.include?("MACOS_EMBED_CACHE_DIR")
  abort("PR Gate 自检失败：Mac App CI 没有显式配置内嵌构建缓存目录。")
end

docs_path = ".github/workflows/docs-ci.yml"
docs_workflow = load_workflow(docs_path)
docs_triggers = triggers(docs_workflow, docs_path)
docs_push_paths = Array(docs_triggers.dig("push", "paths"))
%w[README.md README.zh-CN.md CONTRIBUTING.md docs/** scripts/check-docs-static.sh].each do |required_path|
  unless docs_push_paths.include?(required_path)
    abort("PR Gate 自检失败：Docs CI main push paths 缺少 #{required_path}。")
  end
end
docs_job = docs_workflow.fetch("jobs").fetch("verify")
unless docs_job["runs-on"] == "ubuntu-latest" && docs_job["timeout-minutes"] == 5 &&
       docs_job.to_s.include?("bash ./scripts/check-docs-static.sh")
  abort("PR Gate 自检失败：Docs CI 必须使用轻量 Ubuntu 静态入口。")
end
docs_script = File.read("scripts/check-docs-static.sh")
%w[check-packaging.sh check-app-store-metadata.sh check-nightly-release.sh].each do |required_check|
  unless docs_script.include?(required_check)
    abort("PR Gate 自检失败：文档静态入口缺少 #{required_check}。")
  end
end
if docs_script.match?(/\b(?:go test|cargo test|xcodebuild|ios-dev\.sh)\b/)
  abort("PR Gate 自检失败：文档静态入口不得启动语言构建或 Simulator。")
end

go_workflow = load_workflow(".github/workflows/go-ci.yml")
ios_workflow = load_workflow(".github/workflows/ios-ci.yml")
[go_workflow, ios_workflow].each do |workflow|
  push_paths = Array(triggers(workflow, "language workflow").dig("push", "paths"))
  if push_paths.any? { |path| path == "README.md" || path == "README.zh-CN.md" || path.start_with?("docs/") }
    abort("PR Gate 自检失败：Go/iOS main push 不得再由纯文档路径触发。")
  end
end

safety_path = ".github/workflows/public-repo-safety.yml"
safety_workflow = load_workflow(safety_path)
safety_triggers = triggers(safety_workflow, safety_path)
safety_inputs = safety_triggers.dig("workflow_call", "inputs")
unless safety_inputs.is_a?(Hash) &&
       safety_inputs.dig("mode", "default") == "full-history" &&
       safety_inputs.dig("base_sha", "default") == "" &&
       safety_inputs.dig("head_sha", "default") == ""
  abort("PR Gate 自检失败：公开仓库安全门的 reusable inputs 必须默认 fail closed 到完整历史。")
end
safety_job = safety_workflow.fetch("jobs").fetch("verify")
unless safety_job["runs-on"] == "ubuntu-latest" && safety_job["timeout-minutes"] == 5
  abort("PR Gate 自检失败：公开仓库安全门必须使用 Ubuntu runner 和 5 分钟超时。")
end
safety_steps = safety_job.fetch("steps")
safety_checkout = safety_steps.find { |step| step["name"] == "Checkout" }
unless safety_checkout&.dig("with", "fetch-depth") == 0
  abort("PR Gate 自检失败：公开仓库安全门必须保留完整 checkout，才能扫描 PR 中间提交。")
end
safety_plan = safety_steps.find { |step| step["name"] == "Plan repository safety checks" }
unless safety_plan && safety_plan["id"] == "safety" &&
       safety_plan.to_s.include?("--pull-request") &&
       safety_plan.to_s.include?("--base") &&
       safety_plan.to_s.include?("--head") &&
       safety_plan.to_s.include?("--github-output")
  abort("PR Gate 自检失败：公开仓库安全门缺少 fail-closed 的 PR 范围规划。")
end
safety_go = safety_steps.find { |step| step["name"] == "Setup Go" }
unless safety_go && safety_go["if"] == "steps.safety.outputs.third_party == 'true'"
  abort("PR Gate 自检失败：Setup Go 必须只在第三方许可检查需要时运行。")
end
safety_install = safety_steps.find { |step| step["name"] == "Install repository safety tools" }
unless safety_install && safety_install["run"].is_a?(String) && safety_install["run"].include?("command -v rg")
  abort("PR Gate 自检失败：公开仓库安全工具安装必须优先复用 runner 已有 ripgrep。")
end
safety_install_run = safety_install.fetch("run")
safety_install_lines = safety_install_run.lines.map do |line|
  line.strip.sub(/ \\\z/, "")
end
required_install_lines = [
  'if command -v rg >/dev/null 2>&1; then',
  'rg --version',
  'if [[ "${RUNNER_ARCH:-}" != "X64" ]]; then',
  'ripgrep_asset="ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz"',
  'ripgrep_url="https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz"',
  'ripgrep_sha256="33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c"',
  'ripgrep_root="ripgrep-15.2.0-x86_64-unknown-linux-musl"',
  'tar --extract --gzip --file "$archive_path" --directory "$extract_dir"',
  %q{printf '%s\n' "$(dirname "$rg_path")" >> "$GITHUB_PATH"},
  '"$rg_path" --version',
]
required_install_lines.each do |required_line|
  unless safety_install_lines.include?(required_line)
    abort("PR Gate 自检失败：公开仓库安全工具安装缺少有效命令 #{required_line}。")
  end
end

curl_index = safety_install_lines.index("curl")
curl_url_index = safety_install_lines.index('"$ripgrep_url"')
checksum_line = %q{if ! printf '%s  %s\n' "$ripgrep_sha256" "$archive_path" | sha256sum --check --status -; then}
checksum_index = safety_install_lines.index(checksum_line)
tar_index = safety_install_lines.index('tar --extract --gzip --file "$archive_path" --directory "$extract_dir"')
github_path_index = safety_install_lines.index(%q{printf '%s\n' "$(dirname "$rg_path")" >> "$GITHUB_PATH"})
rg_version_index = safety_install_lines.rindex('"$rg_path" --version')
ordered_indexes = [curl_index, curl_url_index, checksum_index, tar_index, github_path_index, rg_version_index]
unless ordered_indexes.none?(&:nil?) && ordered_indexes.each_cons(2).all? { |left, right| left < right }
  abort("PR Gate 自检失败：公开仓库安全工具必须依次下载、校验、解压、导出 PATH 并执行已校验的 rg。")
end

required_curl_lines = [
  "--proto '=https'",
  "--tlsv1.2",
  "--fail",
  "--silent",
  "--show-error",
  "--location",
  "--retry 3",
  "--retry-delay 2",
  "--retry-max-time 60",
  "--connect-timeout 10",
  "--max-time 120",
  '--output "$archive_path"',
]
curl_lines = safety_install_lines[(curl_index + 1)...curl_url_index]
required_curl_lines.each do |required_line|
  unless curl_lines.include?(required_line)
    abort("PR Gate 自检失败：ripgrep 下载命令缺少 #{required_line}。")
  end
end

safety_run_scripts = safety_steps.each_with_object([]) do |step, scripts|
  scripts << step["run"] if step["run"].is_a?(String)
end.join("\n")
if safety_run_scripts.match?(/\bapt(?:-get)?\b/)
  abort("PR Gate 自检失败：公开仓库安全门不得依赖 apt/apt-get。")
end
step_actions = safety_steps.each_with_object([]) do |step, actions|
  actions << step["uses"] if step["uses"].is_a?(String)
end
third_party_actions = step_actions.reject do |action|
  action.start_with?("actions/", "./")
end
unless third_party_actions.empty?
  abort("PR Gate 自检失败：公开仓库安全门不得新增第三方 Action：#{third_party_actions.join(', ')}。")
end
safety_check = safety_steps.find { |step| step["name"] == "Check public repository safety" }
unless safety_check && safety_check.to_s.include?("--pull-request") &&
       safety_check.to_s.include?("--full-history")
  abort("PR Gate 自检失败：公开仓库安全门没有按 PR/main 事件选择历史范围。")
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
