#!/usr/bin/env bash

# 这个文件由 ios-dev.sh source，依赖其中的 ROOT_DIR、PROJECT_PATH、SCHEME、
# CONFIGURATION、XCODEBUILD_BIN、XCRUN_BIN、current_developer_dir 以及
# select_target 写入的 SELECTED_*。
#
# 构建证据只表达一个结论：“这组输入已在同一工具链、Simulator、Scheme 和配置上
# 由统一入口编译成功”。它不指向、也不消费 DerivedData 里的 .app；quick 的
# iOS 项本身只编译 App、不安装不运行，所以其他 Worktree 之后覆盖共享产物不会
# 改变这个结论。证据缺失、格式不符或任何输入无法确认时一律重新构建。
#
# 存放：<本次 DerivedData>/MimiBuildEvidence/<Worktree 键>.record 与 .inputs。
# DerivedData 位于仓库外共享缓存并按 UDID 隔离；删除该目录会连同证据一起失效。
# Worktree 键取自当前 Worktree 物理路径的哈希，每个 Worktree 只读写自己的记录，
# 不会把 A Worktree 的结果交给 B。

IOS_BUILD_EVIDENCE_SCHEMA="2"
IOS_BUILD_EVIDENCE_DIR_NAME="MimiBuildEvidence"
IOS_BUILD_EVIDENCE_REASON=""
IOS_BUILD_EVIDENCE_SUMMARY=""
IOS_BUILD_EVIDENCE_ARGS=""
# 参与比较的字段及顺序；任何一项不同都必须重新构建。
IOS_BUILD_EVIDENCE_KEYS="schema worktree project scheme configuration build_settings destination simulator derived_data developer_dir xcode toolchain sdk host_arch go tailcat build_env inputs"
IOS_BUILD_EVIDENCE_GO_BIN="${TAILCAT_MOBILE_GO_BIN:-go}"
IOS_BUILD_EVIDENCE_TAILCAT_MODULE="${TAILCAT_MOBILE_MODULE_DIR:-$ROOT_DIR/experiments/tailcat}"

ios_evidence_hash() {
  shasum -a 256 | awk '{ print $1 }'
}

# 输出一行 “key<TAB>value”。记录按行保存：多行值（如 xcodebuild -version）合并
# 为一行，制表符替换为空格。纯 bash 实现，避免每个字段都启动子进程。
ios_evidence_emit() {
  local value="$2"
  value="${value//$'\r'/}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ / }"
  printf '%s\t%s\n' "$1" "$value"
}

ios_evidence_field() {
  local requested_key="$1" line
  while IFS= read -r line; do
    if [[ "${line%%$'\t'*}" == "$requested_key" && "$line" == *$'\t'* ]]; then
      printf '%s\n' "${line#*$'\t'}"
      return 0
    fi
  done <<< "$2"
  return 0
}

ios_evidence_label() {
  case "$1" in
    schema) printf '证据格式' ;;
    worktree) printf 'Worktree' ;;
    project) printf '工程路径' ;;
    scheme) printf 'Scheme' ;;
    configuration) printf '构建配置' ;;
    build_settings) printf '构建参数' ;;
    destination) printf '目标设备' ;;
    simulator) printf '目标设备名称' ;;
    derived_data) printf 'DerivedData' ;;
    developer_dir) printf 'Xcode 路径' ;;
    xcode) printf 'Xcode 版本' ;;
    toolchain) printf 'Swift 工具链（TOOLCHAINS）' ;;
    sdk) printf 'Simulator SDK' ;;
    host_arch) printf '主机架构' ;;
    go) printf 'Go 工具链' ;;
    tailcat) printf 'Tailcat 框架' ;;
    build_env) printf '构建相关环境变量' ;;
    inputs) printf '源码/资源/工程文件' ;;
    *) printf '%s' "$1" ;;
  esac
}

ios_evidence_worktree_root() {
  (cd "$ROOT_DIR" && pwd -P)
}

ios_evidence_record_base() {
  local worktree_key
  worktree_key="$(ios_evidence_worktree_root | ios_evidence_hash | cut -c 1-16)"
  printf '%s/%s/%s\n' "$SELECTED_DERIVED_DATA" "$IOS_BUILD_EVIDENCE_DIR_NAME" "$worktree_key"
}

ios_evidence_tailcat_fingerprint_file() {
  printf '%s/.tailcat-mobile-fingerprint\n' \
    "${TAILCAT_MOBILE_OUTPUT_DIR:-$ROOT_DIR/ios/MimiRemote/Generated}"
}

# 只有不改变编译结果的测试筛选与报告参数可以留下证据。其他参数（构建设置覆盖、
# -sdk、覆盖率等）都会让本次构建与 quick 的 App 编译不再等价。
ios_evidence_args_are_neutral() {
  local action="$1"
  shift
  local argument pending="" only_count=0 skip_count=0 test_action=0
  IOS_BUILD_EVIDENCE_ARGS=""
  IOS_BUILD_EVIDENCE_REASON=""
  [[ "$action" == "test" || "$action" == "build-for-testing" ]] && test_action=1
  for argument in "$@"; do
    if [[ -n "$pending" ]]; then
      pending=""
      continue
    fi
    [[ "$argument" == "-quiet" ]] && continue
    if [[ "$test_action" == "1" ]]; then
      case "$argument" in
        -only-testing:*) only_count=$((only_count + 1)); continue ;;
        -skip-testing:*) skip_count=$((skip_count + 1)); continue ;;
        -only-testing) only_count=$((only_count + 1)); pending="$argument"; continue ;;
        -skip-testing) skip_count=$((skip_count + 1)); pending="$argument"; continue ;;
        -resultBundlePath|-collect-test-diagnostics|-testLanguage|-testRegion|-test-iterations|-parallel-testing-enabled|-test-timeouts-enabled|-only-test-configuration|-skip-test-configuration|-default-test-execution-time-allowance|-maximum-test-execution-time-allowance|-maximum-concurrent-test-simulator-destinations|-test-repetition-relaunch-enabled)
          pending="$argument"
          continue
          ;;
        -retry-tests-on-failure|-run-tests-until-failure) continue ;;
      esac
    fi
    IOS_BUILD_EVIDENCE_REASON="参数 ${argument} 可能改变构建结果"
    return 1
  done
  if [[ -n "$pending" ]]; then
    IOS_BUILD_EVIDENCE_REASON="参数 ${pending} 缺少取值"
    return 1
  fi
  if [[ "$only_count" -gt 0 ]]; then
    IOS_BUILD_EVIDENCE_ARGS="-only-testing ${only_count} 项"
  elif [[ "$test_action" == "1" ]]; then
    IOS_BUILD_EVIDENCE_ARGS="全部测试"
  fi
  if [[ "$skip_count" -gt 0 ]]; then
    IOS_BUILD_EVIDENCE_ARGS="${IOS_BUILD_EVIDENCE_ARGS:+${IOS_BUILD_EVIDENCE_ARGS}，}-skip-testing ${skip_count} 项"
  fi
  return 0
}

# 输出 “<mode> <git blob> <path>” 清单，按路径排序。纳入：
# - 工程所在目录（SRCROOT，例如 ios/MimiRemote）下所有已跟踪与未忽略的未跟踪文件；
# - 解析到 SRCROOT 之外的工程输入：文件引用按分组层级与 sourceTree 计算，构建设置
#   与脚本中的相对路径以 SRCROOT 为基准；无法唯一确定时不复用（见 external_input_paths）；
# - Tailcat Go module 与统一入口、证据和 Tailcat 构建脚本自身。
# 已跟踪且未改动的文件直接取索引中的 blob；改动、未跟踪或被忽略的工程外引用由
# git hash-object 计算同一种 blob，因此提交前后同一内容得到同一清单。
# 失败时只在标准输出打印原因并以 3 退出。
ios_evidence_input_manifest() {
  ruby - "$ROOT_DIR" "$PROJECT_PATH" \
    experiments/tailcat \
    scripts/ios-dev.sh \
    scripts/ios-build-evidence.sh \
    scripts/build-tailcat-mobile.sh <<'RUBY'
# encoding: utf-8
require "json"
require "open3"
Encoding.default_external = Encoding::UTF_8
STDOUT.set_encoding(Encoding::UTF_8)

def fail_closed(message)
  puts message
  exit 3
end

root = File.realpath(ARGV.fetch(0))
project_argument = ARGV.fetch(1)
fixed_inputs = ARGV.drop(2)

def git(root, *arguments, stdin_data: nil)
  # DEVELOPER_DIR、SDKROOT 与 TOOLCHAINS 只用于选择 Xcode 工具链；指向测试或兼容性
  # 工具链时不能让 macOS 的 git shim 失效。
  environment = { "DEVELOPER_DIR" => nil, "SDKROOT" => nil, "TOOLCHAINS" => nil }
  command = ["git", "-c", "core.quotepath=off", "--literal-pathspecs", "-C", root, *arguments]
  output, error, status = if stdin_data.nil?
    Open3.capture3(environment, *command)
  else
    Open3.capture3(environment, *command, stdin_data: stdin_data)
  end
  fail_closed("git #{arguments.first} 失败：#{error.strip}") unless status.success?
  output
end

# 工程外输入按 Xcode 的实际规则解析：文件引用沿分组层级和 sourceTree 计算，
# 构建设置与脚本里的相对路径以 SRCROOT 为基准。任何一处无法唯一确定（解析器不可用、
# 未知 sourceTree、含变量或通配符、经过符号链接或不存在的目录、指向仓库外）都不复用：
# 宁可重新构建，也不能给错误的文件算指纹。
def external_input_paths(root, source_root, pbxproj, text)
  begin
    json, error, status = Open3.capture3("plutil", "-convert", "json", "-o", "-", pbxproj)
  rescue SystemCallError
    fail_closed("缺少 plutil，无法解析 project.pbxproj")
  end
  fail_closed("无法解析 project.pbxproj：#{error.strip}") unless status.success?
  begin
    data = JSON.parse(json)
  rescue JSON::ParserError
    fail_closed("无法解析 project.pbxproj")
  end
  objects = data["objects"]
  project = objects.is_a?(Hash) ? objects[data["rootObject"]] : nil
  fail_closed("project.pbxproj 缺少 PBXProject") unless project.is_a?(Hash) && project["isa"] == "PBXProject"
  unless project["projectDirPath"].to_s.empty? && project["projectRoot"].to_s.empty?
    fail_closed("工程设置了 projectDirPath 或 projectRoot，无法确认 SRCROOT")
  end
  main_group = project["mainGroup"]
  parents = {}
  built = {}
  objects.each do |id, object|
    next unless object.is_a?(Hash)
    built[object["fileRef"]] = true if object["isa"] == "PBXBuildFile" && object["fileRef"]
    next unless object["children"].is_a?(Array)
    object["children"].each do |child|
      fail_closed("工程分组结构异常：同一引用属于多个分组") if parents.key?(child) && parents[child] != id
      parents[child] = id
    end
  end

  # 返回未规范化的路径（保留 ..，用于对照文件系统解析），:skip 表示不是仓库输入，
  # :orphan 表示不在任何分组中。
  locations = {}
  locate = lambda do |id, depth|
    return locations[id] if locations.key?(id)
    fail_closed("工程分组层级异常") if depth > 64
    object = objects[id]
    fail_closed("工程引用了不存在的对象") unless object.is_a?(Hash)
    path = object["path"].to_s
    fail_closed("工程引用路径含变量，无法确认：#{path}") if path.include?("$")
    base = case object["sourceTree"]
    when "<group>"
      if id == main_group
        source_root
      elsif parents.key?(id)
        locate.call(parents[id], depth + 1)
      else
        :orphan
      end
    when "SOURCE_ROOT" then source_root
    when "<absolute>" then ""
    when "BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR" then :skip
    else
      fail_closed("工程引用使用了无法确认的 sourceTree：#{object["sourceTree"]}（#{path}）")
    end
    location = if base.is_a?(Symbol) || path.empty?
      base
    elsif path.start_with?("/")
      path
    else
      base.empty? ? path : File.join(base, path)
    end
    if object["sourceTree"] == "<absolute>" && !location.to_s.start_with?("/")
      fail_closed("工程引用的绝对路径无效：#{path}")
    end
    locations[id] = location
  end

  candidates = []
  objects.each do |id, object|
    next unless object.is_a?(Hash)
    case object["isa"]
    when "PBXFileReference", "XCVersionGroup"
      location = locate.call(id, 0)
      if location == :orphan
        fail_closed("参与构建的工程引用不在任何分组中：#{object["path"]}") if built[id]
        next
      end
      next if location == :skip
      candidates << [location, object["path"].to_s]
    when "XCLocalSwiftPackageReference"
      relative = object["relativePath"].to_s
      fail_closed("本地 Swift Package 路径无法确认：#{relative}") if relative.empty? || relative.include?("$")
      candidates << [relative.start_with?("/") ? relative : File.join(source_root, relative), relative]
    when "XCBuildConfiguration"
      settings = object["buildSettings"].is_a?(Hash) ? object["buildSettings"].values : []
      settings.flatten.each do |value|
        next unless value.is_a?(String) && (value == ".." || value.start_with?("../"))
        candidates << [File.join(source_root, value), value]
      end
    end
  end
  # 脚本、构建设置与输入输出列表中以 SRCROOT / PROJECT_DIR 为基准的路径。
  text.scan(/\$[({]?(?:SRCROOT|PROJECT_DIR)[)}]?(\/[^"'\s\x5c;,:)}]*)/).flatten.each do |suffix|
    next unless suffix.split("/").include?("..")
    candidates << [source_root + suffix, "$SRCROOT#{suffix}"]
  end

  external = []
  candidates.each do |raw, display|
    if raw.include?("$") || raw =~ /[*?\[]/
      fail_closed("工程引用含变量或通配符，无法确认：#{display}")
    end
    lexical = File.expand_path(raw)
    traverses = raw.split("/").include?("..")
    inside_source = lexical == source_root || lexical.start_with?(source_root + "/")
    next if inside_source && !traverses
    fail_closed("工程引用的外部路径无法解析：#{display}") unless File.exist?(lexical)
    if traverses
      physical = begin
        File.realpath(raw)
      rescue SystemCallError
        fail_closed("工程引用的外部路径经过不存在的目录，无法确认：#{display}")
      end
      unless File.realpath(lexical) == physical
        fail_closed("工程引用的外部路径经过符号链接，无法确认实际文件：#{display}")
      end
    end
    next if inside_source
    unless lexical.start_with?(root + "/") && File.realpath(lexical).start_with?(root + "/")
      fail_closed("工程引用了仓库外的路径：#{display}")
    end
    external << lexical.delete_prefix(root + "/")
  end
  external.uniq
end

project_path = File.expand_path(project_argument, root)
fail_closed("找不到工程：#{project_argument}") unless File.directory?(project_path)
project_path = File.realpath(project_path)
fail_closed("工程不在当前 Worktree 内，无法确认输入") unless project_path.start_with?(root + "/")
source_root = File.dirname(project_path)
source_relative = source_root == root ? "." : source_root.delete_prefix(root + "/")
pbxproj = File.join(project_path, "project.pbxproj")
fail_closed("缺少 project.pbxproj") unless File.file?(pbxproj)

text = File.binread(pbxproj).force_encoding("UTF-8").scrub("?")
external_inputs = external_input_paths(root, source_root, pbxproj, text)

pathspecs = ([source_relative] + fixed_inputs + external_inputs).uniq
index = {}
dirty = {}
git(root, "ls-files", "-s", "-v", "-z", "--", *pathspecs).split("\0").each do |entry|
  metadata, path = entry.split("\t", 2)
  tag, mode, object, stage = metadata.split(" ")
  fail_closed("存在未解决的合并冲突：#{path}") unless stage == "0"
  fail_closed("无法确认子模块输入：#{path}") if mode == "160000"
  index[path] = "#{mode} #{object}"
  # assume-unchanged 与 skip-worktree 会让 git diff 忽略改动，必须按内容重新计算。
  dirty[path] = true if tag =~ /\A[a-z]\z/ || tag == "S"
end
git(root, "diff", "--name-only", "--no-renames", "-z", "--", *pathspecs).split("\0").each do |path|
  dirty[path] = true
end
git(root, "ls-files", "--others", "--exclude-standard", "-z", "--", *pathspecs).split("\0").each do |path|
  dirty[path] = true
end
external_inputs.each do |relative|
  next if File.directory?(File.join(root, relative)) || index.key?(relative)
  dirty[relative] = true
end

entries = {}
index.each { |path, value| entries[path] = value unless dirty[path] }
hash_paths = []
dirty.keys.each do |path|
  fail_closed("路径包含换行，无法记录：#{path.inspect}") if path.include?("\n")
  full_path = File.join(root, path)
  if File.symlink?(full_path)
    object = git(root, "hash-object", "--stdin", stdin_data: File.readlink(full_path)).strip
    entries[path] = "120000 #{object}"
  elsif File.file?(full_path)
    hash_paths << path
  elsif File.exist?(full_path)
    fail_closed("无法确认目录输入：#{path}")
  else
    entries[path] = "deleted -"
  end
end
unless hash_paths.empty?
  objects = git(root, "hash-object", "--stdin-paths", stdin_data: hash_paths.join("\n") + "\n").split("\n")
  fail_closed("git hash-object 输出数量不符") unless objects.length == hash_paths.length
  hash_paths.each_with_index do |path, position|
    mode = File.executable?(File.join(root, path)) ? "100755" : "100644"
    entries[path] = "#{mode} #{objects[position]}"
  end
end
fail_closed("没有找到任何构建输入") if entries.empty?
entries.keys.sort.each { |path| puts "#{entries[path]} #{path}" }
RUBY
}

# 输出构建相关环境变量的摘要，每行 “NAME=<值的 SHA-256 前 16 位>”，按名称排序；
# 一个都没设置时输出 none。run_xcodebuild 不清理环境：xcodebuild、工程里的脚本阶段
# 和其中调用的 build-tailcat-mobile.sh 都继承调用方的全部环境变量。所以纳入：
# - 选择工具链或 SDK 的 TOOLCHAINS、SDKROOT（DEVELOPER_DIR 已按实际 Xcode 路径记录）；
# - 编译器与链接器直接读取、或与同名构建设置对应的 CC、CPATH、LIBRARY_PATH 等；
# - Tailcat 构建脚本读取的 TAILCAT_MOBILE_*（只影响等待时长的 LOCK_WAIT_SECONDS 除外）；
# - 工程文件、xcconfig、Info.plist、entitlements 与 Scheme 里以 $(NAME)、${NAME} 或
#   $NAME 引用的名字：xcodebuild 会把同名环境变量当作最低优先级的构建设置。
# PATH 不纳入：工程脚本会在前面固定追加工具目录，实际用到的 Xcode、Go 和 Tailcat
# 已分别按路径、版本或指纹记录。只存哈希，避免把令牌等敏感值写进缓存。
# XCODE_XCCONFIG_FILE 会以最高优先级覆盖构建设置，内容还可能 include 其他文件，
# 设置时一律不复用：只打印原因并以 3 退出。
ios_evidence_build_environment() {
  ruby - "$ROOT_DIR" "$PROJECT_PATH" <<'RUBY'
# encoding: utf-8
require "digest"
require "open3"
Encoding.default_external = Encoding::UTF_8
STDOUT.set_encoding(Encoding::UTF_8)

def fail_closed(message)
  puts message
  exit 3
end

unless ENV.fetch("XCODE_XCCONFIG_FILE", "").empty?
  fail_closed("环境变量 XCODE_XCCONFIG_FILE 会覆盖工程构建设置，无法确认构建结果")
end
root = File.realpath(ARGV.fetch(0))
project_path = File.expand_path(ARGV.fetch(1), root)
fail_closed("找不到工程：#{ARGV.fetch(1)}") unless File.directory?(project_path)
source_root = File.dirname(File.realpath(project_path))
source_relative = source_root == root ? "." : source_root.delete_prefix(root + "/")

names = %w[
  TOOLCHAINS SDKROOT CC CXX LD LDPLUSPLUS LIBTOOL SWIFT_EXEC
  CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH LIBRARY_PATH
  IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET
]
ENV.each_key do |name|
  names << name if name.start_with?("TAILCAT_MOBILE_") && name != "TAILCAT_MOBILE_LOCK_WAIT_SECONDS"
end
output, error, status = Open3.capture3(
  { "DEVELOPER_DIR" => nil, "SDKROOT" => nil, "TOOLCHAINS" => nil },
  "git", "-c", "core.quotepath=off", "--literal-pathspecs", "-C", root,
  "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", source_relative
)
fail_closed("git ls-files 失败：#{error.strip}") unless status.success?
output.split("\0").uniq.each do |path|
  next unless path =~ /\.(pbxproj|xcconfig|plist|entitlements|xcscheme)\z/
  full_path = File.join(root, path)
  next unless File.file?(full_path)
  File.binread(full_path).force_encoding("UTF-8").scrub("?").scan(/\$[({]?([A-Za-z_][A-Za-z0-9_]*)/) do |match|
    names << match.first
  end
end
entries = (names.uniq - ["PATH"]).sort.select { |name| ENV.key?(name) }.map do |name|
  "#{name}=#{Digest::SHA256.hexdigest(ENV.fetch(name))[0, 16]}"
end
puts(entries.empty? ? "none" : entries)
RUBY
}

# 列出两份环境变量摘要中取值不同的名字，用于说明证据失效原因。
ios_evidence_changed_environment_names() {
  ruby -e '
    parse = lambda do |value|
      value.split(" / ").reject { |entry| entry.empty? || entry == "none" }.map { |entry| entry.split("=", 2) }.to_h
    end
    before = parse.call(ARGV.fetch(0))
    after = parse.call(ARGV.fetch(1))
    print((before.keys | after.keys).select { |name| before[name] != after[name] }.sort.join("、"))
  ' "$1" "$2" 2>/dev/null || true
}

# TOOLCHAINS 指定的工具链按 xcrun 实际解析出的 swiftc 路径和版本记录：同一个标识
# （例如 swift）在安装新工具链后会指向不同版本。未设置时由 Xcode 版本决定。
ios_evidence_toolchain() {
  local swiftc_path swiftc_version
  if [[ -z "${TOOLCHAINS:-}" ]]; then
    printf 'Xcode 默认'
    return 0
  fi
  swiftc_path="$("$XCRUN_BIN" --find swiftc 2>/dev/null)" && [[ -n "$swiftc_path" ]] \
    || { printf '无法解析 TOOLCHAINS=%s 对应的 Swift 工具链' "$TOOLCHAINS"; return 1; }
  swiftc_version="$("$XCRUN_BIN" swiftc -version 2>&1)" \
    || { printf '无法读取 TOOLCHAINS=%s 对应的 Swift 版本' "$TOOLCHAINS"; return 1; }
  printf 'TOOLCHAINS=%s / %s / %s' "$TOOLCHAINS" "$swiftc_path" "$swiftc_version"
}

# 输出参与比较的 “key<TAB>value” 行。失败时只打印原因并返回 1。
ios_evidence_values() {
  local inputs_digest="$1"
  local developer_dir xcode_version sdk_version sdk_build project_relative worktree_root tailcat_value
  local go_version go_environment toolchain_value build_environment
  worktree_root="$(ios_evidence_worktree_root)" || { printf '无法解析 Worktree 路径'; return 1; }
  build_environment="$(ios_evidence_build_environment)" \
    || { printf '%s' "${build_environment:-无法读取构建相关环境变量}"; return 1; }
  toolchain_value="$(ios_evidence_toolchain)" || { printf '%s' "$toolchain_value"; return 1; }
  developer_dir="$(current_developer_dir 2>/dev/null || true)"
  if [[ -n "$developer_dir" && -d "$developer_dir" ]]; then
    developer_dir="$(cd "$developer_dir" && pwd -P)"
  fi
  xcode_version="$("$XCODEBUILD_BIN" -version 2>/dev/null)" \
    || { printf '无法读取 Xcode 版本'; return 1; }
  sdk_version="$("$XCRUN_BIN" --sdk iphonesimulator --show-sdk-version 2>/dev/null)" \
    || { printf '无法读取 Simulator SDK 版本'; return 1; }
  sdk_build="$("$XCRUN_BIN" --sdk iphonesimulator --show-sdk-build-version 2>/dev/null)" \
    || { printf '无法读取 Simulator SDK build'; return 1; }
  # Tailcat XCFramework 由 Go 工具链生成，与 build-tailcat-mobile.sh 的指纹口径一致：
  # 全局 go version 加上 module 目录按 GOTOOLCHAIN 解析出的版本和主机平台。
  go_version="$("$IOS_BUILD_EVIDENCE_GO_BIN" version 2>/dev/null)" \
    || { printf '无法读取 Go 版本'; return 1; }
  go_environment="$(
    cd "$IOS_BUILD_EVIDENCE_TAILCAT_MODULE" 2>/dev/null \
      && GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" "$IOS_BUILD_EVIDENCE_GO_BIN" env GOVERSION GOHOSTOS GOHOSTARCH 2>/dev/null
  )" || { printf '无法读取 Tailcat module 的 Go 工具链'; return 1; }
  project_relative="$PROJECT_PATH"
  [[ "$project_relative" == "$ROOT_DIR/"* ]] && project_relative="${project_relative#"$ROOT_DIR"/}"
  tailcat_value="missing"
  if [[ -f "$(ios_evidence_tailcat_fingerprint_file)" ]]; then
    tailcat_value="$(cat "$(ios_evidence_tailcat_fingerprint_file)")"
  fi

  ios_evidence_emit schema "$IOS_BUILD_EVIDENCE_SCHEMA"
  ios_evidence_emit worktree "$worktree_root"
  ios_evidence_emit project "$project_relative"
  ios_evidence_emit scheme "$SCHEME"
  ios_evidence_emit configuration "$CONFIGURATION"
  ios_evidence_emit build_settings "CODE_SIGNING_ALLOWED=NO"
  ios_evidence_emit destination "$SELECTED_DESTINATION"
  ios_evidence_emit simulator "$SELECTED_NAME"
  ios_evidence_emit derived_data "$SELECTED_DERIVED_DATA"
  ios_evidence_emit developer_dir "${developer_dir:-unknown}"
  ios_evidence_emit xcode "$xcode_version"
  ios_evidence_emit toolchain "$toolchain_value"
  ios_evidence_emit sdk "iphonesimulator $sdk_version ($sdk_build)"
  ios_evidence_emit host_arch "$(uname -m)"
  ios_evidence_emit go "$go_version / $go_environment / GOTOOLCHAIN=${GOTOOLCHAIN:-auto}"
  ios_evidence_emit tailcat "$tailcat_value"
  ios_evidence_emit build_env "$build_environment"
  ios_evidence_emit inputs "$inputs_digest"
}

# 一次计算清单和字段。成功时设置 IOS_BUILD_EVIDENCE_MANIFEST / _VALUES。
ios_evidence_snapshot() {
  local manifest values
  IOS_BUILD_EVIDENCE_MANIFEST=""
  IOS_BUILD_EVIDENCE_VALUES=""
  if ! manifest="$(ios_evidence_input_manifest)"; then
    IOS_BUILD_EVIDENCE_REASON="无法确认构建输入：${manifest:-清单生成失败}"
    return 1
  fi
  if ! values="$(ios_evidence_values "$(printf '%s\n' "$manifest" | ios_evidence_hash)")"; then
    IOS_BUILD_EVIDENCE_REASON="无法确认工具链或构建环境：${values:-读取失败}"
    return 1
  fi
  IOS_BUILD_EVIDENCE_MANIFEST="$manifest"
  IOS_BUILD_EVIDENCE_VALUES="$values"
}

ios_evidence_changed_labels() {
  local before="$1" after="$2" key old_value new_value label labels=""
  for key in $IOS_BUILD_EVIDENCE_KEYS; do
    old_value="$(ios_evidence_field "$key" "$before")"
    new_value="$(ios_evidence_field "$key" "$after")"
    [[ "$old_value" == "$new_value" ]] && continue
    label="$(ios_evidence_label "$key")"
    case "$key" in
      scheme|configuration|simulator|xcode|sdk|host_arch|go)
        label="${label}（${old_value:-无} → ${new_value:-无}）"
        ;;
      build_env)
        label="${label}（$(ios_evidence_changed_environment_names "$old_value" "$new_value")）"
        ;;
    esac
    labels="${labels:+${labels}、}$label"
  done
  printf '%s' "${labels:-证据内容}"
}

ios_evidence_changed_inputs() {
  local stored_manifest_file="$1" current_manifest="$2" changed count
  [[ -f "$stored_manifest_file" ]] || return 0
  changed="$(printf '%s\n' "$current_manifest" | ruby -E UTF-8:UTF-8 -e '
    def load(lines)
      lines.each_with_object({}) do |line, entries|
        mode, object, path = line.chomp.split(" ", 3)
        entries[path] = "#{mode} #{object}" unless path.nil?
      end
    end
    stored = load(File.readlines(ARGV.fetch(0)))
    current = load(STDIN.readlines)
    (stored.keys | current.keys).select { |path| stored[path] != current[path] }.sort.each { |path| puts path }
  ' "$stored_manifest_file")" || return 0
  [[ -n "$changed" ]] || return 0
  count="$(printf '%s\n' "$changed" | awk 'END { print NR }')"
  printf '%s' "$(printf '%s\n' "$changed" | head -n 3 | awk 'NR > 1 { printf "、" } { printf "%s", $0 }')"
  if [[ "$count" -gt 3 ]]; then
    printf ' 等 %s 个文件' "$count"
  fi
}

# 构建成功后调用：重新计算输入，与构建前一致才写入证据。
ios_evidence_commit() {
  local action="$1" before_values="$2"
  local base input_count recorded_at head
  if ! ios_evidence_snapshot; then
    echo "    构建证据：未记录（构建后${IOS_BUILD_EVIDENCE_REASON}）"
    return 0
  fi
  if [[ "$IOS_BUILD_EVIDENCE_VALUES" != "$before_values" ]]; then
    echo "    构建证据：未记录（构建期间$(ios_evidence_changed_labels "$before_values" "$IOS_BUILD_EVIDENCE_VALUES")发生变化）"
    return 0
  fi
  base="$(ios_evidence_record_base)"
  mkdir -p "${base%/*}" || return 1
  printf '%s\n' "$IOS_BUILD_EVIDENCE_MANIFEST" > "$base.inputs.tmp.$$" || return 1
  mv "$base.inputs.tmp.$$" "$base.inputs" || return 1
  input_count="$(printf '%s\n' "$IOS_BUILD_EVIDENCE_MANIFEST" | awk 'END { print NR }')"
  recorded_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  head="$(env -u DEVELOPER_DIR -u SDKROOT -u TOOLCHAINS git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
  {
    ios_evidence_emit meta.action "$action"
    ios_evidence_emit meta.args "$IOS_BUILD_EVIDENCE_ARGS"
    ios_evidence_emit meta.recorded_at "$recorded_at"
    ios_evidence_emit meta.head "$head"
    ios_evidence_emit meta.input_count "$input_count"
    printf '%s\n' "$IOS_BUILD_EVIDENCE_VALUES"
  } > "$base.record.tmp.$$" || return 1
  mv "$base.record.tmp.$$" "$base.record" || return 1
  echo "==> 已记录构建证据：${action}${IOS_BUILD_EVIDENCE_ARGS:+（${IOS_BUILD_EVIDENCE_ARGS}）}，输入指纹 $(ios_evidence_field inputs "$IOS_BUILD_EVIDENCE_VALUES" | cut -c 1-12)（${input_count} 个文件）"
}

# 判断当前 Worktree 能否复用 SELECTED_* 目标上的证据。只读，不占用设备租约。
ios_evidence_check() {
  local base stored current_values stored_values changed changed_files action args recorded_at input_count
  IOS_BUILD_EVIDENCE_REASON=""
  IOS_BUILD_EVIDENCE_SUMMARY=""
  base="$(ios_evidence_record_base)"
  if [[ ! -f "$base.record" ]]; then
    IOS_BUILD_EVIDENCE_REASON="没有本 Worktree 在 ${SELECTED_NAME} 上的成功构建证据（只记录统一入口成功的 Simulator build、build-for-testing 或 test）"
    return 1
  fi
  stored="$(cat "$base.record")"
  stored_values="$(printf '%s\n' "$stored" | grep -v '^meta\.' || true)"
  if [[ "$(ios_evidence_field schema "$stored_values")" != "$IOS_BUILD_EVIDENCE_SCHEMA" ]]; then
    IOS_BUILD_EVIDENCE_REASON="证据格式已变化"
    return 1
  fi
  if ! ios_evidence_snapshot; then
    return 1
  fi
  current_values="$IOS_BUILD_EVIDENCE_VALUES"
  if [[ "$stored_values" != "$current_values" ]]; then
    changed="$(ios_evidence_changed_labels "$stored_values" "$current_values")"
    if [[ "$(ios_evidence_field inputs "$stored_values")" != "$(ios_evidence_field inputs "$current_values")" ]]; then
      changed_files="$(ios_evidence_changed_inputs "$base.inputs" "$IOS_BUILD_EVIDENCE_MANIFEST")"
      [[ -z "$changed_files" ]] || changed="${changed}：${changed_files}"
    fi
    IOS_BUILD_EVIDENCE_REASON="自上次成功构建后已变化：${changed}"
    return 1
  fi
  action="$(ios_evidence_field meta.action "$stored")"
  args="$(ios_evidence_field meta.args "$stored")"
  recorded_at="$(ios_evidence_field meta.recorded_at "$stored")"
  input_count="$(ios_evidence_field meta.input_count "$stored")"
  IOS_BUILD_EVIDENCE_SUMMARY="本 Worktree 的 ${action:-unknown}${args:+（${args}）}于 ${recorded_at:-unknown} 在 ${SELECTED_NAME} 成功；输入指纹 $(ios_evidence_field inputs "$current_values" | cut -c 1-12)（${input_count:-?} 个文件）、Xcode/SDK、Swift 工具链、Go 工具链、构建相关环境变量、目标、Scheme/配置与 Tailcat 框架指纹均一致"
  return 0
}
