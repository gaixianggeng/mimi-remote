#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/verify-change.sh [--plan] [--full] [--base <ref>]
  bash ./scripts/verify-change.sh --plan --paths-file <NUL-separated-paths>

默认执行 quick 验证：分析 origin/main...HEAD、暂存区、工作区和未跟踪文件，
只运行受影响栈的最小检查。--plan 只打印计划；--full 升级为受影响栈的完整本地回归。
EOF
}

fail() {
  echo "分层验证失败：$1" >&2
  exit 1
}

mode="quick"
plan_only=0
base_ref="origin/main"
paths_file=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --plan)
      plan_only=1
      shift
      ;;
    --full)
      mode="full"
      shift
      ;;
    --base)
      [[ "$#" -ge 2 ]] || fail "--base 缺少 ref。"
      base_ref="$2"
      shift 2
      ;;
    --paths-file)
      [[ "$#" -ge 2 ]] || fail "--paths-file 缺少路径文件。"
      paths_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数 $1。"
      ;;
  esac
done

for command_name in awk bash git mktemp; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

if [[ -n "$paths_file" ]]; then
  [[ -f "$paths_file" ]] || fail "路径文件不存在：$paths_file"
else
  git cat-file -e "${base_ref}^{commit}" 2>/dev/null \
    || fail "base ref 不存在：${base_ref}。请先 git fetch origin main，或显式传 --base。"
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-verify-change.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
resolved_paths_file="$temporary_root/changed-paths"
: > "$resolved_paths_file"

changed_paths=()
committed_count=0
staged_count=0
unstaged_count=0
untracked_count=0

add_changed_path() {
  local path="$1"
  local existing
  [[ -n "$path" ]] || return 0
  for existing in "${changed_paths[@]:-}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  changed_paths+=("$path")
}

collect_paths() {
  local source="$1"
  local path
  while IFS= read -r -d '' path; do
    case "$source" in
      committed) committed_count=$((committed_count + 1)) ;;
      staged) staged_count=$((staged_count + 1)) ;;
      unstaged) unstaged_count=$((unstaged_count + 1)) ;;
      untracked) untracked_count=$((untracked_count + 1)) ;;
    esac
    add_changed_path "$path"
  done
}

collect_command_paths() {
  local source="$1"
  local output_file="$2"
  shift 2

  # 先把 Git 输出落到临时文件，再交给循环读取；process substitution 会吞掉
  # 生产者的退出码，浅克隆或无 merge-base 时可能因此误报“没有变更”。
  if ! "$@" > "$output_file"; then
    fail "无法收集 ${source} 变更路径。"
  fi
  collect_paths "$source" < "$output_file"
}

if [[ -n "$paths_file" ]]; then
  collect_paths synthetic < "$paths_file"
else
  collect_command_paths committed "$temporary_root/committed-paths" \
    git diff --name-only -z --no-renames "${base_ref}...HEAD"
  collect_command_paths staged "$temporary_root/staged-paths" \
    git diff --name-only -z --no-renames --cached
  collect_command_paths unstaged "$temporary_root/unstaged-paths" \
    git diff --name-only -z --no-renames
  collect_command_paths untracked "$temporary_root/untracked-paths" \
    git ls-files --others --exclude-standard -z
fi

for path in "${changed_paths[@]:-}"; do
  [[ -n "$path" ]] || continue
  printf '%s\0' "$path" >> "$resolved_paths_file"
done

scope_output="$(bash ./scripts/ci-pr-scope.sh --paths-file "$resolved_paths_file")"
go_scope="$(printf '%s\n' "$scope_output" | awk -F= '$1 == "go" { print $2 }')"
ios_scope="$(printf '%s\n' "$scope_output" | awk -F= '$1 == "ios" { print $2 }')"
rust_scope="$(printf '%s\n' "$scope_output" | awk -F= '$1 == "rust" { print $2 }')"
macos_scope="$(printf '%s\n' "$scope_output" | awk -F= '$1 == "macos" { print $2 }')"
docs_scope="$(printf '%s\n' "$scope_output" | awk -F= '$1 == "docs" { print $2 }')"

is_documentation_path() {
  case "$1" in
    *.md|README|README.*|CONTRIBUTING.*|AGENTS.md|SECURITY.md|LICENSE|LICENSE.*|*/LICENSE|*/LICENSE.*|docs/*|web/*|artifacts/*)
      return 0
      ;;
  esac
  return 1
}

is_control_path() {
  case "$1" in
    .github/*|scripts/*|packaging/*|config/*|.goreleaser.yml|.gitignore|.editorconfig|.xcodebuildmcp/*)
      return 0
      ;;
  esac
  return 1
}

is_go_source_path() {
  case "$1" in
    experiments/tailcat/*)
      return 1
      ;;
  esac
  case "$1" in
    *.go|go.mod|go.sum|cmd/*|internal/*|contracts/mimi-protocol/*)
      return 0
      ;;
  esac
  return 1
}

is_ios_source_path() {
  case "$1" in
    ios/MimiRemote/*|experiments/tailcat/*|contracts/mimi-protocol/*|internal/protocolcontract/*)
      return 0
      ;;
  esac
  return 1
}

is_rust_source_path() {
  case "$1" in
    Cargo.toml|Cargo.lock|bridges/claude/*)
      return 0
      ;;
  esac
  return 1
}

is_macos_source_path() {
  case "$1" in
    macos/MimiRemoteMac/*)
      return 0
      ;;
  esac
  return 1
}

all_docs=true
direct_go=false
direct_ios=false
direct_rust=false
direct_macos=false
has_control=false
has_contract=false
has_release_control=false
has_gate_control=false
has_codex_control=false
has_verify_control=false
has_packaging_control=false
has_source_size_control=false
has_repository_security_control=false
has_ios_privacy_control=false
has_ios_device_control=false
has_tailcat_source=false
has_ios_asc_control=false
has_critical_mapping_control=false
has_linear_polling_control=false
has_agentd_restart_control=false
has_development_cache_control=false
unknown_paths=()
shell_paths=()
yaml_paths=()
ruby_paths=()
python_paths=()
powershell_paths=()
go_packages=()
go_requires_full=false
rust_all=false
rust_codex=false
rust_core=false
rust_claude=false

add_unique_value() {
  local value="$1"
  shift
  local existing
  for existing in "$@"; do
    [[ "$existing" == "$value" ]] && return 1
  done
  return 0
}

add_go_package_for_path() {
  local source_path="$1"
  local candidate="."
  local go_file
  local package_path

  [[ "$source_path" == */* ]] && candidate="${source_path%/*}"
  while true; do
    for go_file in "$candidate"/*.go; do
      if [[ -f "$go_file" ]]; then
        package_path="."
        [[ "$candidate" != "." ]] && package_path="./${candidate}"
        if add_unique_value "$package_path" "${go_packages[@]:-}"; then
          go_packages+=("$package_path")
        fi
        return 0
      fi
    done

    [[ "$candidate" == "." ]] && break
    if [[ "$candidate" == */* ]]; then
      candidate="${candidate%/*}"
    else
      candidate="."
    fi
  done

  # 删除整个 package、go.mod/go.sum 或无法归属 package 时，用完整 Go 回归兜底。
  go_requires_full=true
}

classify_rust_path() {
  case "$1" in
    Cargo.toml|Cargo.lock)
      rust_all=true
      ;;
    bridges/claude/crates/codex-proto/*)
      rust_codex=true
      rust_core=true
      rust_claude=true
      ;;
    bridges/claude/crates/bridge-core/*)
      rust_core=true
      rust_claude=true
      ;;
    bridges/claude/crates/claude-bridge/*)
      rust_claude=true
      ;;
    *)
      rust_all=true
      ;;
  esac
}

for path in "${changed_paths[@]:-}"; do
  [[ -n "$path" ]] || continue

  path_is_documentation=false
  path_is_go=false
  path_is_ios=false
  path_is_rust=false
  path_is_macos=false

  if is_documentation_path "$path"; then
    path_is_documentation=true
  else
    all_docs=false
    if is_go_source_path "$path"; then
      path_is_go=true
      direct_go=true
      case "$path" in
        contracts/mimi-protocol/*)
          # 共享 fixture 由专用契约检查覆盖；quick 不再重复一次全仓 Go test。
          ;;
        *)
          add_go_package_for_path "$path"
          ;;
      esac
    fi
    if is_ios_source_path "$path"; then
      path_is_ios=true
      direct_ios=true
    fi
    if is_rust_source_path "$path"; then
      path_is_rust=true
      direct_rust=true
      classify_rust_path "$path"
    fi
    if is_macos_source_path "$path"; then
      path_is_macos=true
      direct_macos=true
    fi
  fi
  if is_control_path "$path"; then
    has_control=true
  fi

  case "$path" in
    experiments/tailcat/*)
      has_tailcat_source=true
      ;;
  esac
  case "$path" in
    contracts/mimi-protocol/*|internal/protocolcontract/*)
      has_contract=true
      ;;
  esac
  case "$path" in
    .github/workflows/release.yml|.github/workflows/nightly.yml|scripts/check-nightly-release.sh|scripts/generate-nightly-what-to-test.rb|scripts/check-release-source.sh|scripts/verify-release.sh|scripts/ios_testflight_*|config/release/*|docs/nightly-release.md)
      has_release_control=true
      ;;
  esac
  case "$path" in
    .github/workflows/*|.github/actions/*|scripts/ci-pr-scope.sh|scripts/check-pr-gate.sh)
      has_gate_control=true
      ;;
  esac
  case "$path" in
    .github/workflows/codex-protocol.yml|scripts/check-codex-protocol.sh|docs/codex-protocol-support.md)
      has_codex_control=true
      ;;
  esac
  case "$path" in
    scripts/verify-change.sh|scripts/test-verify-change.sh|CONTRIBUTING.md|README.md|README.zh-CN.md)
      has_verify_control=true
      ;;
  esac
  case "$path" in
    packaging/*|.goreleaser.yml|scripts/check-packaging.sh|scripts/verify-release.sh|scripts/build-*-installer.*|scripts/check-*-installer.*)
      has_packaging_control=true
      ;;
  esac
  case "$path" in
    scripts/check-source-size.sh)
      has_source_size_control=true
      ;;
  esac
  case "$path" in
    .github/workflows/public-repo-safety.yml|scripts/check-public-repo-safety.sh|scripts/test-public-repo-safety.sh|scripts/check-third-party-notices.sh|NOTICE.md|THIRD_PARTY_NOTICES.md)
      has_repository_security_control=true
      ;;
  esac
  case "$path" in
    scripts/check-ios-network-security.sh|scripts/check-ios-privacy-manifest.sh|*/PrivacyInfo.xcprivacy)
      has_ios_privacy_control=true
      ;;
  esac
  case "$path" in
    scripts/ios-dev.sh|scripts/build-tailcat-mobile.sh|scripts/ios-device-lease.sh|scripts/ios-device-gui-handoff-macos.sh|scripts/test-ios-device-management.sh|scripts/test-tailcat-mobile-build.sh|scripts/test-ios-device-gui-handoff-macos.sh|scripts/testdata/ios-device-management/*|scripts/testdata/tailcat-mobile/*)
      has_ios_device_control=true
      ;;
  esac
  case "$path" in
    scripts/ios_asc_*|scripts/test-ios-asc-cli.sh|scripts/distribute_internal_build.rb|config/release/ios-asc-cli.env)
      has_ios_asc_control=true
      ;;
  esac
  case "$path" in
    scripts/check-critical-regressions.sh|scripts/test-conversation-regressions.sh)
      has_critical_mapping_control=true
      ;;
  esac
  case "$path" in
    scripts/check-linear-polling-safety.sh|scripts/install-linear-poll-guard.sh|config/automations/*)
      has_linear_polling_control=true
      ;;
  esac
  case "$path" in
    scripts/restart-agentd-dev-macos.sh|scripts/restart-agentd-dev-handoff-macos.sh|scripts/sign-agentd-dev-macos.sh)
      has_agentd_restart_control=true
      ;;
  esac
  case "$path" in
    scripts/development-cache-path.sh|scripts/development-cache-lock.sh|scripts/test-development-cache.sh|scripts/ios-dev.sh|scripts/build-tailcat-mobile.sh|scripts/test-macos-app.sh|macos/MimiRemoteMac/Scripts/build-local.sh|macos/MimiRemoteMac/Scripts/install-local.sh)
      has_development_cache_control=true
      ;;
  esac

  case "$path" in
    *.sh|scripts/git-testflight-push)
      [[ -f "$path" ]] && shell_paths+=("$path")
      ;;
    *.rb)
      [[ -f "$path" ]] && ruby_paths+=("$path")
      ;;
    *.py)
      [[ -f "$path" ]] && python_paths+=("$path")
      ;;
    *.ps1)
      [[ -f "$path" ]] && powershell_paths+=("$path")
      ;;
    *.yml|*.yaml)
      [[ -f "$path" ]] && yaml_paths+=("$path")
      ;;
  esac

  if [[ "$path_is_documentation" == false ]] && \
     ! is_control_path "$path" && \
     [[ "$path_is_go" == false ]] && \
     [[ "$path_is_ios" == false ]] && \
     [[ "$path_is_rust" == false ]] && \
     [[ "$path_is_macos" == false ]]; then
    unknown_paths+=("$path")
  fi
done

checks=()
check_reasons=()

add_check() {
  local reason="$1"
  local command="$2"
  local existing
  for existing in "${checks[@]:-}"; do
    [[ "$existing" == "$command" ]] && return 0
  done
  check_reasons+=("$reason")
  checks+=("$command")
}

shell_quote() {
  local quoted
  printf -v quoted '%q' "$1"
  printf '%s' "$quoted"
}

if [[ -z "$paths_file" ]]; then
  add_check "已提交差异的空白/冲突标记" "git diff --check $(shell_quote "$base_ref")...HEAD"
  add_check "暂存区差异的空白/冲突标记" "git diff --cached --check"
  add_check "工作区差异的空白/冲突标记" "git diff --check"
fi

if [[ "${#shell_paths[@]}" -gt 0 ]]; then
  shell_command=""
  for path in "${shell_paths[@]}"; do
    [[ -z "$shell_command" ]] || shell_command+=" && "
    shell_command+="bash -n -- $(shell_quote "$path")"
  done
  add_check "变更的 Shell 脚本先做语法检查" "$shell_command"
fi

if [[ "${#yaml_paths[@]}" -gt 0 ]]; then
  command -v ruby >/dev/null 2>&1 || fail "YAML 语法检查需要 ruby。"
  yaml_command="ruby -e 'require \"yaml\"; ARGV.each { |path| YAML.parse_file(path) }' --"
  for path in "${yaml_paths[@]}"; do
    yaml_command+=" $(shell_quote "$path")"
  done
  add_check "变更的 YAML 文件先做语法解析" "$yaml_command"
fi

if [[ "${#ruby_paths[@]}" -gt 0 ]]; then
  command -v ruby >/dev/null 2>&1 || fail "Ruby 语法检查需要 ruby。"
  ruby_command=""
  for path in "${ruby_paths[@]}"; do
    [[ -z "$ruby_command" ]] || ruby_command+=" && "
    ruby_command+="ruby -c -- $(shell_quote "$path")"
  done
  add_check "变更的 Ruby 脚本先做语法检查" "$ruby_command"
fi

if [[ "${#python_paths[@]}" -gt 0 ]]; then
  command -v python3 >/dev/null 2>&1 || fail "Python 语法检查需要 python3。"
  python_command="python3 -c 'import ast, pathlib, sys; [ast.parse(pathlib.Path(path).read_text(), filename=path) for path in sys.argv[1:]]'"
  for path in "${python_paths[@]}"; do
    python_command+=" $(shell_quote "$path")"
  done
  add_check "变更的 Python 脚本先做无产物语法检查" "$python_command"
fi

if [[ "$docs_scope" == true ]]; then
  add_check "文档与公开发布说明使用轻量静态门禁" "bash ./scripts/check-docs-static.sh"
fi

if [[ "$has_gate_control" == true && "$has_repository_security_control" == false ]]; then
  add_check "CI 编排或路径分类变化必须通过 Gate 自检" "bash ./scripts/check-pr-gate.sh"
fi
if [[ "$has_verify_control" == true && "$has_gate_control" == false && "$has_repository_security_control" == false ]]; then
  # check-pr-gate.sh 已包含这项自测；同一轮不要嵌套执行两次。
  add_check "分层验证入口或说明变化必须通过无设备自测" "bash ./scripts/test-verify-change.sh"
fi
if [[ "$has_release_control" == true ]]; then
  if [[ "$has_gate_control" == false && "$has_repository_security_control" == false ]]; then
    add_check "Release/Nightly 控制面先做信任门静态检查" "bash ./scripts/check-nightly-release.sh --check"
  fi
  add_check "Release/Nightly 信任门必须保持 fail-closed" "bash ./scripts/check-nightly-release.sh --self-test"
fi
if [[ "$has_codex_control" == true ]]; then
  add_check "Codex 协议快照相关变化" "bash ./scripts/check-codex-protocol.sh"
fi
if [[ "$has_packaging_control" == true ]]; then
  add_check "打包与 Release 来源策略变化" "bash ./scripts/check-packaging.sh"
fi
if [[ "$has_repository_security_control" == true ]]; then
  add_check "公开仓库安全门自身变化必须执行完整安全检查" "bash ./scripts/check-public-repo-safety.sh"
fi
if [[ "$has_ios_privacy_control" == true ]]; then
  add_check "iOS 网络与隐私边界变化必须执行专项静态检查" "bash ./scripts/check-ios-network-security.sh && bash ./scripts/check-ios-privacy-manifest.sh"
fi
if [[ "$has_ios_device_control" == true ]]; then
  add_check "iOS 目标、Tailcat 构建、租约和真机 GUI 交接变化使用专项自测" "bash ./scripts/test-tailcat-mobile-build.sh && bash ./scripts/test-ios-device-management.sh && bash ./scripts/test-ios-device-gui-handoff-macos.sh"
fi
if [[ "$has_ios_asc_control" == true ]]; then
  add_check "App Store Connect CLI 封装变化使用本地 fake ASC 自测" "bash ./scripts/test-ios-asc-cli.sh"
fi
if [[ "$has_critical_mapping_control" == true && "$has_gate_control" == false && "$has_repository_security_control" == false ]]; then
  add_check "关键用户链路 selector 变化执行静态映射自检" "bash ./scripts/check-critical-regressions.sh"
fi
if [[ "$has_linear_polling_control" == true ]]; then
  add_check "Linear 自动化变化保持本地 guard 和单轮调用约束" "bash ./scripts/check-linear-polling-safety.sh"
fi
if [[ "$has_agentd_restart_control" == true ]]; then
  add_check "agentd 本地重启链路只执行无安装副作用的 self-test" "bash ./scripts/restart-agentd-dev-macos.sh --self-test"
fi
if [[ "$has_development_cache_control" == true ]]; then
  add_check "本地重型构建必须复用仓库外缓存并串行写入" "bash ./scripts/test-development-cache.sh"
fi
if [[ "$has_contract" == true ]]; then
  add_check "Go/iOS 共享契约变化" "bash ./scripts/check-mimi-protocol-contract.sh"
fi
if [[ "$direct_go" == true || "$direct_ios" == true || "$has_source_size_control" == true ]]; then
  # 先用秒级门禁拦住超大源文件，避免等到 Xcode/Go 构建后才失败。
  add_check "Go/iOS 源码体积快速门禁" "bash ./scripts/check-source-size.sh"
fi

if [[ "$direct_go" == true ]]; then
  if [[ "$mode" == "full" || "$go_requires_full" == true || "${#go_packages[@]}" -gt 8 ]]; then
    add_check "Go 受影响范围使用完整回归" "go test ./... -count=1"
  elif [[ "${#go_packages[@]}" -gt 0 ]]; then
    go_test_command="go test"
    for package_path in "${go_packages[@]}"; do
      go_test_command+=" $(shell_quote "$package_path")"
    done
    go_test_command+=" -count=1"
    add_check "Go quick 只测试直接变更的 package" "$go_test_command"
  elif [[ "$has_contract" == false ]]; then
    add_check "Go 受影响范围无法定位 package，使用完整回归" "go test ./... -count=1"
  fi
  if [[ "$mode" == "full" ]]; then
    add_check "Go full 补充静态分析" "go vet ./..."
  fi
fi

if [[ "$has_tailcat_source" == true ]]; then
  add_check "Tailcat 独立 Go module 变化使用自身测试" "(cd experiments/tailcat && go test ./... -count=1)"
fi

if [[ "$direct_ios" == true ]]; then
  if [[ "$mode" == "full" ]]; then
    # Go 变更由上方独立 Go 计划覆盖；iOS 阶段不在 macOS/Simulator 链路重复执行。
    add_check "iOS full 单次执行核心链路与双语资源回归" "bash ./scripts/test-conversation-regressions.sh --ios-only"
  else
    # quick 只证明生产 App 能在固定 M5 Simulator 上编译。整个 XCTest 测试包会随
    # 项目增长而持续变慢；问题相关 selector 应在开发阶段单独执行，完整集合交给 full/CI。
    add_check "iOS quick 只编译 App，不编译或运行 XCTest" \
      "IOS_TARGET_MODE=simulator IOS_SIMULATOR_ID= IOS_SIMULATOR_NAME='iPad Pro 13-inch (M5)' bash ./scripts/ios-dev.sh build"
  fi
fi

if [[ "$direct_rust" == true ]]; then
  add_check "Rust 格式检查" "cargo fmt --all -- --check"
  rust_test_command='CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(bash ./scripts/development-cache-path.sh cargo/target)}" cargo test --locked'
  if [[ "$rust_all" == true || "$mode" == "full" ]]; then
    rust_codex=true
    rust_core=true
    rust_claude=true
  fi
  [[ "$rust_codex" == true ]] && rust_test_command+=" -p alleycat-codex-proto"
  [[ "$rust_core" == true ]] && rust_test_command+=" -p alleycat-bridge-core"
  [[ "$rust_claude" == true ]] && rust_test_command+=" -p alleycat-claude-bridge"
  add_check "Rust 只回归变更 crate 及其下游 crate" "$rust_test_command"
fi

if [[ "$direct_macos" == true ]]; then
  add_check "Mac App 变更执行统一无签名编译测试" "bash ./scripts/test-macos-app.sh"
fi

if [[ "$mode" == "full" ]]; then
  # public-repo-safety 末尾已经调用 check-pr-gate；full 不再提前重复执行一次。
  add_check "full 模式补齐公开仓库安全检查（包含 PR Gate 自检）" "bash ./scripts/check-public-repo-safety.sh"
  add_check "full 模式补齐 Codex 协议检查" "bash ./scripts/check-codex-protocol.sh"
fi

plan_suffix=""
[[ "$plan_only" -eq 1 ]] && plan_suffix="（仅计划）"
echo "Mimi 分层验证计划"
echo "- 模式：${mode}${plan_suffix}"
if [[ -n "$paths_file" ]]; then
  echo "- 变更来源：显式 paths file"
else
  echo "- Base：${base_ref}"
  echo "- 来源计数：committed=${committed_count}, staged=${staged_count}, unstaged=${unstaged_count}, untracked=${untracked_count}"
fi
echo "- 去重后路径：${#changed_paths[@]}"
echo "- PR Gate scope：go=${go_scope}, ios=${ios_scope}, rust=${rust_scope}, macos=${macos_scope}, docs=${docs_scope}"
echo

echo "验证阶段："
if [[ "$mode" == "full" ]]; then
  echo "- 当前：full；交付报告必须说明命中的高风险条件。"
else
  echo "- 当前：quick；只在最后一次代码修改后执行一次，不要在每个微调后重复执行。"
fi
echo "- 开发中：只运行问题直接相关的 package、XCTest selector、快照或静态检查。"
echo "- full 条件：共享协议/跨栈接口，高风险状态语义，影响范围无法界定的大重构，正式发布或用户明确要求。"
echo "- 非 full 条件：普通 UI、文案、单 package、测试文件、改动文件较多、准备提交或“为了保险”。"
if [[ "$has_contract" == true ]]; then
  echo "- 自动高风险信号：检测到 Go/iOS 共享协议路径；建议显式评估 full。"
elif [[ "$direct_go" == true && "$direct_ios" == true ]] || \
     [[ "$direct_go" == true && "$direct_rust" == true ]] || \
     [[ "$direct_go" == true && "$direct_macos" == true ]] || \
     [[ "$direct_ios" == true && "$direct_rust" == true ]] || \
     [[ "$direct_ios" == true && "$direct_macos" == true ]] || \
     [[ "$direct_rust" == true && "$direct_macos" == true ]]; then
  echo "- 自动高风险信号：检测到多个产品栈；建议确认是否修改同一跨栈接口。"
else
  echo "- 自动高风险信号：未检测到；除非存在脚本无法识别的高风险语义，否则保持 quick。"
fi
echo

if [[ "${#changed_paths[@]}" -eq 0 ]]; then
  echo "没有发现需要验证的变更。"
  exit 0
fi

echo "变更路径："
for path in "${changed_paths[@]}"; do
  echo "- ${path}"
done
echo

if [[ "$all_docs" == true ]]; then
  echo "判定：纯文档/静态内容；不启动 Go、Cargo、Xcode 或真机。"
elif [[ "$has_control" == true && "$direct_go" == false && "$direct_ios" == false && "$direct_rust" == false && "$direct_macos" == false ]]; then
  echo "判定：CI/脚本/发布控制面；只运行语法与映射自检，不启动语言构建。"
else
  echo "判定：包含产品源码；只验证直接受影响的语言栈。"
fi

echo "跳过的语言栈："
[[ "$direct_go" == false ]] && echo "- Go：没有直接 Go 产品路径。"
[[ "$direct_ios" == false ]] && echo "- iOS：没有直接 iOS 产品路径，不启动 Xcode/Simulator/真机。"
[[ "$direct_rust" == false ]] && echo "- Rust：没有直接 bridge 产品路径。"
[[ "$direct_macos" == false ]] && echo "- Mac App：没有直接 Mac App 产品路径。"
if [[ "$direct_go" == true && "$direct_ios" == true && "$direct_rust" == true && "$direct_macos" == true ]]; then
  echo "- 无：四个产品栈均受影响。"
fi

if [[ "$direct_ios" == true ]]; then
  echo "真机：默认延后。相机、通知、Keychain、Tailscale/弱网、性能和发布前专项仍必须单独真机验收。"
fi
if [[ "${#powershell_paths[@]}" -gt 0 ]]; then
  echo "Windows：PowerShell 脚本的执行与平台语义延后到 Windows CI；本地不启动额外虚拟机。"
fi
if [[ "$mode" == "quick" ]]; then
  echo "完整回归：默认延后到 --full 或 PR Gate；不要在每个微调后重复执行。"
fi
if [[ "${#unknown_paths[@]}" -gt 0 ]]; then
  echo "人工确认：以下路径没有验证映射，quick 不会把它们静默视为通过："
  for path in "${unknown_paths[@]}"; do
    echo "- ${path}"
  done
fi
echo

echo "将执行 ${#checks[@]} 项："
for index in "${!checks[@]}"; do
  echo "$((index + 1)). ${check_reasons[$index]}"
  echo "   ${checks[$index]}"
done

if [[ "$plan_only" -eq 1 ]]; then
  exit 0
fi

if [[ "${#unknown_paths[@]}" -gt 0 ]]; then
  fail "存在未映射路径；请先人工确认风险并补充映射，不要用 quick 静默跳过。"
fi

overall_started="$SECONDS"
for index in "${!checks[@]}"; do
  started="$SECONDS"
  echo
  echo "==> [$((index + 1))/${#checks[@]}] ${check_reasons[$index]}"
  echo "    ${checks[$index]}"
  bash -c "${checks[$index]}"
  echo "<== 通过，用时 $((SECONDS - started))s"
done

echo
echo "分层验证通过：${#checks[@]} 项，总用时 $((SECONDS - overall_started))s。"
