#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/ci-pr-scope.sh --base <sha> --head <sha> [--github-output <path>] [--summary <path>]
  bash ./scripts/ci-pr-scope.sh --paths-file <NUL-separated-paths> [--github-output <path>] [--summary <path>]
  bash ./scripts/ci-pr-scope.sh --all [--github-output <path>] [--summary <path>]
EOF
}

fail() {
  echo "PR Gate 路径分类失败：$1" >&2
  exit 1
}

base_sha=""
head_sha=""
paths_file=""
github_output=""
summary_file=""
run_all=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base)
      [[ "$#" -ge 2 ]] || fail "--base 缺少 SHA。"
      base_sha="$2"
      shift 2
      ;;
    --head)
      [[ "$#" -ge 2 ]] || fail "--head 缺少 SHA。"
      head_sha="$2"
      shift 2
      ;;
    --paths-file)
      [[ "$#" -ge 2 ]] || fail "--paths-file 缺少路径。"
      paths_file="$2"
      shift 2
      ;;
    --github-output)
      [[ "$#" -ge 2 ]] || fail "--github-output 缺少路径。"
      github_output="$2"
      shift 2
      ;;
    --summary)
      [[ "$#" -ge 2 ]] || fail "--summary 缺少路径。"
      summary_file="$2"
      shift 2
      ;;
    --all)
      run_all=1
      shift
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

mode_count=0
[[ "$run_all" -eq 1 ]] && mode_count=$((mode_count + 1))
[[ -n "$paths_file" ]] && mode_count=$((mode_count + 1))
if [[ -n "$base_sha" || -n "$head_sha" ]]; then
  [[ -n "$base_sha" && -n "$head_sha" ]] || fail "--base 与 --head 必须同时提供。"
  mode_count=$((mode_count + 1))
fi
[[ "$mode_count" -eq 1 ]] || fail "必须且只能选择 --all、--paths-file 或 --base/--head。"

temporary_paths=""
if [[ "$run_all" -eq 1 ]]; then
  go_scope=true
  ios_scope=true
  rust_scope=true
  macos_scope=true
  docs_scope=true
  path_count="all"
else
  if [[ -n "$paths_file" ]]; then
    [[ -f "$paths_file" ]] || fail "路径文件不存在：$paths_file"
    resolved_paths_file="$paths_file"
  else
    git cat-file -e "${base_sha}^{commit}" 2>/dev/null \
      || fail "base commit 不存在：$base_sha"
    git cat-file -e "${head_sha}^{commit}" 2>/dev/null \
      || fail "head commit 不存在：$head_sha"
    temporary_paths="$(mktemp "${TMPDIR:-/tmp}/mimi-pr-gate-paths.XXXXXX")"
    trap 'rm -f "$temporary_paths"' EXIT
    # 禁用 rename detection，让跨目录移动同时按旧路径删除和新路径新增分类。
    git diff --name-only -z --no-renames "${base_sha}...${head_sha}" > "$temporary_paths"
    resolved_paths_file="$temporary_paths"
  fi

  go_scope=false
  ios_scope=false
  rust_scope=false
  macos_scope=false
  docs_scope=false
  path_count=0

  while IFS= read -r -d '' changed_path; do
    [[ -n "$changed_path" ]] || continue
    path_count=$((path_count + 1))

    # CI 编排或分类规则本身变化时执行全部语言门禁，避免分类器修改静默缩小覆盖面。
    case "$changed_path" in
      .github/workflows/*|.github/actions/*|scripts/ci-pr-scope.sh|scripts/check-pr-gate.sh)
        go_scope=true
        ios_scope=true
        rust_scope=true
        macos_scope=true
        docs_scope=true
        continue
        ;;
    esac

    # 公开说明和 App Store 文案只需要轻量静态门禁；产品源码、契约与发布
    # 脚本继续由下方语言 scope 覆盖，不能借文档路径绕过完整回归。
    case "$changed_path" in
      README.md|README.zh-CN.md|CONTRIBUTING.md|docs/*|docs/**/*|scripts/check-docs-static.sh)
        docs_scope=true
        continue
        ;;
    esac

    case "$changed_path" in
      *.go|go.mod|go.sum|.goreleaser.yml|SKILL.md|packaging/*|packaging/**/*|contracts/mimi-protocol/*|contracts/mimi-protocol/**/*)
        go_scope=true
        ;;
      scripts/test-conversation-regressions.sh|scripts/check-critical-regressions.sh|scripts/check-nightly-release.sh|scripts/generate-nightly-what-to-test.rb|scripts/check-packaging.sh|scripts/check-source-size.sh|scripts/check-mimi-protocol-contract.sh|scripts/check-macos-*|scripts/check-release-*|scripts/build-macos-installer.sh|scripts/build-windows-installer.ps1|scripts/check-windows-installer.ps1|scripts/test-windows-install.ps1|scripts/install-linux.sh|scripts/test-install-linux.sh|scripts/package-skill.sh|scripts/sign-agentd-dev-macos.sh|scripts/restart-agentd-dev-macos.sh|scripts/restart-agentd-dev-handoff-macos.sh|scripts/verify-release.sh)
        go_scope=true
        ;;
    esac

    case "$changed_path" in
      ios/MimiRemote/*|ios/MimiRemote/**/*|.xcodebuildmcp/*|.xcodebuildmcp/**/*|contracts/mimi-protocol/*|contracts/mimi-protocol/**/*|internal/protocolcontract/*|internal/protocolcontract/**/*)
        ios_scope=true
        ;;
      scripts/ios-dev.sh|scripts/ios-device-lease.sh|scripts/ios-device-gui-handoff-macos.sh|scripts/test-ios-device-management.sh|scripts/test-ios-device-gui-handoff-macos.sh|scripts/testdata/ios-device-management/*|scripts/testdata/ios-device-management/**/*|scripts/ios_testflight_ci.sh|scripts/ios_testflight_local.sh|scripts/ios_asc_*|scripts/test-ios-asc-cli.sh|scripts/distribute_internal_build.rb|scripts/generate-nightly-what-to-test.rb|scripts/git-testflight-push|scripts/test-conversation-regressions.sh|scripts/check-critical-regressions.sh|scripts/check-nightly-release.sh|scripts/test-ios-localization-smoke.sh|scripts/check-ios-*|scripts/check-app-store-metadata.sh|scripts/check-source-size.sh|scripts/deploy-ipad.sh|config/release/ios-asc-cli.env|config/release/ios-testflight.local.env)
        ios_scope=true
        ;;
    esac

    case "$changed_path" in
      Cargo.toml|Cargo.lock|bridges/claude/*|bridges/claude/**/*)
        rust_scope=true
        ;;
    esac

    case "$changed_path" in
      macos/MimiRemoteMac/*|macos/MimiRemoteMac/**/*|scripts/test-macos-app.sh)
        macos_scope=true
        ;;
    esac

    case "$changed_path" in
      scripts/check-packaging.sh|scripts/check-app-store-metadata.sh|scripts/check-nightly-release.sh|scripts/generate-nightly-what-to-test.rb)
        docs_scope=true
        ;;
    esac
  done < "$resolved_paths_file"
fi

output="$(
  printf 'go=%s\nios=%s\nrust=%s\nmacos=%s\ndocs=%s\n' \
    "$go_scope" \
    "$ios_scope" \
    "$rust_scope" \
    "$macos_scope" \
    "$docs_scope"
)"
printf '%s\n' "$output"

if [[ -n "$github_output" ]]; then
  printf '%s\n' "$output" >> "$github_output"
fi

if [[ -n "$summary_file" ]]; then
  {
    echo "## PR Gate change scope"
    echo
    echo "- Changed paths: \`$path_count\`"
    echo "- Go and release: \`$go_scope\`"
    echo "- iOS: \`$ios_scope\`"
    echo "- Rust bridge: \`$rust_scope\`"
    echo "- Mac App: \`$macos_scope\`"
    echo "- Docs/static: \`$docs_scope\`"
    echo "- Codex protocol and repository safety: \`always\`"
  } >> "$summary_file"
fi
