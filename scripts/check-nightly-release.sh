#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ROOT="${MIMI_NIGHTLY_RELEASE_ROOT:-$ROOT_DIR}"

fail() {
  echo "Nightly/Release 自检失败：$1" >&2
  exit 1
}

run_check() {
  ruby - "$CHECK_ROOT/.github/workflows/nightly.yml" \
    "$CHECK_ROOT/.github/workflows/ios-ci.yml" \
    "$CHECK_ROOT/.github/workflows/release.yml" \
    "$CHECK_ROOT/scripts/distribute_internal_build.rb" \
    "$CHECK_ROOT/scripts/generate-nightly-what-to-test.rb" <<'RUBY'
require "yaml"

def fail_check(message)
  abort("Nightly/Release 自检失败：#{message}")
end

def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: true)
rescue Psych::SyntaxError => error
  fail_check("#{path} YAML 无法解析：#{error.message}")
end

def triggers(workflow, path)
  value = workflow["on"] || workflow[true]
  fail_check("#{path} 缺少 on") unless value.is_a?(Hash)
  value
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

def assert_pinned_actions(path, workflow)
  workflow.fetch("jobs").each do |job_id, job|
    candidates = []
    candidates << job if job["uses"]
    candidates.concat(steps(job))
    candidates.each do |candidate|
      action = candidate["uses"]
      next if action.nil? || action.start_with?("./")
      fail_check("#{path} #{job_id} action 未固定完整 commit SHA：#{action}") unless
        action.match?(/@[0-9a-f]{40}\z/)
    end
  end
end

nightly_path, ios_path, release_path, distributor_path, generator_path = ARGV
nightly = load_yaml(nightly_path)
ios = load_yaml(ios_path)
release = load_yaml(release_path)
fail_check("Nightly What to Test 生成器不存在") unless File.file?(generator_path)
generator = File.read(generator_path)
[nightly, ios, release].zip([nightly_path, ios_path, release_path]).each do |workflow, path|
  assert_pinned_actions(path, workflow)
end

nightly_triggers = triggers(nightly, nightly_path)
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
secrets_step = step(release_secrets, "Require App Store signing secrets")
required_release_secrets = %w[
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_PRIVATE_KEY
  IOS_APPSTORE_PROVISIONING_PROFILE_BASE64
  IOS_WIDGET_APPSTORE_PROVISIONING_PROFILE_BASE64
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
call = ios_triggers.fetch("workflow_call")
%w[source_ref publish_internal_testflight what_to_test].each do |name|
  fail_check("ios-ci workflow_call 缺少 #{name}") unless call.dig("inputs", name)
end
fail_check("ios-ci source_ref 类型错误") unless call.dig("inputs", "source_ref", "type") == "string"
fail_check("ios-ci publish_internal_testflight 必须是 bool") unless call.dig("inputs", "publish_internal_testflight", "type") == "boolean"
fail_check("ios-ci what_to_test 类型错误") unless call.dig("inputs", "what_to_test", "type") == "string"
ios_jobs = ios.fetch("jobs")
conversation = ios_jobs.fetch("conversation-regressions")
checkout = steps(conversation).find { |item| item["uses"].to_s.start_with?("actions/checkout@") }
fail_check("conversation-regressions 必须 checkout immutable source_ref") unless checkout && checkout.dig("with", "ref").to_s.include?("inputs.source_ref")
app = ios_jobs.fetch("app-store-release")
fail_check("signed app-store-release 必须等待 conversation-regressions") unless Array(app["needs"]) == ["conversation-regressions"]
condition = app.fetch("if").to_s
fail_check("app-store-release 缺少手工 publish_app_store 条件") unless condition.include?("workflow_dispatch") && condition.include?("publish_app_store")
fail_check("app-store-release 缺少 reusable publish_internal_testflight 条件") unless condition.include?("publish_internal_testflight")
fail_check("reusable workflow 会继承 caller event，禁止用 workflow_call 判断发布路径") if condition.include?("workflow_call")
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
evidence = step(app, "Write Nightly TestFlight evidence")
artifact = step(app, "Upload Nightly TestFlight evidence")
fail_check("Nightly evidence 只能由显式 reusable publish input 生成") unless
  evidence["if"].to_s.include?("publish_internal_testflight") && !evidence["if"].to_s.include?("event_name")
fail_check("Nightly evidence JSON 字段不完整") unless %w[source_sha run_id run_attempt repository workflow event uploaded].all? { |key| evidence.to_s.include?(key) }
fail_check("Nightly evidence artifact 配置错误") unless artifact["uses"].to_s.match?(/@[0-9a-f]{40}\z/) && artifact.dig("with", "name").to_s.include?("nightly-testflight-") && artifact.dig("with", "retention-days") == 30

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
expected_release_jobs = %w[source-trust verify verify-windows release publish-windows]
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

%w[verify verify-windows release publish-windows].each do |job_name|
  job = release_jobs.fetch(job_name)
  fail_check("Release #{job_name} 仓库条件不可放宽") unless
    job["if"] == "github.repository == 'gaixianggeng/mimi-remote'"
  fail_check("Release #{job_name} 没有显式依赖 source-trust") unless
    Array(job["needs"]).include?("source-trust")
  fail_check("Release #{job_name} 没有绑定 production-release Environment") unless
    job["environment"] == "production-release"
end
windows_publish = release_jobs.fetch("publish-windows")
fail_check("Windows 发布 job 必须依赖已验证 artifact 和已创建的正式 Release") unless
  Array(windows_publish["needs"]).sort == %w[release source-trust verify-windows].sort
fail_check("Windows 发布 job 必须使用 Windows runner 和最小 contents:write 权限") unless
  windows_publish["runs-on"] == "windows-latest" &&
  windows_publish["permissions"] == { "contents" => "write" }
%w[verify verify-windows release].each do |job_name|
  checkout = steps(release_jobs.fetch(job_name)).find { |item| item["uses"].to_s.start_with?("actions/checkout@") }
  fail_check("Release #{job_name} 没有 checkout source-trust 验证的 immutable SHA") unless
    checkout && checkout.dig("with", "ref").to_s.include?("needs.source-trust.outputs.tag_sha")
end
%w[verify release].each do |job_name|
  goreleaser_step_name = job_name == "verify" ? "Build release snapshot" : "Release"
  goreleaser_step = step(release_jobs.fetch(job_name), goreleaser_step_name)
  fail_check("Release #{job_name} 的 GoReleaser 没有绑定 source-trust 校验的 RELEASE_TAG") unless
    goreleaser_step.dig("env", "GORELEASER_CURRENT_TAG") == "${{ env.RELEASE_TAG }}"
end
fail_check("Release workflow 不得从 dispatch 的 main ref 推导发布版本") if
  release.to_s.include?("GITHUB_REF_NAME")
distributor = File.read(distributor_path)
fail_check("Internal TestFlight 组校验必须 fail-closed") unless distributor.include?('unless group.dig("attributes", "isInternalGroup") == true')

puts "Nightly/Release workflow 自检通过。"
RUBY
}

self_test() {
  local test_root
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-nightly-release-self-test.XXXXXX")"
  trap 'rm -rf "$test_root"' RETURN
  mkdir -p "$test_root/.github/workflows" "$test_root/scripts"
  cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/"
  cp "$ROOT_DIR/.github/workflows/ios-ci.yml" "$test_root/.github/workflows/"
  cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/"
  cp "$ROOT_DIR/scripts/distribute_internal_build.rb" "$test_root/scripts/"
  cp "$ROOT_DIR/scripts/generate-nightly-what-to-test.rb" "$test_root/scripts/"
  MIMI_NIGHTLY_RELEASE_ROOT="$test_root" "$0" --check >/dev/null
  ruby "$test_root/scripts/generate-nightly-what-to-test.rb" --self-test >/dev/null

  expect_failure() {
    if MIMI_NIGHTLY_RELEASE_ROOT="$test_root" "$0" --check >/dev/null 2>&1; then
      fail "self-test 变体本应失败但通过。"
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
    cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/nightly.yml" "$old_value" "$new_value"
    expect_failure
  }
  mutate_nightly 'artifact["name"] == "nightly-testflight-#{sha}"' 'artifact["name"]'
  mutate_nightly 'if [[ "$should_publish" == "true" ]]; then' 'if true; then'
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

  mutate_ios() {
    local old_value="$1"
    local new_value="$2"
    cp "$ROOT_DIR/.github/workflows/ios-ci.yml" "$test_root/.github/workflows/ios-ci.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/ios-ci.yml" "$old_value" "$new_value"
    expect_failure
  }
  mutate_ios "&& 'release' || 'regression'" "&& 'regression' || 'regression'"
  mutate_ios '${{ !(inputs.publish_internal_testflight || (github.event_name == '\''workflow_dispatch'\'' && inputs.publish_app_store)) }}' '${{ false }}'
  mutate_ios '!(inputs.publish_internal_testflight || (github.event_name == '\''workflow_dispatch'\'' && inputs.publish_app_store))' '!inputs.publish_internal_testflight'

  cp "$ROOT_DIR/.github/workflows/nightly.yml" "$test_root/.github/workflows/nightly.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("      inputs.publish_internal_testflight", "      (github.event_name == '\''workflow_call'\'' && inputs.publish_internal_testflight)"); File.write(p, s)' "$test_root/.github/workflows/ios-ci.yml"
  expect_failure
  cp "$ROOT_DIR/.github/workflows/ios-ci.yml" "$test_root/.github/workflows/ios-ci.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("name: Release", "name: release-validation drift"); File.write(p, s)' "$test_root/.github/workflows/release.yml"
  expect_failure
  cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/release.yml"
  ruby -e 'p = ARGV.fetch(0); s = File.read(p).sub("name: Release", "name: attestation drift"); File.write(p, s)' "$test_root/.github/workflows/release.yml"
  expect_failure
  mutate_release() {
    local old_value="$1"
    local new_value="$2"
    cp "$ROOT_DIR/.github/workflows/release.yml" "$test_root/.github/workflows/release.yml"
    ruby -e '
      path, old_value, new_value = ARGV
      source = File.read(path)
      abort "self-test mutation target missing: #{old_value}" unless source.include?(old_value)
      File.write(path, source.sub(old_value, new_value))
    ' "$test_root/.github/workflows/release.yml" "$old_value" "$new_value"
    expect_failure
  }
  mutate_release 'repository_dispatch:' 'push:'
  mutate_release 'run: bash ./scripts/check-release-source.sh --check' 'run: echo bypassed'
  mutate_release 'needs: source-trust' 'needs: []'
  mutate_release '      - source-trust
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
  echo "Nightly/Release checker self-test 通过：schedule、权限、trust gate、发布凭据预检、evidence 绑定、Release default-branch source-trust、旁路 job 与 validation/attestation 漂移均能失败。"
}

case "${1:---check}" in
  --check) run_check ;;
  --self-test) self_test ;;
  *) fail "用法：bash ./scripts/check-nightly-release.sh [--check|--self-test]" ;;
esac
