#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_MAIN_REPOSITORY="gaixianggeng/mimi-remote"
readonly EXPECTED_TAP_REPOSITORY="gaixianggeng/homebrew-tap"
readonly EXPECTED_TAP_SSH_URL="git@github.com:gaixianggeng/homebrew-tap.git"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-release-prerequisites.sh
  bash ./scripts/check-release-prerequisites.sh --self-test

正式校验需要以下环境变量：
  GITHUB_REPOSITORY  当前 GitHub Actions 仓库名
  GITHUB_TOKEN       主仓库只读 Token（GitHub Actions 内置 Token 即可）
  TAP_DEPLOY_KEY     仅对 gaixianggeng/homebrew-tap 有写权限的 SSH Deploy Key

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

  # 这里只返回有限状态码，不输出 API JSON，避免公开 CI 日志带出无关账户元数据。
  printf '%s' "$metadata" | ruby -rjson -e '
    expected_repository = ARGV.fetch(0)

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
    else
      puts "ok"
    end
  ' "$expected_repository"
}

validate_repository_metadata() {
  local metadata="$1"
  local expected_repository="$2"
  local repository_label="$3"
  local result

  if ! result="$(inspect_repository_metadata "$metadata" "$expected_repository")"; then
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
    *)
      echo "Release 已停止：${repository_label}元数据校验返回未知状态。" >&2
      ;;
  esac
  return 1
}

verify_tap_deploy_key() {
  local key_file
  local tap_dir
  local ssh_command
  local status=0

  key_file="$(mktemp -t mimi-remote-tap-key)"
  tap_dir="$(mktemp -d -t mimi-remote-tap-check)"
  # OpenSSH 私钥必须以换行结束；GitHub Secret 展开后不能假设仍保留文件尾换行。
  printf '%s\n' "$TAP_DEPLOY_KEY" > "$key_file"
  chmod 600 "$key_file"
  ssh_command="ssh -i $key_file -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -F /dev/null"

  # 核心逻辑：对 Tap 的同一 main ref 做 dry-run push，验证的是 receive-pack 写权限，不产生远端提交。
  if ! GIT_SSH_COMMAND="$ssh_command" git clone --quiet --depth 1 "$EXPECTED_TAP_SSH_URL" "$tap_dir"; then
    echo "Release 已停止：Tap Deploy Key 无法读取 ${EXPECTED_TAP_REPOSITORY}。" >&2
    status=1
  elif ! (
    cd "$tap_dir"
    GIT_SSH_COMMAND="$ssh_command" git push --dry-run --quiet origin HEAD:main
  ); then
    echo "Release 已停止：Tap Deploy Key 没有 ${EXPECTED_TAP_REPOSITORY} 的写权限。" >&2
    status=1
  fi

  rm -f "$key_file"
  rm -rf "$tap_dir"
  return "$status"
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
  public_tap='{"full_name":"gaixianggeng/homebrew-tap","visibility":"public","private":false}'
  private_repository='{"full_name":"gaixianggeng/mimi-remote","visibility":"private","private":true}'
  malformed_json='{"full_name":"gaixianggeng/mimi-remote","visibility":'

  [[ "$(inspect_repository_metadata "$public_main" "$EXPECTED_MAIN_REPOSITORY")" == "ok" ]] || {
    echo "自测失败：PUBLIC 主仓库应通过。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$public_tap" "$EXPECTED_TAP_REPOSITORY")" == "ok" ]] || {
    echo "自测失败：PUBLIC Tap 应通过。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$private_repository" "$EXPECTED_MAIN_REPOSITORY")" == "not_public" ]] || {
    echo "自测失败：PRIVATE 仓库必须被拒绝。" >&2
    return 1
  }
  [[ "$(inspect_repository_metadata "$malformed_json" "$EXPECTED_MAIN_REPOSITORY")" == "malformed" ]] || {
    echo "自测失败：损坏的 GitHub API JSON 必须被拒绝。" >&2
    return 1
  }
  echo "Release 前置门禁自测通过（PUBLIC / PRIVATE / malformed JSON）。"
}

run_check() {
  local main_metadata
  local tap_metadata

  require_command curl
  require_command git
  require_command ruby

  if [[ "${GITHUB_REPOSITORY:-}" != "$EXPECTED_MAIN_REPOSITORY" ]]; then
    echo "Release 已停止：发布工作流必须运行在 ${EXPECTED_MAIN_REPOSITORY}，不能从私有开发仓库或其他镜像创建公开 Release。" >&2
    return 1
  fi
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "Release 已停止：缺少用于读取主仓库元数据的 GITHUB_TOKEN。" >&2
    return 1
  fi
  if [[ -z "${TAP_DEPLOY_KEY:-}" ]]; then
    echo "Release 已停止：缺少 TAP_DEPLOY_KEY。" >&2
    return 1
  fi

  if ! main_metadata="$(fetch_repository_metadata "$EXPECTED_MAIN_REPOSITORY" "$GITHUB_TOKEN")"; then
    echo "Release 已停止：无法从 GitHub API 读取主仓库 ${EXPECTED_MAIN_REPOSITORY}；请检查仓库状态和 GITHUB_TOKEN 权限。" >&2
    return 1
  fi
  validate_repository_metadata "$main_metadata" "$EXPECTED_MAIN_REPOSITORY" "主仓库"

  if ! tap_metadata="$(fetch_repository_metadata "$EXPECTED_TAP_REPOSITORY" "$GITHUB_TOKEN")"; then
    echo "Release 已停止：无法从 GitHub API 读取 Tap ${EXPECTED_TAP_REPOSITORY}；请检查仓库是否存在。" >&2
    return 1
  fi
  validate_repository_metadata "$tap_metadata" "$EXPECTED_TAP_REPOSITORY" "Homebrew Tap"
  verify_tap_deploy_key

  echo "Release 前置门禁通过：主仓库与 Homebrew Tap 均为 PUBLIC，Tap Deploy Key 写权限可用。"
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
