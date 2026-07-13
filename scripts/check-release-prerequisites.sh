#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_MAIN_REPOSITORY="gaixianggeng/mimi-remote"
readonly EXPECTED_TAP_REPOSITORY="gaixianggeng/homebrew-tap"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-release-prerequisites.sh
  bash ./scripts/check-release-prerequisites.sh --self-test

正式校验需要以下环境变量：
  GITHUB_REPOSITORY  当前 GitHub Actions 仓库名
  GITHUB_TOKEN       主仓库只读 Token（GitHub Actions 内置 Token 即可）
  TAP_GITHUB_TOKEN   对 gaixianggeng/homebrew-tap 有 contents:write 的 Token

--self-test 只校验 GitHub API JSON 判定逻辑，不联网。
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Release 已停止：缺少命令 $1。" >&2
    return 127
  fi
}

inspect_repository_metadata() {
  local metadata="$1"
  local expected_repository="$2"
  local require_push="$3"

  # 这里只返回有限状态码，不输出 API JSON，避免公开 CI 日志带出无关账户元数据。
  printf '%s' "$metadata" | ruby -rjson -e '
    expected_repository = ARGV.fetch(0)
    require_push = ARGV.fetch(1) == "true"

    begin
      metadata = JSON.parse(STDIN.read)
    rescue JSON::ParserError
      puts "malformed"
      exit
    end

    unless metadata.is_a?(Hash)
      puts "malformed"
      exit
    end

    if metadata["full_name"] != expected_repository
      puts "wrong_repository"
    elsif metadata["visibility"] != "public" || metadata["private"] != false
      puts "not_public"
    elsif require_push && metadata.dig("permissions", "push") != true
      puts "no_push"
    else
      puts "ok"
    end
  ' "$expected_repository" "$require_push"
}

validate_repository_metadata() {
  local metadata="$1"
  local expected_repository="$2"
  local repository_label="$3"
  local require_push="$4"
  local result

  if ! result="$(inspect_repository_metadata "$metadata" "$expected_repository" "$require_push")"; then
    echo "Release 已停止：无法执行 GitHub API JSON 校验器。" >&2
    return 1
  fi

  case "$result" in
    ok)
      return 0
      ;;
    malformed)
      echo "Release 已停止：GitHub API 返回的${repository_label}元数据不是有效且完整的 JSON。" >&2
      ;;
    wrong_repository)
      echo "Release 已停止：GitHub API 返回的${repository_label}身份与 ${expected_repository} 不一致。" >&2
      ;;
    not_public)
      echo "Release 已停止：${repository_label} ${expected_repository} 必须设置为 PUBLIC；private/internal 仓库无法支持公开 GitHub Release 和无认证 Homebrew 安装。" >&2
      ;;
    no_push)
      echo "Release 已停止：TAP_GITHUB_TOKEN 对 ${expected_repository} 缺少 contents:write 权限。" >&2
      ;;
    *)
      echo "Release 已停止：${repository_label}元数据校验返回未知状态。" >&2
      ;;
  esac
  return 1
}

fetch_repository_metadata() {
  local repository="$1"
  local token="$2"
  local api_url="${GITHUB_API_URL:-https://api.github.com}"

  # 不启用 shell trace，也不打印 curl 命令；Token 只进入 Authorization 请求头。
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url%/}/repos/${repository}"
}

run_self_test() {
  require_command ruby

  local public_main
  local public_tap
  local private_repository
  local malformed_json

  public_main='{"full_name":"gaixianggeng/mimi-remote","visibility":"public","private":false}'
  public_tap='{"full_name":"gaixianggeng/homebrew-tap","visibility":"public","private":false,"permissions":{"push":true}}'
  private_repository='{"full_name":"gaixianggeng/mimi-remote","visibility":"private","private":true}'
  malformed_json='{"full_name":"gaixianggeng/mimi-remote","visibility":'

  [[ "$(inspect_repository_metadata "$public_main" "$EXPECTED_MAIN_REPOSITORY" false)" == "ok" ]] || {
    echo "自测失败：PUBLIC 主仓库应通过。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$public_tap" "$EXPECTED_TAP_REPOSITORY" true)" == "ok" ]] || {
    echo "自测失败：PUBLIC 且可写的 Tap 应通过。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$private_repository" "$EXPECTED_MAIN_REPOSITORY" false)" == "not_public" ]] || {
    echo "自测失败：PRIVATE 仓库必须被拒绝。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$malformed_json" "$EXPECTED_MAIN_REPOSITORY" false)" == "malformed" ]] || {
    echo "自测失败：损坏的 GitHub API JSON 必须被拒绝。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata '{"full_name":"gaixianggeng/homebrew-tap","visibility":"public","private":false,"permissions":{"push":false}}' "$EXPECTED_TAP_REPOSITORY" true)" == "no_push" ]] || {
    echo "自测失败：没有 push 权限的 Tap Token 必须被拒绝。" >&2
    return 1
  }

  echo "Release 前置门禁自测通过（PUBLIC / PRIVATE / malformed JSON / Tap push 权限）。"
}

run_check() {
  local main_metadata
  local tap_metadata

  require_command curl
  require_command ruby

  if [[ "${GITHUB_REPOSITORY:-}" != "$EXPECTED_MAIN_REPOSITORY" ]]; then
    echo "Release 已停止：请先把 GitHub 仓库重命名为 ${EXPECTED_MAIN_REPOSITORY}，与 Go module 和公开文档保持一致。" >&2
    return 1
  fi
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Release 已停止：缺少用于读取主仓库元数据的 GITHUB_TOKEN。" >&2
    return 1
  fi
  if [[ -z "${TAP_GITHUB_TOKEN:-}" ]]; then
    echo "Release 已停止：缺少 TAP_GITHUB_TOKEN。" >&2
    return 1
  fi

  if ! main_metadata="$(fetch_repository_metadata "$EXPECTED_MAIN_REPOSITORY" "$GITHUB_TOKEN")"; then
    echo "Release 已停止：无法从 GitHub API 读取主仓库 ${EXPECTED_MAIN_REPOSITORY}；请检查仓库状态和 GITHUB_TOKEN 权限。" >&2
    return 1
  fi
  validate_repository_metadata "$main_metadata" "$EXPECTED_MAIN_REPOSITORY" "主仓库" false

  if ! tap_metadata="$(fetch_repository_metadata "$EXPECTED_TAP_REPOSITORY" "$TAP_GITHUB_TOKEN")"; then
    echo "Release 已停止：无法从 GitHub API 读取 Tap ${EXPECTED_TAP_REPOSITORY}；请检查仓库是否存在及 TAP_GITHUB_TOKEN 权限。" >&2
    return 1
  fi
  validate_repository_metadata "$tap_metadata" "$EXPECTED_TAP_REPOSITORY" "Homebrew Tap" true

  echo "Release 前置门禁通过：主仓库与 Homebrew Tap 均为 PUBLIC，Tap Token 具备写权限。"
}

case "${1:-}" in
  "")
    run_check
    ;;
  --self-test)
    run_self_test
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
