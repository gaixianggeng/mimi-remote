#!/usr/bin/env ruby
# frozen_string_literal: true

# 生成 Nightly TestFlight 的 What to Test。此脚本只读取 checkout 中的 Git
# 历史，不读取 Secret，也不把提交者、路径或环境变量写入发布说明。

require "date"
require "fileutils"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"

MAX_LENGTH = 4000
MAX_TITLE_LENGTH = 180
FALLBACK_NO_BASELINE = "建议完整验证当前构建（首次 Nightly 或找不到上一成功 Nightly 基线）。"
FALLBACK_NO_USER_CHANGES = "仅内部维护/文档/测试调整，无新增用户功能。"

class GitCommandError < StandardError; end

def git_output(repo, *arguments)
  stdout, stderr, status = Open3.capture3("git", *arguments, chdir: repo)
  return stdout if status.success?

  detail = stderr.to_s.strip
  detail = "退出码 #{status.exitstatus}" if detail.empty?
  raise GitCommandError, "git #{arguments.join(" ")} 失败：#{detail}"
end

def valid_sha?(value)
  value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/i)
end

def commit_exists?(repo, sha)
  return false unless valid_sha?(sha)

  _stdout, _stderr, status = Open3.capture3("git", "cat-file", "-e", "#{sha}^{commit}", chdir: repo)
  status.success?
end

def ancestor?(repo, base_sha, head_sha)
  return false unless commit_exists?(repo, base_sha) && commit_exists?(repo, head_sha)

  _stdout, _stderr, status = Open3.capture3("git", "merge-base", "--is-ancestor", base_sha, head_sha, chdir: repo)
  status.success?
end

def short_sha(sha)
  valid_sha?(sha) ? sha[0, 7] : sha.to_s.gsub(/[^0-9a-f]/i, "")[0, 7].to_s
end

def normalized_title(value)
  # 提交 subject 理论上只有一行，但仍清洗控制字符和换行，避免把恶意标题
  # 变成额外的 What to Test 行或 GitHub Actions output 控制内容。
  cleaned = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  cleaned = cleaned.gsub(/[[:space:]\p{Cc}]+/u, " ").strip
  return "" if cleaned.empty?

  return cleaned if cleaned.length <= MAX_TITLE_LENGTH

  "#{cleaned[0, MAX_TITLE_LENGTH - 1]}…"
end

def documentation_path?(path)
  basename = File.basename(path)
  path.start_with?("docs/", "artifacts/") ||
    basename.match?(/\.(?:md|markdown|rst|txt)\z/i) ||
    basename.match?(/\A(?:README|CHANGELOG|CONTRIBUTING|SECURITY|LICENSE)(?:\.|\z)/i)
end

def test_path?(path)
  parts = path.split("/")
  basename = parts.last.to_s
  parts.any? { |part| part.match?(/\A(?:test|tests|testdata|spec|specs|fixtures?)\z/i) } ||
    parts.any? { |part| part.match?(%r{\A(?:[^/]+)(?:Tests|UITests)\z}) } ||
    basename.match?(/(?:\A|[._-])(?:test|tests|spec)(?:[._-]|\z)/i) ||
    basename.match?(/_test\.[^.]+\z/i)
end

def release_control_path?(path)
  path.start_with?("config/release/", "scripts/release/") ||
    path.match?(%r{\Ascripts/(?:check|test|verify|ci|generate|build|sign|deploy|package|install)-}) ||
    path.match?(%r{\Ascripts/(?:ios_asc|ios_testflight|distribute_internal|git-testflight)}) ||
    path.match?(%r{\Ascripts/[^/]*(?:release|testflight)[^/]*\z}i) ||
    path == ".goreleaser.yml"
end

def ci_control_path?(path)
  path.start_with?(".github/", ".circleci/", ".buildkite/") ||
    %w[Jenkinsfile Makefile].include?(path)
end

def noise_path?(path)
  documentation_path?(path) || test_path?(path) || release_control_path?(path) || ci_control_path?(path)
end

def testflight_payload_path?(path)
  # Nightly 只上传 iOS App 与 Widget；Mac、agentd、Web 等源码即使是用户可感知
  # 功能，也不属于这个 TestFlight 构建，不能写进本包的测试说明。
  return true if path.start_with?("ios/MimiRemote/Sources/") && !path.include?("/.claude/")
  return true if path.start_with?("ios/MimiRemote/WidgetExtension/")
  return true if path.start_with?("ios/MimiRemote/Resources/Assets.xcassets/") &&
    !path.start_with?("ios/MimiRemote/Resources/Assets.xcassets/AppIconMac.appiconset/")
  return true if %w[
    ios/MimiRemote/Resources/Info.plist
    ios/MimiRemote/Resources/Localizable.xcstrings
    ios/MimiRemote/Resources/MimiRemote.entitlements
    ios/MimiRemote/Resources/PrivacyInfo.xcprivacy
    ios/MimiRemote/Resources/en.lproj/InfoPlist.strings
    ios/MimiRemote/Resources/zh-Hans.lproj/InfoPlist.strings
    ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj
    ios/MimiRemote/MimiRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    ios/MimiRemote/project.yml
  ].include?(path)

  false
end

def changed_paths(repo, commit_sha)
  git_output(
    repo,
    "diff-tree",
    "--root",
    "--no-commit-id",
    "--name-only",
    "-r",
    "-z",
    "--no-renames",
    commit_sha
  ).split("\0").reject(&:empty?)
end

def commit_subject(repo, commit_sha)
  git_output(repo, "log", "-1", "--format=%s", commit_sha).lines.first.to_s
end

def range_commits(repo, base_sha, head_sha)
  git_output(repo, "log", "--no-merges", "--reverse", "--format=%H", "#{base_sha}..#{head_sha}")
    .lines
    .map(&:strip)
    .reject(&:empty?)
end

def user_change_titles(repo, base_sha, head_sha)
  seen = {}
  range_commits(repo, base_sha, head_sha).each_with_object([]) do |commit_sha, titles|
    paths = changed_paths(repo, commit_sha)
    # 只有真正进入 TestFlight payload 的生产文件才能生成条目。混合提交
    # 保留原 subject，无法归属到 iOS/Widget 产物时不猜测用户功能。
    relevant_paths = paths.reject { |path| noise_path?(path) }
    next unless relevant_paths.any? { |path| testflight_payload_path?(path) }

    title = normalized_title(commit_subject(repo, commit_sha))
    next if title.empty? || seen[title]

    seen[title] = true
    titles << title
  end
end

def render_summary(date, base_sha, head_sha, titles)
  date_line = "Nightly 日期：#{date}"
  if valid_sha?(base_sha) && base_sha != head_sha && ancestor?(Dir.pwd, base_sha, head_sha)
    header = [date_line, "SHA 范围：#{short_sha(base_sha)}..#{short_sha(head_sha)}", "本次更新："]
  else
    header = [date_line, "当前 SHA：#{short_sha(head_sha)}", "本次更新："]
    titles = [FALLBACK_NO_BASELINE]
  end

  if titles.empty?
    titles = [FALLBACK_NO_USER_CHANGES]
  end

  render = lambda do |selected|
    (header + selected.map { |title| "- #{title}" }).join("\n")
  end
  result = render.call(titles)
  return result if result.length <= MAX_LENGTH

  # 先稳定地按 Git log 顺序保留条目，再追加明确的省略数量；若 marker 本身
  # 仍超限，逐项回退，保证任何 Unicode 字符串都不会超过 4000 个字符。
  selected = []
  titles.each do |title|
    candidate = render.call(selected + [title])
    break if candidate.length > MAX_LENGTH

    selected << title
  end

  remaining = titles.length - selected.length
  marker = "其余 #{remaining} 项更新未展开（内容已截断）。"
  while render.call(selected + [marker]).length > MAX_LENGTH && selected.any?
    selected.pop
    remaining += 1
    marker = "其余 #{remaining} 项更新未展开（内容已截断）。"
  end

  final = render.call(selected + [marker])
  # header 远小于上限；该保护只防止未来修改 header 时破坏长度契约。
  final[0, MAX_LENGTH]
end

def generate_summary(repo, date, base_sha, head_sha)
  unless valid_sha?(head_sha) && commit_exists?(repo, head_sha)
    raise ArgumentError, "head SHA 必须是存在的 40 位 commit SHA。"
  end

  usable_base = valid_sha?(base_sha) && base_sha != head_sha && ancestor?(repo, base_sha, head_sha) ? base_sha : nil
  titles = usable_base ? user_change_titles(repo, usable_base, head_sha) : []
  # render_summary 通过 Dir.pwd 判断祖先关系；调用方固定传入 checkout 根目录，
  # 这里使用同一目录生成最终内容，避免误把不可达基线当成可信 range。
  previous_dir = Dir.pwd
  Dir.chdir(repo) do
    return render_summary(date, usable_base, head_sha, titles)
  end
ensure
  Dir.chdir(previous_dir) if previous_dir && Dir.pwd != previous_dir
end

def run_self_test
  included_payload_paths = %w[
    ios/MimiRemote/Sources/RootView.swift
    ios/MimiRemote/WidgetExtension/Info.plist
    ios/MimiRemote/Resources/Info.plist
    ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
    ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj
    ios/MimiRemote/MimiRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    ios/MimiRemote/project.yml
  ]
  excluded_payload_paths = %w[
    ios/MimiRemote/Resources/Info-Catalyst.plist
    ios/MimiRemote/Resources/MimiRemote-Catalyst.entitlements
    ios/MimiRemote/Resources/LocalizationTechnicalStringAllowlist.json
    ios/MimiRemote/Resources/Assets.xcassets/AppIconMac.appiconset/Contents.json
    ios/MimiRemote/MimiRemote.xcodeproj/xcshareddata/xcschemes/MimiRemotePhysicalUITests.xcscheme
    ios/MimiRemote/Sources/Features/.claude/settings.json
    macos/MimiRemoteMac/Sources/App/MimiRemoteMacApp.swift
  ]
  raise "self-test: iOS/Widget payload 路径被漏掉" unless included_payload_paths.all? { |path| testflight_payload_path?(path) }
  raise "self-test: 非 TestFlight payload 路径被误收" if excluded_payload_paths.any? { |path| testflight_payload_path?(path) }

  Dir.mktmpdir("mimi-nightly-what-to-test-self-test") do |repo|
    git = lambda do |*args|
      git_output(repo, *args)
    end
    git.call("init", "-q")
    git.call("config", "user.name", "Mimi Nightly Self Test")
    git.call("config", "user.email", "nightly-self-test@example.invalid")

    write_commit = lambda do |path, content, title|
      absolute = File.join(repo, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
      git.call("add", "--", path)
      git.call("commit", "-q", "-m", title)
      git.call("rev-parse", "HEAD").strip
    end

    write_commit.call("ios/MimiRemote/Sources/base.swift", "struct Base {}\n", "baseline")
    baseline = git.call("rev-parse", "HEAD").strip
    first = write_commit.call("ios/MimiRemote/Sources/feature.swift", "struct Feature {}\n", "Add feature")
    duplicate = write_commit.call("ios/MimiRemote/Sources/feature.swift", "struct Feature { let v = 2 }\n", "Add feature")
    write_commit.call("docs/notes.md", "docs\n", "Document feature")
    write_commit.call("Tests/FeatureTests.swift", "tests\n", "Test feature")
    write_commit.call(".github/workflows/example.yml", "name: CI\n", "Tune CI")
    write_commit.call("scripts/check-nightly-release.sh", "#!/usr/bin/env bash\n", "Harden release check")
    write_commit.call("internal/httpapi/daemon.go", "package httpapi\n", "Backend only change")
    write_commit.call("ios/MimiRemote/WidgetExtension/another.swift", "struct Another {}\n", "Second feature")
    main_branch = git.call("branch", "--show-current").strip
    git.call("checkout", "-q", "-b", "nightly-self-test-feature")
    write_commit.call("ios/MimiRemote/Sources/branch.swift", "struct BranchFeature {}\n", "Branch feature")
    git.call("checkout", "-q", main_branch)
    git.call("merge", "--no-ff", "-q", "-m", "Merge synthetic branch", "nightly-self-test-feature")
    latest = git.call("rev-parse", "HEAD").strip

    summary = generate_summary(repo, "2026-08-18", baseline, latest)
    raise "self-test: 多提交标题缺失" unless summary.include?("- Add feature") && summary.include?("- Second feature") && summary.include?("- Branch feature")
    raise "self-test: 重复标题未去重" unless summary.scan("- Add feature").length == 1
    raise "self-test: 噪音提交未过滤" if summary.include?("Document feature") || summary.include?("Tune CI") || summary.include?("Harden release check") || summary.include?("Backend only change")
    raise "self-test: merge commit 未过滤" if summary.include?("Merge synthetic branch")
    raise "self-test: summary 应包含范围" unless summary.include?("SHA 范围：#{short_sha(baseline)}..#{short_sha(latest)}")
    raise "self-test: 未覆盖中间提交" unless first != duplicate

    noise_head = write_commit.call("docs/only.md", "docs\n", "Only docs")
    noise_summary = generate_summary(repo, "2026-08-18", latest, noise_head)
    raise "self-test: 纯噪音兜底缺失" unless noise_summary.include?(FALLBACK_NO_USER_CHANGES)

    first_summary = generate_summary(repo, "2026-08-18", nil, latest)
    raise "self-test: 首次 Nightly 兜底缺失" unless first_summary.include?(FALLBACK_NO_BASELINE) && first_summary.include?(short_sha(latest))
    invalid_base_summary = generate_summary(repo, "2026-08-18", "0" * 40, latest)
    raise "self-test: 无效基线未安全兜底" unless invalid_base_summary.include?(FALLBACK_NO_BASELINE)

    malicious = normalized_title("unsafe\n::set-output name=token::leak\r\nnext")
    raise "self-test: 恶意/换行 subject 未清洗" if malicious.include?("\n") || malicious.include?("\r")
    raise "self-test: 恶意 subject 未保持单行" unless malicious.lines.length == 1

    long_base = git.call("rev-parse", "HEAD").strip
    40.times do |index|
      write_commit.call("ios/MimiRemote/Sources/long-#{index}.swift", "struct Long#{index} {}\n", "Long feature #{index} #{'x' * 220}")
    end
    long_head = git.call("rev-parse", "HEAD").strip
    long_summary = generate_summary(repo, "2026-08-18", long_base, long_head)
    raise "self-test: 超长内容超过 4000 字符" unless long_summary.length <= MAX_LENGTH
    raise "self-test: 超长内容未说明省略项" unless long_summary.include?("内容已截断") && long_summary.match?(/其余 \d+ 项更新未展开/)
    raise "self-test: 输出含独立控制行" if long_summary.lines.any? { |line| line.chomp == "::set-output" }

    puts "Nightly What to Test 生成器自测通过：首次/无效基线、纯噪音、多提交、去重、长度上限与恶意标题场景均符合预期。"
  end
end

options = { date: Date.today.iso8601, base_sha: nil, head_sha: nil, self_test: false }
OptionParser.new do |parser|
  parser.banner = "用法：ruby scripts/generate-nightly-what-to-test.rb --head-sha SHA [--base-sha SHA] [--date YYYY-MM-DD]"
  parser.on("--head-sha SHA", "当前 Nightly immutable commit SHA") { |value| options[:head_sha] = value }
  parser.on("--base-sha SHA", "上一成功 Nightly 的可达基线 SHA") { |value| options[:base_sha] = value }
  parser.on("--date DATE", "Nightly 日期（YYYY-MM-DD）") { |value| options[:date] = value }
  parser.on("--self-test", "运行无网络生成器自测") { options[:self_test] = true }
end.parse!

if options[:self_test]
  run_self_test
  exit 0
end

abort "必须提供 --head-sha。" unless options[:head_sha]
begin
  Date.iso8601(options[:date])
rescue Date::Error
  abort "--date 必须是 YYYY-MM-DD。"
end

begin
  puts generate_summary(Dir.pwd, options[:date], options[:base_sha], options[:head_sha])
rescue ArgumentError, GitCommandError => error
  abort "Nightly What to Test 生成失败：#{error.message}"
end
