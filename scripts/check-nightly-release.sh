#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ROOT="${MIMI_NIGHTLY_RELEASE_ROOT:-$ROOT_DIR}"

fail() {
  echo "Nightly/Release 自检失败：$1" >&2
  exit 1
}

run_check() {
  ruby - "$CHECK_ROOT/.github/workflows" \
    "$CHECK_ROOT/scripts/distribute_internal_build.rb" \
    "$CHECK_ROOT/scripts/generate-nightly-what-to-test.rb" <<'RUBY'
require "pathname"
require "yaml"

IOS_TESTFLIGHT_ENV_NAME = "ios-testflight-release"
ALLOWED_IOS_TESTFLIGHT_ENV_BINDINGS = [
  ["nightly.yml", "release-secrets-preflight"],
  ["ios-ci.yml", "app-store-release"]
].freeze

def fail_check(message)
  abort("Nightly/Release 自检失败：#{message}")
end

def load_yaml(path)
  parsed = YAML.safe_load(File.read(path), aliases: true)
  fail_check("#{path} YAML 顶层必须是映射") unless parsed.is_a?(Hash)
  parsed
rescue Psych::SyntaxError => error
  fail_check("#{path} YAML 无法解析：#{error.message}")
end

def raw_triggers(workflow, path)
  has_str_on = workflow.key?("on")
  has_bool_on = workflow.key?(true)
  fail_check("#{path} 同时存在多个 on 声明") if has_str_on && has_bool_on
  fail_check("#{path} 缺少 on") unless has_str_on || has_bool_on
  has_str_on ? workflow["on"] : workflow[true]
end

def triggers(workflow, path)
  value = raw_triggers(workflow, path)
  fail_check("#{path} 缺少 on") unless value.is_a?(Hash)
  value
end

def trigger_names(workflow, path)
  value = raw_triggers(workflow, path)
  case value
  when String
    name = value.strip.downcase
    fail_check("#{path} 的 on 不能为空") if name.empty?
    [name]
  when Array
    fail_check("#{path} 的 on 不能为空数组") if value.empty?
    value.map do |entry|
      fail_check("#{path} 的 on 数组元素必须是非空字符串") unless entry.is_a?(String) && !entry.strip.empty?
      entry.strip.downcase
    end
  when Hash
    fail_check("#{path} 的 on 不能为空映射") if value.empty?
    value.keys.map do |key|
      name = key.to_s.strip.downcase
      fail_check("#{path} 的 on 键不能为空") if name.empty?
      name
    end
  else
    fail_check("#{path} 的 on 格式无效")
  end
end

def pr_triggered_workflow?(workflow, path)
  trigger_names(workflow, path).any? do |name|
    name == "pull_request" || name == "pull_request_target" || name.start_with?("pull_request_")
  end
end

def workflow_jobs(workflow, path)
  jobs = workflow["jobs"]
  fail_check("#{path} 缺少 jobs 映射") unless jobs.is_a?(Hash)
  jobs
end

def fetch_case_insensitive_key(hash, target_key, context_label)
  matches = hash.keys.select { |key| key.to_s.downcase == target_key }
  fail_check("#{context_label} 包含重复的 #{target_key} 字段") if matches.length > 1
  return [false, nil] if matches.empty?
  [true, hash[matches.first]]
end

def steps(job)
  Array(job.fetch("steps", []))
end

def step_index(job, name)
  index = steps(job).index { |step| step["name"] == name }
  fail_check("#{job.fetch("name", "job")} 缺少 step #{name}") unless index
  index
end

def step(job, name)
  steps(job).fetch(step_index(job, name))
end

def parse_constant_environment_name(environment, error_message)
  raw_name =
    case environment
    when String
      environment
    when Hash
      fail_check("#{error_message}（environment 映射必须包含 name 且仅允许 name/url）") unless
        environment.key?("name") && (environment.keys - %w[name url]).empty?
      environment["name"]
    else
      fail_check("#{error_message}（environment 必须是常量字符串或含 name 的映射）")
    end
  fail_check("#{error_message}（environment 名称必须是字符串）") unless raw_name.is_a?(String)
  normalized = raw_name.strip
  fail_check("#{error_message}（environment 名称必须是非空常量，禁止表达式）") if
    normalized.empty? || normalized.include?("${{")
  normalized
end

def assert_constant_environment(job, expected_name, error_message)
  fail_check("#{error_message}（缺少 environment 声明）") unless
    job.is_a?(Hash) &&
    job.key?("environment") &&
    job.keys.count { |key| key.to_s.downcase == "environment" } == 1
  normalized = parse_constant_environment_name(job["environment"], error_message)
  fail_check("#{error_message}（实际为 #{normalized.inspect}）") unless
    normalized.downcase == expected_name.downcase
end

def assert_only_allowed_environment_jobs(workflow_label, jobs, allowed_job_ids)
  jobs.each do |job_id, job|
    next if allowed_job_ids.include?(job_id)
    fail_check("#{workflow_label} #{job_id} 配置必须是映射") unless job.is_a?(Hash)
    has_environment = job.keys.any? { |key| key.to_s.downcase == "environment" }
    fail_check("#{workflow_label} #{job_id} 不得绑定 ios-testflight-release 或其他 Environment") if has_environment
  end
end

def local_workflow_target(uses_value)
  return nil unless uses_value.is_a?(String)
  raw = uses_value.strip
  return nil unless raw.start_with?("./")
  clean = Pathname.new(raw).cleanpath.to_s
  return nil unless clean.downcase.start_with?(".github/workflows/")
  File.basename(clean)
end

def calls_ios_ci?(uses_value)
  return false unless uses_value.is_a?(String)
  path_part = uses_value.strip.split("@", 2).first.to_s
  return false if path_part.empty?
  clean = Pathname.new(path_part).cleanpath.to_s.downcase
  clean == ".github/workflows/ios-ci.yml" ||
    clean.end_with?("/.github/workflows/ios-ci.yml") ||
    File.basename(clean) == "ios-ci.yml"
end

def assert_no_ios_publish_inputs(context_label, job)
  has_with, with_inputs = fetch_case_insensitive_key(job, "with", context_label)
  return if !has_with || with_inputs.nil?
  fail_check("#{context_label} 的 with 必须是映射") unless with_inputs.is_a?(Hash)
  with_inputs.each do |raw_key, value|
    key = raw_key.to_s.strip.downcase
    next unless %w[publish_internal_testflight publish_app_store].include?(key)
    fail_check("#{context_label} 调用 ios-ci 不得启用 #{raw_key}") unless value == false
  end
end

def assert_pinned_actions(path, workflow)
  workflow_jobs(workflow, path).each do |job_id, job|
    fail_check("#{path} #{job_id} 配置必须是映射") unless job.is_a?(Hash)
    candidates = []
    has_uses, job_uses = fetch_case_insensitive_key(job, "uses", "#{path} #{job_id}")
    candidates << job_uses if has_uses
    steps(job).each_with_index do |step_item, idx|
      fail_check("#{path} #{job_id} step ##{idx + 1} 配置必须是映射") unless step_item.is_a?(Hash)
      has_step_uses, step_uses = fetch_case_insensitive_key(step_item, "uses", "#{path} #{job_id} step ##{idx + 1}")
      candidates << step_uses if has_step_uses
    end
    candidates.each do |action|
      next if action.nil?
      fail_check("#{path} #{job_id} uses 必须是字符串") unless action.is_a?(String)
      next if action.start_with?("./")
      fail_check("#{path} #{job_id} action 未固定完整 commit SHA：#{action}") unless
        action.match?(/@[0-9a-f]{40}\z/)
    end
  end
end

workflows_dir, distributor_path, generator_path = ARGV
fail_check("workflows 目录不存在：#{workflows_dir}") unless File.directory?(workflows_dir)
workflow_entries = Dir.children(workflows_dir)
  .select { |entry| entry.match?(/\.ya?ml\z/i) }
  .sort
  .map { |entry| [entry, File.join(workflows_dir, entry)] }
  .select { |_entry, path| File.file?(path) }
fail_check("workflows 目录为空：#{workflows_dir}") if workflow_entries.empty?

workflows = {}
workflow_entries.each do |filename, path|
  workflow = load_yaml(path)
  assert_pinned_actions(path, workflow)
  workflows[filename] = { path: path, workflow: workflow }
end

%w[nightly.yml ios-ci.yml release.yml pr-gate.yml].each do |required_name|
  fail_check("缺少核心 workflow：#{required_name}") unless workflows.key?(required_name)
end

nightly_path = workflows.fetch("nightly.yml").fetch(:path)
ios_path = workflows.fetch("ios-ci.yml").fetch(:path)
release_path = workflows.fetch("release.yml").fetch(:path)
pr_gate_path = workflows.fetch("pr-gate.yml").fetch(:path)
nightly = workflows.fetch("nightly.yml").fetch(:workflow)
ios = workflows.fetch("ios-ci.yml").fetch(:workflow)
release = workflows.fetch("release.yml").fetch(:workflow)
pr_gate = workflows.fetch("pr-gate.yml").fetch(:workflow)
fail_check("Nightly What to Test 生成器不存在") unless File.file?(generator_path)
generator = File.read(generator_path)

nightly_triggers = triggers(nightly, nightly_path)
fail_check("Nightly 只能由 schedule 和 workflow_dispatch 触发") unless
  nightly_triggers.keys.sort == %w[schedule workflow_dispatch]
fail_check("Nightly 必须有 UTC 18:30 schedule") unless
  Array(nightly_triggers["schedule"]).any? { |entry| entry["cron"] == "30 18 * * *" }
dispatch = nightly_triggers["workflow_dispatch"]
fail_check("Nightly 必须支持 force_publish bool dispatch") unless
  dispatch.is_a?(Hash) && dispatch.dig("inputs", "force_publish", "type") == "boolean" &&
  dispatch.dig("inputs", "force_publish", "default") == false
fail_check("Nightly 权限必须只有 contents:read 和 actions:read") unless
  nightly["permissions"] == { "contents" => "read", "actions" => "read" }
concurrency = nightly.fetch("concurrency")
fail_check("Nightly concurrency group 必须是固定值") unless
  concurrency["group"].is_a?(String) && !concurrency["group"].include?("${{")
fail_check("Nightly 必须保留 cancel-in-progress:false") unless concurrency["cancel-in-progress"] == false

nightly_jobs = nightly.fetch("jobs")
plan = nightly_jobs.fetch("plan")
release_secrets = nightly_jobs.fetch("release-secrets-preflight")
publish = nightly_jobs.fetch("publish")
final = nightly_jobs.fetch("final")
trust_index = step_index(plan, "Trust gate before deduplication API")
dedup_index = step_index(plan, "Check previous successful Nightly runs")
fail_check("Nightly trust gate 必须先于去重 API") unless trust_index < dedup_index
pretrust = steps(plan).take(trust_index)
fail_check("Nightly trust gate 前不得读取 Secrets") if pretrust.any? { |item| item.to_s.include?("secrets.") }
trust_run = steps(plan).fetch(trust_index).fetch("run")
[
  'gaixianggeng/mimi-remote', 'refs/heads/main', 'GITHUB_SHA',
  'git rev-parse HEAD', '+refs/heads/main:refs/remotes/origin/main',
  'git rev-parse refs/remotes/origin/main', 'head_sha', 'main_sha'
].each { |needle| fail_check("Nightly trust gate 缺少 #{needle}") unless trust_run.include?(needle) }
dedup_run = steps(plan).fetch(dedup_index).fetch("run")
[
  'actions/workflows/nightly.yml/runs', 'head_sha', 'GITHUB_RUN_ID',
  'actions/runs/${run_id}/artifacts', 'actions/artifacts/${artifact_id}/zip',
  'workflow_run', 'EXPECTED_RUN_ID', 'Nightly Internal TestFlight',
  'should_publish', 'force_publish'
].each { |needle| fail_check("Nightly 去重逻辑缺少 #{needle}") unless dedup_run.include?(needle) }
[
  'artifact["name"] == "nightly-testflight-#{sha}"',
  'artifact["expired"] == false',
  'workflow_run["id"].to_s == run_id',
  'workflow_run["head_sha"] == sha',
  '[[ "$(unzip -Z1 "$artifact_zip")" == "evidence.json" ]]',
  'value["source_sha"] == ENV.fetch("SOURCE_SHA")',
  'value["run_id"].to_s == ENV.fetch("EXPECTED_RUN_ID")',
  'value["repository"] == ENV.fetch("GITHUB_REPOSITORY")',
  'value["workflow"] == "Nightly Internal TestFlight"',
  '%w[schedule workflow_dispatch].include?(value["event"])',
  'value["uploaded"] == true'
].each { |needle| fail_check("Nightly evidence 绑定缺少 #{needle}") unless dedup_run.include?(needle) }
[
  'actions/workflows/ios-ci.yml/runs?head_sha=${source_sha}&event=workflow_dispatch&branch=main&per_page=100&page=${manual_page}',
  'actions/runs/${run_id}/jobs?filter=all&per_page=100&page=${jobs_page}',
  'run["head_sha"] == ENV.fetch("SOURCE_SHA")',
  'run.dig("head_repository", "full_name") == ENV.fetch("GITHUB_REPOSITORY")',
  'run["path"] == ".github/workflows/ios-ci.yml"',
  'run["event"] == "workflow_dispatch" && run["status"] == "completed"',
  'job["run_id"].to_s == ENV.fetch("EXPECTED_RUN_ID")',
  'job["head_sha"] == ENV.fetch("SOURCE_SHA")',
  'job["name"] == "app-store-release"',
  'step["name"] == "Archive, audit, upload, and distribute build"',
  'step["conclusion"] == "success"'
].each { |needle| fail_check("Nightly 手动内部上传去重缺少 #{needle}") unless dedup_run.include?(needle) }
[
  'run["conclusion"] == "success"', 'run["head_branch"] == "main"',
  'run["head_sha"] != source_sha', 'per_page=100&page=${baseline_page}',
  'if [[ "$should_publish" == "true" ]]; then',
  'git cat-file -e "${candidate_sha}^{commit}"',
  'git merge-base --is-ancestor "$candidate_sha" "$source_sha"',
  'scripts/generate-nightly-what-to-test.rb', 'GITHUB_OUTPUT',
  'what_to_test<<$delimiter', 'od -An -N16 -tx1 /dev/urandom',
  'grep -Fqx -- "$delimiter"'
].each { |needle| fail_check("Nightly What to Test 安全边界缺少 #{needle}") unless dedup_run.include?(needle) }
[
  'MAX_LENGTH = 4000', '--no-merges', 'diff-tree', 'changed_paths', 'base_sha != head_sha',
  'noise_path?', 'testflight_payload_path?', 'ios/MimiRemote/WidgetExtension/',
  'Info-Catalyst.plist', 'MimiRemotePhysicalUITests.xcscheme',
  'FALLBACK_NO_BASELINE', 'FALLBACK_NO_USER_CHANGES',
  'normalized_title', '其余 #{remaining} 项更新未展开'
].each { |needle| fail_check("Nightly What to Test 生成器缺少 #{needle}") unless generator.include?(needle) }
fail_check("Nightly plan 必须输出 source_sha/what_to_test/should_publish") unless
  %w[source_sha what_to_test should_publish].all? { |key| plan.dig("outputs", key).to_s.include?("steps.plan.outputs") }

fail_check("Nightly 发布凭据预检必须在 plan 成功且确定需要发布后运行") unless
  Array(release_secrets["needs"]) == ["plan"] &&
  release_secrets["if"].to_s.include?("needs.plan.outputs.should_publish")
fail_check("Nightly 发布凭据预检必须使用轻量 Ubuntu runner 和短超时") unless
  release_secrets["runs-on"] == "ubuntu-latest" && release_secrets["timeout-minutes"] == 2
assert_constant_environment(
  release_secrets,
  "ios-testflight-release",
  "Nightly 发布凭据预检必须精确绑定 ios-testflight-release Environment"
)
assert_only_allowed_environment_jobs("Nightly", nightly_jobs, ["release-secrets-preflight"])
secrets_step = step(release_secrets, "Require App Store signing secrets")
required_release_secrets = %w[
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_PRIVATE_KEY
  IOS_APPSTORE_PROVISIONING_PROFILE_BASE64
  IOS_WIDGET_APPSTORE_PROVISIONING_PROFILE_BASE64
  IOS_NOTIFICATION_APPSTORE_PROVISIONING_PROFILE_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_BASE64
  IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
  IOS_KEYCHAIN_PASSWORD
]
fail_check("Nightly 发布凭据预检的 Secret 集合不完整") unless
  secrets_step.fetch("env").keys.sort == required_release_secrets.sort
required_release_secrets.each do |name|
  fail_check("Nightly 发布凭据预检没有读取 #{name}") unless
    secrets_step.dig("env", name).to_s.include?("secrets.#{name}") &&
    secrets_step.fetch("run").include?(name)
end
fail_check("Nightly 轻量预检不得解码或写出签名材料") if
  secrets_step.fetch("run").match?(/\bsecurity\b|profileContent|\.p12|\.mobileprovision|\bbase64\s+(?:--decode|-d|-D|<)/i)
fail_check("Nightly 发布凭据预检必须 fail-closed") unless
  secrets_step.fetch("run").include?('[[ -n "${!secret_name}" ]]') &&
  secrets_step.fetch("run").include?("exit 1")

fail_check("Nightly publish 必须复用 ios-ci reusable workflow") unless
  publish["uses"] == "./.github/workflows/ios-ci.yml"
fail_check("Nightly publish 必须等待 plan 与发布凭据预检") unless
  Array(publish["needs"]).sort == %w[plan release-secrets-preflight].sort
fail_check("Nightly publish 必须只在需要发布且凭据预检成功时执行") unless
  publish["if"].to_s.include?("needs.plan.outputs.should_publish") &&
  publish["if"].to_s.include?("needs.release-secrets-preflight.result") &&
  publish["if"].to_s.include?("success")
publish_with = publish.fetch("with")
fail_check("Nightly publish source_ref 必须来自 plan SHA") unless publish_with["source_ref"].to_s.include?("needs.plan.outputs.source_sha")
fail_check("Nightly publish 必须显式启用 reusable TestFlight") unless publish_with["publish_internal_testflight"] == true
fail_check("Mimi 中转入口已常显，Nightly 不能再传入旧开关") if publish_with.key?("enable_managed_connection")
%w[workflow_call workflow_dispatch].each do |trigger|
  fail_check("Mimi 中转入口已常显，ios-ci 不应再声明旧入口开关") if
    triggers(ios, ios_path).dig(trigger, "inputs").to_h.key?("enable_managed_connection")
end
fail_check("Nightly publish What to Test 必须来自 plan") unless publish_with["what_to_test"].to_s.include?("needs.plan.outputs.what_to_test")
fail_check("Nightly publish 必须使用 secrets: inherit") unless publish["secrets"] == "inherit"
fail_check("Nightly final 必须 always 聚合 plan、发布凭据预检和 publish") unless
  final["if"].to_s.include?("always()") &&
  Array(final["needs"]).sort == %w[plan publish release-secrets-preflight].sort
%w[PLAN_RESULT RELEASE_SECRETS_RESULT PUBLISH_RESULT SHOULD_PUBLISH].each do |name|
  fail_check("Nightly final 缺少 #{name} 结果判断") unless final.to_s.include?(name)
end
fail_check("Nightly skip 必须按成功结果收敛") unless final.to_s.include?("PUBLISH_RESULT" ) && final.to_s.include?("skipped")

ios_triggers = triggers(ios, ios_path)
fail_check("ios-ci 不得直接由 pull_request 触发") if
  ios_triggers.keys.any? { |key| key.to_s.downcase.include?("pull_request") }
call = ios_triggers.fetch("workflow_call")
%w[source_ref publish_internal_testflight what_to_test].each do |name|
  fail_check("ios-ci workflow_call 缺少 #{name}") unless call.dig("inputs", name)
end
fail_check("ios-ci source_ref 类型错误") unless call.dig("inputs", "source_ref", "type") == "string"
fail_check("ios-ci publish_internal_testflight 必须是 bool") unless call.dig("inputs", "publish_internal_testflight", "type") == "boolean"
fail_check("ios-ci publish_internal_testflight 默认值必须显式为 false") unless call.dig("inputs", "publish_internal_testflight", "default") == false
fail_check("ios-ci what_to_test 类型错误") unless call.dig("inputs", "what_to_test", "type") == "string"
ios_dispatch = ios_triggers["workflow_dispatch"]
fail_check("ios-ci workflow_dispatch.inputs.publish_app_store 必须是 bool") unless
  ios_dispatch.is_a?(Hash) && ios_dispatch.dig("inputs", "publish_app_store", "type") == "boolean"
fail_check("ios-ci workflow_dispatch.inputs.publish_app_store 默认值必须显式为 false") unless
  ios_dispatch.dig("inputs", "publish_app_store", "default") == false
fail_check("ios-ci workflow_call 不得声明必填发布 secrets") if
  call["secrets"].is_a?(Hash) && call["secrets"].values.any? { |cfg| cfg.is_a?(Hash) && cfg["required"] == true }
ios_jobs = ios.fetch("jobs")
%w[conversation-regressions image-recovery-ui-regressions].each do |regression_job_id|
  regression_job = ios_jobs.fetch(regression_job_id)
  checkout = steps(regression_job).find { |item| item["uses"].to_s.start_with?("actions/checkout@") }
  fail_check("#{regression_job_id} 必须 checkout immutable source_ref") unless checkout && checkout.dig("with", "ref").to_s.include?("inputs.source_ref")
end
%w[conversation-regressions image-recovery-ui-regressions tailcat-integration].each do |regression_job_id|
  ios_jobs.fetch(regression_job_id)
end
assert_only_allowed_environment_jobs("iOS CI", ios_jobs, ["app-store-release"])
app = ios_jobs.fetch("app-store-release")
assert_constant_environment(
  app,
  "ios-testflight-release",
  "app-store-release 必须精确绑定 ios-testflight-release Environment"
)
fail_check("signed app-store-release 必须等待 conversation-regressions 与 image-recovery-ui-regressions") unless Array(app["needs"]).sort == %w[conversation-regressions image-recovery-ui-regressions]
raw_condition = app["if"]
fail_check("app-store-release 必须声明字符串形式发布条件 if") unless raw_condition.is_a?(String)
condition = raw_condition.gsub(/\s+/, " ").strip
fail_check("reusable workflow 会继承 caller event，禁止用 workflow_call 判断发布路径") if condition.downcase.include?("workflow_call")
fail_check("app-store-release 发布条件禁止包含 pull_request") if condition.downcase.include?("pull_request")
expected_app_store_if = "(github.event_name == 'workflow_dispatch' && inputs.publish_app_store) || inputs.publish_internal_testflight"
fail_check("app-store-release 发布条件必须精确保持为 #{expected_app_store_if}") unless condition == expected_app_store_if
trust = step(app, "Trust gate before App Store signing")
prepare_index = step_index(app, "Prepare App Store signing")
fail_check("Prepare signing 前必须有 trust gate") unless step_index(app, "Trust gate before App Store signing") < prepare_index
fail_check("iOS trust gate 不得读取 Secrets") if trust.to_s.include?("secrets.")
trust_run = trust.fetch("run")
[
  'gaixianggeng/mimi-remote', 'refs/heads/main',
  'GITHUB_SHA', 'CANDIDATE_SOURCE_REF', '^[0-9a-f]{40}$',
  'git rev-parse HEAD', '+refs/heads/main:refs/remotes/origin/main',
  'head_sha', 'main_sha', '"$GITHUB_SHA" == "$CANDIDATE_SOURCE_REF"'
].each { |needle| fail_check("iOS trust gate 缺少 #{needle}") unless trust_run.include?(needle) }
upload = app.dig("env", "IOS_TESTFLIGHT_UPLOAD").to_s
fail_check("iOS upload 必须严格使用 1/0 二选一") unless upload.include?("'1'") && upload.include?("'0'") && app.dig("env", "IOS_TESTFLIGHT_VALIDATE").to_s == "0"
ios_concurrency = ios.fetch("concurrency")
concurrency_group = ios_concurrency.fetch("group").to_s.gsub(/\s+/, "")
cancel_expression = ios_concurrency.fetch("cancel-in-progress").to_s.gsub(/\s+/, "")
expected_release_predicate = "(inputs.publish_internal_testflight||(github.event_name=='workflow_dispatch'&&inputs.publish_app_store))"
expected_group = 'ios-ci-${{' + expected_release_predicate + "&&'release'||'regression'" + '}}-${{github.ref}}'
expected_cancel_expression = '${{!' + expected_release_predicate + '}}'
fail_check("iOS CI 必须把 TestFlight release 与普通 regression concurrency group 分开") unless
  concurrency_group == expected_group
fail_check("iOS CI 只能取消普通回归，不能取消 TestFlight 上传") unless
  cancel_expression == expected_cancel_expression
upload_step = step(app, "Archive, audit, upload, and distribute build")
fail_check("手动发布去重依赖内部上传步骤，不得改成空操作或可忽略失败") unless
  upload_step["run"] == "bash ./scripts/ios_testflight_ci.sh" &&
    !upload_step["if"] && !upload_step["continue-on-error"]
evidence = step(app, "Write Nightly TestFlight evidence")
artifact = step(app, "Upload Nightly TestFlight evidence")
fail_check("Nightly evidence 只能由显式 reusable publish input 生成") unless
  evidence["if"].to_s.include?("publish_internal_testflight") && !evidence["if"].to_s.include?("event_name")
fail_check("Nightly evidence JSON 字段不完整") unless %w[source_sha run_id run_attempt repository workflow event uploaded].all? { |key| evidence.to_s.include?(key) }
fail_check("Nightly evidence artifact 配置错误") unless artifact["uses"].to_s.match?(/@[0-9a-f]{40}\z/) && artifact.dig("with", "name").to_s.include?("nightly-testflight-") && artifact.dig("with", "retention-days") == 30

pr_gate_jobs = pr_gate.fetch("jobs")
assert_only_allowed_environment_jobs("PR Gate", pr_gate_jobs, [])
pr_gate_ios = pr_gate_jobs.fetch("ios")
fail_check("PR Gate ios job 必须调用 ./.github/workflows/ios-ci.yml") unless
  pr_gate_ios.is_a?(Hash) && pr_gate_ios["uses"] == "./.github/workflows/ios-ci.yml"
pr_gate_ios_jobs = pr_gate_jobs.select do |job_id, job|
  next false unless job.is_a?(Hash)
  has_uses, uses_value = fetch_case_insensitive_key(job, "uses", "PR Gate #{job_id}")
  has_uses && calls_ios_ci?(uses_value)
end
fail_check("PR Gate 缺少调用 ./.github/workflows/ios-ci.yml 的 job") if pr_gate_ios_jobs.empty?
pr_gate_ios_jobs.each do |job_id, job|
  assert_no_ios_publish_inputs("PR Gate #{job_id}", job)
end

release_triggers = triggers(release, release_path)
release_dispatch = release_triggers["repository_dispatch"]
fail_check("Release 只能由默认分支 repository_dispatch:release 触发") unless
  release_triggers.keys == ["repository_dispatch"] &&
  release_dispatch == { "types" => ["release"] }
fail_check("Release 顶层权限必须严格保持 contents:read") unless
  release["permissions"] == { "contents" => "read" }
fail_check("Release RELEASE_TAG 必须只来自 dispatch input") unless
  release.dig("env", "RELEASE_TAG").to_s.include?("github.event.client_payload.release_tag") &&
  release.fetch("env").keys == ["RELEASE_TAG"]
fail_check("release.yml 不得依赖 release-validation/readiness/attestation") if release.to_s.match?(/release-validation|readiness|attestation/i)
release_jobs = release.fetch("jobs")
expected_release_jobs = %w[source-trust verify-safety verify verify-windows prepare-release linux-smoke release publish-windows]
fail_check("Release jobs 集合存在未受 source-trust 约束的旁路") unless
  release_jobs.keys.sort == expected_release_jobs.sort
release_trust = release_jobs.fetch("source-trust")
expected_trust_keys = %w[name if runs-on timeout-minutes outputs steps]
fail_check("Release source-trust 含未允许的权限、Environment 或控制字段") unless
  release_trust.keys.sort == expected_trust_keys.sort
fail_check("Release source-trust 必须只输出 checker 验证的 tag_sha") unless
  release_trust.fetch("outputs").keys == ["tag_sha"] &&
  release_trust.dig("outputs", "tag_sha").to_s.include?("steps.source.outputs.tag_sha")
fail_check("Release source-trust 仓库条件不可放宽") unless
  release_trust["if"] == "github.repository == 'gaixianggeng/mimi-remote'"
fail_check("Release source-trust 必须使用轻量 Ubuntu runner 和短超时") unless
  release_trust["runs-on"] == "ubuntu-latest" && release_trust["timeout-minutes"] == 3
fail_check("Release source-trust 必须且只能包含 checkout 与 trust 两步") unless
  steps(release_trust).length == 2
release_trust_checkout = steps(release_trust).fetch(0)
fail_check("Release source-trust checkout 含可跳过或忽略失败的字段") unless
  release_trust_checkout.keys.sort == %w[name uses with]
fail_check("Release source-trust 必须完整 checkout tag 与 main 历史") unless
  release_trust_checkout["uses"].to_s.start_with?("actions/checkout@") &&
  release_trust_checkout.dig("with", "fetch-depth") == 0 &&
  release_trust_checkout.dig("with", "ref").to_s.include?("github.sha")
release_trust_step = step(release_trust, "Trust gate before release secrets")
fail_check("Release source-trust 不得读取 Secrets") if release_trust.to_s.include?("secrets.")
fail_check("Release trust step 含 continue-on-error、if 或其他旁路字段") unless
  release_trust_step.keys.sort == %w[id name run] && release_trust_step["id"] == "source"
fail_check("Release source-trust 没有调用统一来源校验入口") unless
  release_trust_step["run"] == "bash ./scripts/check-release-source.sh --check"

release_safety = release_jobs.fetch("verify-safety")
fail_check("Release 安全扫描 job 的来源、权限或 runner 不符合约束") unless
  release_safety.keys.sort == %w[if name needs runs-on steps timeout-minutes] &&
  release_safety["name"] == "Verify full-history repository safety" &&
  release_safety["needs"] == "source-trust" &&
  release_safety["if"] == "github.repository == 'gaixianggeng/mimi-remote'" &&
  release_safety["runs-on"] == "ubuntu-latest" &&
  release_safety["timeout-minutes"] == 10 &&
  !release_safety.to_s.include?("secrets.")
safety_steps = steps(release_safety)
fail_check("Release 安全扫描必须依次安装工具并执行原样全历史扫描") unless
  safety_steps.length == 4 &&
  safety_steps.map { |item| item["name"] } == [
    "Checkout verified release source", "Setup Go",
    "Install repository safety tools", "Check public repository safety"
  ]
safety_checkout, safety_go, safety_install, safety_scan = safety_steps
fail_check("Release 安全扫描必须 checkout 受信 tag SHA 的完整历史") unless
  safety_checkout.keys.sort == %w[name uses with] &&
  safety_checkout["uses"].to_s.start_with?("actions/checkout@") &&
  safety_checkout.dig("with", "ref") == "${{ needs.source-trust.outputs.tag_sha }}" &&
  safety_checkout.dig("with", "fetch-depth") == 0
fail_check("Release 安全扫描的 Go 与 ripgrep 准备步骤不可跳过") unless
  safety_go.keys.sort == %w[name uses with] &&
  safety_go["uses"].to_s.start_with?("actions/setup-go@") &&
  safety_go.dig("with", "go-version-file") == "go.mod" &&
  safety_install.keys.sort == %w[name run] &&
  safety_install["run"] == "command -v rg >/dev/null 2>&1 || sudo apt-get install -y ripgrep"
fail_check("Release 全历史安全扫描不得降级、跳过或忽略失败") unless
  safety_scan.keys.sort == %w[name run] &&
  safety_scan["run"] == "bash ./scripts/check-public-repo-safety.sh --full-history"

%w[verify verify-windows prepare-release release publish-windows].each do |job_name|
  job = release_jobs.fetch(job_name)
  fail_check("Release #{job_name} 仓库条件不可放宽") unless
    job["if"] == "github.repository == 'gaixianggeng/mimi-remote'"
  fail_check("Release #{job_name} 没有显式依赖 source-trust") unless
    Array(job["needs"]).include?("source-trust")
  fail_check("Release #{job_name} 没有绑定 production-release Environment") unless
    job["environment"] == "production-release"
end
%w[verify verify-windows].each do |job_name|
  fail_check("Release #{job_name} 必须等待受信来源与全历史安全扫描") unless
    Array(release_jobs.fetch(job_name)["needs"]).sort == %w[source-trust verify-safety].sort
end
prepare = release_jobs.fetch("prepare-release")
publish = release_jobs.fetch("release")
linux = release_jobs.fetch("linux-smoke")
fail_check("Release 正式构建必须等待全部来源、安全和构建门禁") unless
  Array(prepare["needs"]).sort ==
    %w[source-trust verify-safety verify verify-windows].sort
fail_check("Release 必须先生成正式归档再交给 Linux 门禁") unless
  step(prepare, "Prepare signed release artifacts").dig("with", "args") == "release --clean --skip=publish" &&
    !prepare.key?("permissions") &&
    prepare.dig("outputs", "linux_artifacts") == "${{ steps.linux-assets.outputs.artifact-id }}"
fail_check("Linux 配对检查必须用匹配的两个原生 runner 执行，且只读取受信构建产物") unless
  linux["if"] == "github.repository == 'gaixianggeng/mimi-remote'" &&
    !linux.key?("continue-on-error") && !linux.key?("permissions") && !linux.key?("environment") &&
    linux["runs-on"] == "${{ matrix.runner }}" && Array(linux["needs"]).sort == %w[prepare-release source-trust] &&
    linux.dig("strategy", "matrix", "include") == [
      { "arch" => "amd64", "runner" => "ubuntu-24.04" }, { "arch" => "arm64", "runner" => "ubuntu-24.04-arm" }
    ]
fail_check("正式发布必须等待两种架构的 Linux 实包配对检查") unless
  Array(publish["needs"]).sort == %w[linux-smoke prepare-release source-trust verify-safety] &&
    publish["permissions"] == { "contents" => "write" }
linux_artifact = "${{ needs.prepare-release.outputs.linux_artifacts }}"
fail_check("Linux 检查与发布必须下载同一个准备阶段归档 ID") unless
  [linux, publish].all? { |job| steps(job).any? { |item| item["uses"].to_s.start_with?("actions/download-artifact@") && item.dig("with", "artifact-ids") == linux_artifact } }
smoke_step = step(linux, "Pair with the released Linux executable")
fail_check("Linux 配对检查不得跳过、吞掉失败或只编译测试") unless
  smoke_step.keys.sort == %w[env name run shell] &&
    smoke_step["run"].include?('GOFLAGS=-json bash ./scripts/test-linux-tailcat-package.sh "$binary"') &&
    smoke_step["run"].include?('TestPackagedTailcatStartsAndPairs') &&
    smoke_step["run"].include?('length == 1')
fail_check("Release macOS 验证不得重复在低内存 runner 扫描完整历史") if
  steps(release_jobs.fetch("verify")).any? { |item| item["name"] == "Check public repository safety" }
windows_publish = release_jobs.fetch("publish-windows")
fail_check("Windows 发布 job 必须依赖已验证 artifact 和已创建的正式 Release") unless
  Array(windows_publish["needs"]).sort == %w[release source-trust verify-safety verify-windows].sort
fail_check("Windows 发布 job 必须使用 Windows runner 和最小 contents:write 权限") unless
  windows_publish["runs-on"] == "windows-latest" &&
  windows_publish["permissions"] == { "contents" => "write" }
%w[verify verify-windows prepare-release linux-smoke].each do |job_name|
  checkout = steps(release_jobs.fetch(job_name)).find { |item| item["uses"].to_s.start_with?("actions/checkout@") }
  fail_check("Release #{job_name} 没有 checkout source-trust 验证的 immutable SHA") unless
    checkout && checkout.dig("with", "ref").to_s.include?("needs.source-trust.outputs.tag_sha")
end
%w[verify prepare-release].each do |job_name|
  goreleaser_step_name = job_name == "verify" ? "Build release snapshot" : "Prepare signed release artifacts"
  goreleaser_step = step(release_jobs.fetch(job_name), goreleaser_step_name)
  fail_check("Release #{job_name} 的 GoReleaser 没有绑定 source-trust 校验的 RELEASE_TAG") unless
    goreleaser_step.dig("env", "GORELEASER_CURRENT_TAG") == "${{ env.RELEASE_TAG }}"
end
fail_check("Release workflow 不得从 dispatch 的 main ref 推导发布版本") if
  release.to_s.include?("GITHUB_REF_NAME")
distributor = File.read(distributor_path)
fail_check("Internal TestFlight 组校验必须 fail-closed") unless distributor.include?('unless group.dig("attributes", "isInternalGroup") == true')

# 全仓 workflow 扫描：
# 1. 计算所有带 pull_request / pull_request_target（及 pull_request_*）触发器的 workflow 及其经本地 reusable workflow 可达的调用链。
# 2. 任何 PR 触发（或 PR 可达）的 workflow 调用 ios-ci.yml 时，均不得启用 publish_internal_testflight 或 publish_app_store。
# 3. 全仓任意 workflow 的任意 job 声明 environment 时，必须为可静态确定的非空常量（禁止表达式）；
#    ios-testflight-release（大小写不敏感）全仓仅允许 nightly.yml/release-secrets-preflight 与 ios-ci.yml/app-store-release；
#    PR 触发或 PR 可达的 workflow 除 ios-ci.yml/app-store-release 外不得绑定任何 Environment；
#    release.yml 的 production-release 绑定保持合法。
workflows_by_downcase = Hash.new { |hash, key| hash[key] = [] }
direct_pr_workflows = []
workflows.each do |filename, entry|
  workflows_by_downcase[filename.downcase] << filename
  workflow = entry.fetch(:workflow)
  path = entry.fetch(:path)
  direct_pr_workflows << filename if pr_triggered_workflow?(workflow, path)
end

pr_reachable = {}
queue = direct_pr_workflows.dup
while (current = queue.shift)
  next if pr_reachable[current]
  pr_reachable[current] = true
  entry = workflows.fetch(current)
  jobs = workflow_jobs(entry.fetch(:workflow), entry.fetch(:path))
  jobs.each do |job_id, job|
    fail_check("#{current} #{job_id} 配置必须是映射") unless job.is_a?(Hash)
    has_uses, uses_value = fetch_case_insensitive_key(job, "uses", "#{current} #{job_id}")
    next unless has_uses && uses_value.is_a?(String)
    if calls_ios_ci?(uses_value)
      assert_no_ios_publish_inputs("PR workflow #{current} #{job_id}", job)
    end
    target_basename = local_workflow_target(uses_value)
    next unless target_basename
    workflows_by_downcase[target_basename.downcase].each do |resolved|
      queue << resolved unless pr_reachable[resolved]
    end
  end
end

workflows.each do |filename, entry|
  workflow = entry.fetch(:workflow)
  path = entry.fetch(:path)
  jobs = workflow_jobs(workflow, path)
  jobs.each do |job_id, job|
    fail_check("#{filename} #{job_id} 配置必须是映射") unless job.is_a?(Hash)
    has_env, env_value = fetch_case_insensitive_key(job, "environment", "#{filename} #{job_id}")
    next unless has_env

    env_name = parse_constant_environment_name(env_value, "#{filename} #{job_id}")
    if env_name.downcase == IOS_TESTFLIGHT_ENV_NAME
      unless ALLOWED_IOS_TESTFLIGHT_ENV_BINDINGS.include?([filename, job_id])
        fail_check("#{filename} #{job_id} 不得绑定 ios-testflight-release Environment（全仓仅允许 nightly.yml/release-secrets-preflight 与 ios-ci.yml/app-store-release）")
      end
    elsif pr_reachable[filename] && !ALLOWED_IOS_TESTFLIGHT_ENV_BINDINGS.include?([filename, job_id])
      fail_check("PR workflow #{filename} #{job_id} 不得绑定 Environment（实际为 #{env_name.inspect}）")
    end
  end
end

puts "Nightly/Release workflow 自检通过。"
RUBY
}

self_test() {
  local test_root
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-nightly-release-self-test.XXXXXX")"
  trap 'rm -rf "$test_root"' RETURN
  mkdir -p "$test_root/.github" "$test_root/scripts"
  cp -R "$ROOT_DIR/.github/workflows" "$test_root/.github/"
  [[ -f "$test_root/.github/workflows/pr-metadata.yml" ]] || fail "self-test 未完整拷贝 .github/workflows 目录"
  cp "$ROOT_DIR/scripts/distribute_internal_build.rb" "$test_root/scripts/"
  cp "$ROOT_DIR/scripts/generate-nightly-what-to-test.rb" "$test_root/scripts/"
  MIMI_NIGHTLY_RELEASE_ROOT="$test_root" "$0" --check >/dev/null
  ruby "$test_root/scripts/generate-nightly-what-to-test.rb" --self-test >/dev/null

  # 执行真实 plan shell 并替换 Actions API，验证去重结果而不触发签名或上传。
  ruby - "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root" <<'RUBY'
require "json"
require "yaml"
require "open3"
require "fileutils"
workflow_path, test_root = ARGV
plan_step = YAML.safe_load(File.read(workflow_path), aliases: true)
  .fetch("jobs").fetch("plan").fetch("steps").find { |item| item["id"] == "plan" }
plan_path = File.join(test_root, "plan.sh")
File.write(plan_path, plan_step.fetch("run"))
bin_dir = File.join(test_root, "bin")
FileUtils.mkdir_p(bin_dir)
curl_path = File.join(bin_dir, "curl")
File.write(curl_path, <<'MOCK')
#!/usr/bin/env ruby
require "json"
require "uri"
url = URI(ARGV.last)
query = URI.decode_www_form(url.query.to_s).to_h
fixture = JSON.parse(File.read(ENV.fetch("PLAN_FIXTURE")))
File.open(ENV.fetch("PLAN_API_LOG"), "a") { |file| file.puts(url.request_uri) }
page = query.fetch("page", "1").to_i - 1
response = case url.path
when %r{/workflows/nightly.yml/runs\z}
  { workflow_runs: query.key?("head_sha") ? fixture.fetch("nightly_runs", []) : [] }
when %r{/workflows/ios-ci.yml/runs\z}
  abort "fixture API failure" if fixture["api_failure"]
  { workflow_runs: fixture.fetch("manual_pages", [[]])[page] || [] }
when %r{/runs/42/jobs\z}
  { jobs: fixture.fetch("job_pages", [[]])[page] || [] }
else
  abort "Unexpected fixture API: #{url.request_uri}"
end
puts JSON.generate(response)
MOCK
FileUtils.chmod(0755, curl_path)
sha = `git rev-parse HEAD`.strip
run = {
  "id" => 42, "head_sha" => sha, "head_branch" => "main",
  "head_repository" => { "full_name" => "gaixianggeng/mimi-remote" },
  "path" => ".github/workflows/ios-ci.yml", "event" => "workflow_dispatch",
  "status" => "completed", "conclusion" => "success"
}
job = {
  "name" => "app-store-release", "run_id" => 42, "head_sha" => sha,
  "steps" => [{ "name" => "Archive, audit, upload, and distribute build", "conclusion" => "success" }]
}
check_plan = lambda do |name, expected, fixture, force = false|
  case_dir = File.join(test_root, name)
  FileUtils.mkdir_p(case_dir)
  fixture_path = File.join(case_dir, "fixture.json")
  output_path = File.join(case_dir, "output")
  api_log = File.join(case_dir, "api.log")
  File.write(fixture_path, JSON.generate(fixture))
  env = {
    "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}", "PLAN_FIXTURE" => fixture_path,
    "PLAN_API_LOG" => api_log, "RUNNER_TEMP" => case_dir,
    "GITHUB_OUTPUT" => output_path, "GITHUB_REPOSITORY" => "gaixianggeng/mimi-remote",
    "GITHUB_RUN_ID" => "99", "SOURCE_SHA" => sha, "FORCE_PUBLISH" => force.to_s,
    "GH_TOKEN" => "fixture-token"
  }
  stdout, stderr, status = Open3.capture3(env, "bash", plan_path)
  output = File.exist?(output_path) ? File.read(output_path) : ""
  if expected == :failure
    abort "#{name}: API 失败后不得继续发布" if status.success? || output.include?("should_publish=")
  else
    abort "#{name}: plan 结果错误\n#{stdout}\n#{stderr}" unless
      status.success? && output.lines.include?("should_publish=#{expected}\n")
    if expected == false
      abort "#{name}: 缺少跳过原因" unless stdout.include?("同一 commit")
      abort "#{name}: 跳过后仍查询基线" if File.read(api_log).lines.any? { |line|
        line.include?("/nightly.yml/runs?") && !line.include?("head_sha=")
      }
    end
    if force
      calls = File.read(api_log)
      abort "force_publish 不得查询发布去重 API" if calls.include?("/ios-ci.yml/runs") || calls.include?("head_sha=")
    end
  end
end
uploaded = { "manual_pages" => [[run]], "job_pages" => [[job]] }
check_plan.call("manual_uploaded", false, uploaded)
check_plan.call("new_commit", true, uploaded.merge("manual_pages" => [[run.merge("head_sha" => "0" * 40)]]))
check_plan.call("manual_tests_only", true, uploaded.merge("job_pages" => [[]]))
failed_job = job.merge("steps" => [{ "name" => "Archive, audit, upload, and distribute build", "conclusion" => "failure" }])
check_plan.call("upload_failed", true, uploaded.merge("job_pages" => [[failed_job]]))
check_plan.call("cleanup_failed_after_upload", false, uploaded.merge("manual_pages" => [[run.merge("conclusion" => "failure")]]))
{
  "push_run" => { "event" => "push" },
  "other_branch" => { "head_branch" => "feature" },
  "other_workflow" => { "path" => ".github/workflows/external.yml" },
  "fork_run" => { "head_repository" => { "full_name" => "example/fork" } },
  "unfinished_run" => { "status" => "in_progress" }
}.each do |name, changes|
  check_plan.call(name, true, uploaded.merge("manual_pages" => [[run.merge(changes)]]))
end
{
  "wrong_job_run" => { "run_id" => 43 },
  "wrong_job_sha" => { "head_sha" => "0" * 40 },
  "other_release_job" => { "name" => "external-release" }
}.each do |name, changes|
  check_plan.call(name, true, uploaded.merge("job_pages" => [[job.merge(changes)]]))
end
check_plan.call("manual_pagination", false, uploaded.merge("manual_pages" => [Array.new(100) { run.merge("event" => "push") }, [run]]))
check_plan.call("jobs_pagination", false, uploaded.merge("job_pages" => [Array.new(100) { job.merge("name" => "regression") }, [job]]))
check_plan.call("force_publish", true, uploaded, true)
check_plan.call("manual_api_failure", :failure, { "api_failure" => true })
check_plan.call("previous_nightly", false, { "nightly_runs" => [{ "id" => 41, "head_sha" => sha, "conclusion" => "success" }] })
puts "Nightly plan 行为回归通过：手动上传、新提交、失败/无上传、来源绑定、分页、强制发布和 API 失败。"
RUBY

  expect_failure() {
    local expected_error="${1:-}"
    local output=""
    if output="$(MIMI_NIGHTLY_RELEASE_ROOT="$test_root" "$0" --check 2>&1)"; then
      fail "self-test 变体本应失败但通过。"
    fi
    if [[ "$output" == *"YAML 无法解析"* ]]; then
      fail "self-test 变体意外产生 YAML 语法错误：$output"
    fi
    if [[ -n "$expected_error" && "$output" != *"$expected_error"* ]]; then
      fail "self-test 变体未命中预期断言（期望包含：${expected_error}；实际：${output}）"
    fi
  }

  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("30 18 * * *", "00 00 * * *"); File.write(p, s)' "$test_root/.github/workflows/nightly.yml"
  expect_failure
  cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("actions: read", "actions: write"); File.write(p, s)' "$test_root/.github/workflows/nightly.yml"
  expect_failure
  cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).gsub("refs/heads/main", "refs/heads/release"); File.write(p, s)' "$test_root/.github/workflows/nightly.yml"
  expect_failure
  mutate_nightly() {
    local old_value="$1"
    local new_value="$2"
    local expected_error="${3:-}"
    cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/nightly.yml" "$old_value" "$new_value"
    expect_failure "$expected_error"
    cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
  }
  mutate_nightly 'artifact["name"] == "nightly-testflight-#{sha}"' 'artifact["name"]'
  mutate_nightly 'if [[ "$should_publish" == "true" ]]; then' 'if true; then'
  mutate_nightly 'run["head_sha"] == ENV.fetch("SOURCE_SHA")' 'true'
  mutate_nightly 'run.dig("head_repository", "full_name") == ENV.fetch("GITHUB_REPOSITORY")' 'true'
  mutate_nightly 'run["path"] == ".github/workflows/ios-ci.yml"' 'true'
  mutate_nightly 'run["event"] == "workflow_dispatch" && run["status"] == "completed"' 'true'
  mutate_nightly 'job["run_id"].to_s == ENV.fetch("EXPECTED_RUN_ID")' 'true'
  mutate_nightly 'job["head_sha"] == ENV.fetch("SOURCE_SHA")' 'true'
  mutate_nightly 'job["name"] == "app-store-release"' 'true'
  mutate_nightly 'step["conclusion"] == "success"' 'true'
  mutate_nightly 'artifact["expired"] == false' 'artifact["expired"] != true'
  mutate_nightly 'workflow_run["id"].to_s == run_id' 'workflow_run["id"]'
  mutate_nightly 'workflow_run["head_sha"] == sha' 'workflow_run["head_sha"]'
  mutate_nightly '[[ "$(unzip -Z1 "$artifact_zip")" == "evidence.json" ]]' 'unzip -Z1 "$artifact_zip" >/dev/null'
  mutate_nightly 'value["source_sha"] == ENV.fetch("SOURCE_SHA") &&' 'true &&'
  mutate_nightly 'value["run_id"].to_s == ENV.fetch("EXPECTED_RUN_ID") &&' 'true &&'
  mutate_nightly 'value["repository"] == ENV.fetch("GITHUB_REPOSITORY") &&' 'true &&'
  mutate_nightly 'value["workflow"] == "Nightly Internal TestFlight" &&' 'true &&'
  mutate_nightly '%w[schedule workflow_dispatch].include?(value["event"]) &&' 'true &&'
  mutate_nightly 'value["uploaded"] == true' 'true'
  mutate_nightly 'IOS_WIDGET_APPSTORE_PROVISIONING_PROFILE_BASE64: ${{ secrets.IOS_WIDGET_APPSTORE_PROVISIONING_PROFILE_BASE64 }}' 'IOS_WIDGET_APPSTORE_PROVISIONING_PROFILE_BASE64: ${{ secrets.IOS_APPSTORE_PROVISIONING_PROFILE_BASE64 }}'
  mutate_nightly "needs.release-secrets-preflight.result == 'success'" "true"
  mutate_nightly $'    environment: ios-testflight-release\n' '' 'Nightly 发布凭据预检必须精确绑定 ios-testflight-release Environment'
  mutate_nightly '    environment: ios-testflight-release' '    environment: production-release' 'Nightly 发布凭据预检必须精确绑定 ios-testflight-release Environment'
  mutate_nightly '    environment: ios-testflight-release' $'    environment:\n      name: "${{ \'ios-testflight-release\' }}"' 'Nightly 发布凭据预检必须精确绑定 ios-testflight-release Environment'
  mutate_nightly '    environment: ios-testflight-release' $'    environment:\n      name: 123' 'Nightly 发布凭据预检必须精确绑定 ios-testflight-release Environment'
  mutate_nightly '    name: Plan Nightly Internal TestFlight' $'    name: Plan Nightly Internal TestFlight\n    environment: ios-testflight-release' 'Nightly plan 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly '    name: Plan Nightly Internal TestFlight' $'    name: Plan Nightly Internal TestFlight\n    environment:\n      name: "${{ \'ios-testflight-release\' }}"' 'Nightly plan 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly '    name: Upload Nightly Internal TestFlight' $'    name: Upload Nightly Internal TestFlight\n    environment: ios-testflight-release' 'Nightly publish 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly '    name: Nightly Internal TestFlight result' $'    name: Nightly Internal TestFlight result\n    environment: ios-testflight-release' 'Nightly final 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly '    name: Nightly Internal TestFlight result' $'    name: Nightly Internal TestFlight result\n    environment: IOS-TESTFLIGHT-RELEASE' 'Nightly final 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly $'\n  final:\n' $'\n  rogue-release-job:\n    runs-on: ubuntu-latest\n    environment:\n      name: IOS-TESTFLIGHT-RELEASE\n    steps:\n      - run: echo leak\n\n  final:\n' 'Nightly rogue-release-job 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_nightly $'\n  final:\n' $'\n  rogue-expr-job:\n    runs-on: ubuntu-latest\n    environment:\n      name: "${{ \'ios-testflight-release\' }}"\n    steps:\n      - run: echo leak\n\n  final:\n' 'Nightly rogue-expr-job 不得绑定 ios-testflight-release 或其他 Environment'

  mutate_ios() {
    local old_value="$1"
    local new_value="$2"
    local expected_error="${3:-}"
    cp "$ROOT_DIR/.github/workflows/ios-ci.yml" "$test_root/.github/workflows/ios-ci.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/ios-ci.yml" "$old_value" "$new_value"
    expect_failure "$expected_error"
    cp "$ROOT_DIR/.github/workflows/ios-ci.yml" "$test_root/.github/workflows/ios-ci.yml"
  }
  mutate_ios 'run: bash ./scripts/ios_testflight_ci.sh' 'run: echo bypass-upload'
  mutate_ios "&& 'release' || 'regression'" "&& 'regression' || 'regression'"
  mutate_ios '${{ !(inputs.publish_internal_testflight || (github.event_name == '\''workflow_dispatch'\'' && inputs.publish_app_store)) }}' '${{ false }}'
  mutate_ios '!(inputs.publish_internal_testflight || (github.event_name == '\''workflow_dispatch'\'' && inputs.publish_app_store))' '!inputs.publish_internal_testflight'
  mutate_ios $'    environment: ios-testflight-release\n' '' 'app-store-release 必须精确绑定 ios-testflight-release Environment'
  mutate_ios '    environment: ios-testflight-release' '    environment: production-release' 'app-store-release 必须精确绑定 ios-testflight-release Environment'
  mutate_ios '    environment: ios-testflight-release' $'    environment:\n      name: "${{ \'ios-testflight-release\' }}"' 'app-store-release 必须精确绑定 ios-testflight-release Environment'
  mutate_ios '    environment: ios-testflight-release' $'    environment:\n      name: 123' 'app-store-release 必须精确绑定 ios-testflight-release Environment'
  mutate_ios '    timeout-minutes: 35' $'    timeout-minutes: 35\n    environment: ios-testflight-release' 'iOS CI conversation-regressions 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios '    timeout-minutes: 35' $'    timeout-minutes: 35\n    environment:\n      name: "${{ \'ios-testflight-release\' }}"' 'iOS CI conversation-regressions 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios '    name: Image recovery UI regressions' $'    name: Image recovery UI regressions\n    environment: ios-testflight-release' 'iOS CI image-recovery-ui-regressions 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios '    name: Tailcat integration (Linux)' $'    name: Tailcat integration (Linux)\n    environment: ios-testflight-release' 'iOS CI tailcat-integration 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios '    name: Tailcat integration (Linux)' $'    name: Tailcat integration (Linux)\n    environment: IOS-TESTFLIGHT-RELEASE' 'iOS CI tailcat-integration 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios $'\n  app-store-release:\n' $'\n  rogue-release-job:\n    runs-on: ubuntu-latest\n    environment:\n      name: IOS-TESTFLIGHT-RELEASE\n    steps:\n      - run: echo leak\n\n  app-store-release:\n' 'iOS CI rogue-release-job 不得绑定 ios-testflight-release 或其他 Environment'
  mutate_ios $'\n  app-store-release:\n' $'\n  rogue-expr-job:\n    runs-on: ubuntu-latest\n    environment:\n      name: "${{ \'ios-testflight-release\' }}"\n    steps:\n      - run: echo leak\n\n  app-store-release:\n' 'iOS CI rogue-expr-job 不得绑定 ios-testflight-release 或其他 Environment'

  mutate_ios $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      inputs.publish_internal_testflight' $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      (github.event_name == \'workflow_call\' && inputs.publish_internal_testflight)' 'reusable workflow 会继承 caller event，禁止用 workflow_call 判断发布路径'
  mutate_ios $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      inputs.publish_internal_testflight' $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      inputs.publish_internal_testflight || github.event_name == \'pull_request\'' 'app-store-release 发布条件禁止包含 pull_request'
  mutate_ios $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      inputs.publish_internal_testflight' $'      (github.event_name == \'workflow_dispatch\' && inputs.publish_app_store) ||\n      inputs.publish_internal_testflight || github.event_name == \'push\'' 'app-store-release 发布条件必须精确保持为'
  mutate_ios $'      publish_internal_testflight:\n        description: "由 Nightly reusable workflow 上传 Internal TestFlight"\n        required: false\n        default: false\n        type: boolean' $'      publish_internal_testflight:\n        description: "由 Nightly reusable workflow 上传 Internal TestFlight"\n        required: false\n        default: true\n        type: boolean' 'ios-ci publish_internal_testflight 默认值必须显式为 false'
  mutate_ios $'      publish_internal_testflight:\n        description: "由 Nightly reusable workflow 上传 Internal TestFlight"\n        required: false\n        default: false\n        type: boolean' $'      publish_internal_testflight:\n        description: "由 Nightly reusable workflow 上传 Internal TestFlight"\n        required: false\n        type: boolean' 'ios-ci publish_internal_testflight 默认值必须显式为 false'
  mutate_ios $'      publish_app_store:\n        description: "在稳定 macOS 26 runner 上归档并上传 Internal TestFlight（不提交 App Store 审核）"\n        required: true\n        default: false\n        type: boolean' $'      publish_app_store:\n        description: "在稳定 macOS 26 runner 上归档并上传 Internal TestFlight（不提交 App Store 审核）"\n        required: true\n        default: true\n        type: boolean' 'ios-ci workflow_dispatch.inputs.publish_app_store 默认值必须显式为 false'

  mutate_pr_gate() {
    local old_value="$1"
    local new_value="$2"
    local expected_error="${3:-}"
    cp "$ROOT_DIR/.github/workflows/pr-gate.yml" "$test_root/.github/workflows/pr-gate.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/pr-gate.yml" "$old_value" "$new_value"
    expect_failure "$expected_error"
    cp "$ROOT_DIR/.github/workflows/pr-gate.yml" "$test_root/.github/workflows/pr-gate.yml"
  }
  mutate_pr_gate $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: true' 'PR Gate ios 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_gate $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_app_store: true' 'PR Gate ios 调用 ios-ci 不得启用 publish_app_store'
  mutate_pr_gate $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      PUBLISH_INTERNAL_TESTFLIGHT: true' 'PR Gate ios 调用 ios-ci 不得启用 PUBLISH_INTERNAL_TESTFLIGHT'
  mutate_pr_gate $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: "false"' 'PR Gate ios 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_gate $'\n  rust:\n' $'\n  rogue-ios-publish:\n    needs: scope\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: true\n\n  rust:\n' 'PR Gate rogue-ios-publish 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_gate '    name: Detect change scope' $'    name: Detect change scope\n    environment: ios-testflight-release' 'PR Gate scope 不得绑定 ios-testflight-release 或其他 Environment'

  mutate_pr_metadata() {
    local old_value="$1"
    local new_value="$2"
    local expected_error="${3:-}"
    cp "$ROOT_DIR/.github/workflows/pr-metadata.yml" "$test_root/.github/workflows/pr-metadata.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/pr-metadata.yml" "$old_value" "$new_value"
    expect_failure "$expected_error"
    cp "$ROOT_DIR/.github/workflows/pr-metadata.yml" "$test_root/.github/workflows/pr-metadata.yml"
  }
  # 独立 PR workflow（pr-metadata.yml）变异：覆盖 Codex R2 三项复现与额外边界。
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-release-env:\n    runs-on: ubuntu-latest\n    environment:\n      name: IOS-TESTFLIGHT-RELEASE\n    steps:\n      - run: true\n\n  metadata:\n' 'pr-metadata.yml rogue-release-env 不得绑定 ios-testflight-release Environment'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-expr-env:\n    runs-on: ubuntu-latest\n    environment:\n      name: "${{ \'ios-testflight-release\' }}"\n    steps:\n      - run: true\n\n  metadata:\n' 'pr-metadata.yml rogue-expr-env（environment 名称必须是非空常量，禁止表达式）'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-ios-publish:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: true\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-ios-publish 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-str-env:\n    runs-on: ubuntu-latest\n    environment: ios-testflight-release\n    steps:\n      - run: true\n\n  metadata:\n' 'pr-metadata.yml rogue-str-env 不得绑定 ios-testflight-release Environment'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-prod-env:\n    runs-on: ubuntu-latest\n    environment: production-release\n    steps:\n      - run: true\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-prod-env 不得绑定 Environment'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-ios-appstore:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_app_store: true\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-ios-appstore 调用 ios-ci 不得启用 publish_app_store'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-ios-str-false:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: "false"\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-ios-str-false 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_metadata $'jobs:\n  metadata:\n' $'jobs:\n  rogue-ios-expr-publish:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: "${{ true }}"\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-ios-expr-publish 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_metadata $'on:\n  pull_request:\n    types:\n      - opened\n      - edited\n      - synchronize\n      - reopened\n\npermissions:\n  contents: read\n\nconcurrency:\n  group: pr-metadata-${{ github.event.pull_request.number }}\n  cancel-in-progress: true\n\njobs:\n  metadata:\n' $'on:\n  pull_request_target:\n    types:\n      - opened\n\npermissions:\n  contents: read\n\njobs:\n  rogue-pr-target-publish:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: true\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-pr-target-publish 调用 ios-ci 不得启用 publish_internal_testflight'
  mutate_pr_metadata $'on:\n  pull_request:\n    types:\n      - opened\n      - edited\n      - synchronize\n      - reopened\n\npermissions:\n  contents: read\n\nconcurrency:\n  group: pr-metadata-${{ github.event.pull_request.number }}\n  cancel-in-progress: true\n\njobs:\n  metadata:\n' $'on: [pull_request]\n\npermissions:\n  contents: read\n\njobs:\n  rogue-array-on-publish:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: true\n\n  metadata:\n' 'PR workflow pr-metadata.yml rogue-array-on-publish 调用 ios-ci 不得启用 publish_internal_testflight'

  # 全仓 .yaml 扩展名、非 PR workflow 与经本地 reusable workflow 链式调用的隔离变异。
  cat >"$test_root/.github/workflows/rogue-extra.yaml" <<'YAML'
name: Rogue Extra
on: push
jobs:
  rogue-push-env:
    runs-on: ubuntu-latest
    environment:
      name: IOS-TESTFLIGHT-RELEASE
    steps:
      - run: true
YAML
  expect_failure 'rogue-extra.yaml rogue-push-env 不得绑定 ios-testflight-release Environment'
  cat >"$test_root/.github/workflows/rogue-extra.yaml" <<'YAML'
name: Rogue Extra Expr
on: workflow_dispatch
jobs:
  rogue-dispatch-expr:
    runs-on: ubuntu-latest
    environment:
      name: "${{ inputs.env }}"
    steps:
      - run: true
YAML
  expect_failure 'rogue-extra.yaml rogue-dispatch-expr（environment 名称必须是非空常量，禁止表达式）'
  rm -f "$test_root/.github/workflows/rogue-extra.yaml"

  cat >"$test_root/.github/workflows/rogue-chain-caller.yml" <<'YAML'
name: Rogue Chain Caller
on: pull_request
jobs:
  entry:
    uses: ./.github/workflows/rogue-chain-mid.yaml
YAML
  cat >"$test_root/.github/workflows/rogue-chain-mid.yaml" <<'YAML'
name: Rogue Chain Mid
on: workflow_call
jobs:
  relay:
    uses: ./.github/workflows/ios-ci.yml
    with:
      publish_internal_testflight: true
YAML
  expect_failure 'PR workflow rogue-chain-mid.yaml relay 调用 ios-ci 不得启用 publish_internal_testflight'
  rm -f "$test_root/.github/workflows/rogue-chain-caller.yml" "$test_root/.github/workflows/rogue-chain-mid.yaml"

  # 正向等价形式核验：指定发布 job 允许常量 mapping 与大小写等价名称，PR workflow 允许不启用发布的 ios-ci 调用。
  expect_pass_mutation() {
    local rel_path="$1"
    local old_value="$2"
    local new_value="$3"
    cp "$ROOT_DIR/$rel_path" "$test_root/$rel_path"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test positive mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/$rel_path" "$old_value" "$new_value"
    local output=""
    if ! output="$(MIMI_NIGHTLY_RELEASE_ROOT="$test_root" "$0" --check 2>&1)"; then
      cp "$ROOT_DIR/$rel_path" "$test_root/$rel_path"
      fail "self-test 正向等价变体本应通过但失败（${rel_path}）：${output}"
    fi
    cp "$ROOT_DIR/$rel_path" "$test_root/$rel_path"
  }
  expect_pass_mutation '.github/workflows/nightly.yml' '    environment: ios-testflight-release' $'    environment:\n      name: ios-testflight-release'
  expect_pass_mutation '.github/workflows/ios-ci.yml' '    environment: ios-testflight-release' $'    environment:\n      name: IOS-TESTFLIGHT-RELEASE'
  expect_pass_mutation '.github/workflows/pr-gate.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml' $'  ios:\n    name: iOS\n    needs: scope\n    if: needs.scope.outputs.ios == \'true\'\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: false'
  expect_pass_mutation '.github/workflows/pr-metadata.yml' $'jobs:\n  metadata:\n' $'jobs:\n  ios-regression-only:\n    uses: ./.github/workflows/ios-ci.yml\n\n  metadata:\n'
  expect_pass_mutation '.github/workflows/pr-metadata.yml' $'jobs:\n  metadata:\n' $'jobs:\n  ios-regression-explicit-false:\n    uses: ./.github/workflows/ios-ci.yml\n    with:\n      publish_internal_testflight: false\n\n  metadata:\n'
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("name: Release", "name: release-validation drift"); File.write(p, s)' "$test_root/.github/workflows/release.yml"
  expect_failure
  cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/release.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("name: Release", "name: attestation drift"); File.write(p, s)' "$test_root/.github/workflows/release.yml"
  expect_failure
  mutate_release() {
    local old_value="$1"
    local new_value="$2"
    local expected_error="${3:-}"
    cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/release.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/release.yml" "$old_value" "$new_value"
    expect_failure "$expected_error"
    cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/release.yml"
  }
  mutate_release 'repository_dispatch:' 'push:'
  mutate_release '      - linux-smoke' '      - verify'
  mutate_release 'args: release --clean --skip=publish' 'args: release --clean'
  mutate_release 'GOFLAGS=-json bash ./scripts/test-linux-tailcat-package.sh "$binary"' 'true'
  mutate_release 'run: bash ./scripts/check-release-source.sh --check' 'run: echo bypassed'
  mutate_release 'needs: source-trust' 'needs: []'
  mutate_release 'run: bash ./scripts/check-public-repo-safety.sh --full-history' 'run: echo bypassed'
  mutate_release 'ref: ${{ needs.source-trust.outputs.tag_sha }}' 'ref: ${{ github.sha }}'
  mutate_release '      - name: Check public repository safety
        run:' '      - name: Check public repository safety
        continue-on-error: true
        run:'
  mutate_release '  verify:
    needs:
      - source-trust
      - verify-safety' '  verify:
    needs: source-trust'
  mutate_release '  verify-windows:
    needs:
      - source-trust
      - verify-safety' '  verify-windows:
    needs: source-trust'
  mutate_release '  release:
    needs:
      - source-trust
      - verify-safety' '  release:
    needs:
      - source-trust'
  mutate_release '      - source-trust
      - verify-safety
      - release
      - verify-windows' '      - release
      - verify-windows'
  mutate_release 'environment: production-release' 'environment: bypass-release'
  mutate_release 'fetch-depth: 0' 'fetch-depth: 1'
  mutate_release 'GORELEASER_CURRENT_TAG: ${{ env.RELEASE_TAG }}' 'GORELEASER_CURRENT_TAG: v0.0.0'
  mutate_release 'permissions:
  contents: read' 'permissions:
  contents: write'
  mutate_release '    name: Verify release source' '    name: Verify release source
    permissions:
      contents: write'
  mutate_release '      - name: Trust gate before release secrets
        id: source
        run:' '      - name: Trust gate before release secrets
        id: source
        continue-on-error: true
        run:'
  mutate_release '  verify:' '  bypass-release-trust:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    environment: production-release
    steps:
      - run: echo "$STOLEN"
        env:
          STOLEN: ${{ secrets.TAP_DEPLOY_KEY }}

  verify:'
  echo "Nightly/Release checker self-test 通过：schedule、权限、trust gate、发布凭据预检、发布谓词/默认值/PR Gate 与独立 PR workflow 隔离、全仓 ios-testflight-release Environment 绑定隔离、evidence 绑定、Release default-branch source-trust、旁路 job 与 validation/attestation 漂移均能失败。"
}

case "${1:---check}" in
  --check) run_check ;;
  --self-test) self_test ;;
  *) fail "用法：bash ./scripts/check-nightly-release.sh [--check|--self-test]" ;;
esac
