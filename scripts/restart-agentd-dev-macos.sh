#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly JOB_LABEL="com.gaixianggeng.mimi-remote.agentd-dev-restart"
readonly HOMEBREW_SERVICE_LABEL="homebrew.mxcl.mimi-remote"
readonly STATE_DIR="${HOME}/Library/Application Support/mimi-remote/dev-restart"
readonly LATEST_STATUS="${STATE_DIR}/latest-status"
readonly LOG_PATH="${HOME}/Library/Logs/mimi-remote-dev-restart.log"
readonly SIGN_SCRIPT="${ROOT_DIR}/scripts/sign-agentd-dev-macos.sh"
readonly HANDOFF_SCRIPT="${ROOT_DIR}/scripts/restart-agentd-dev-handoff-macos.sh"
LOCK_DIR=""

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/restart-agentd-dev-macos.sh [--no-wait]
  bash ./scripts/restart-agentd-dev-macos.sh --status
  bash ./scripts/restart-agentd-dev-macos.sh --self-test

默认流程：构建 → Apple Development 稳定签名 → launchd 独立交接 → 原子替换与重启
          → readyz 验证 → 失败自动恢复旧二进制。

--no-wait  适合从 iPad/Codex 远程任务发起。交接成功后立即返回，旧连接随后会断开。
--status   查看最近一次交接结果和日志。

环境变量：
  MIMI_AGENTD_SIGN_IDENTITY    覆盖本机开发签名 identity。
  MIMI_AGENTD_INSTALL_PATH     覆盖 Homebrew agentd 真实安装路径，仅用于隔离测试。
EOF
}

fail() {
  echo "agentd 开发重启失败：$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令 $1"
}

self_test() {
  bash "$SIGN_SCRIPT" --self-test >/dev/null
  bash -n "$HANDOFF_SCRIPT"
  [[ "$JOB_LABEL" != "$HOMEBREW_SERVICE_LABEL" ]]
  echo "agentd 开发重启流水线自测通过。"
}

show_status() {
  local latest=""
  if [[ -f "$LATEST_STATUS" ]]; then
    latest="$(<"$LATEST_STATUS")"
    printf '最近状态：%s\n' "$latest"
  else
    echo "最近状态：尚无开发重启记录"
  fi
  if [[ -f "$LOG_PATH" ]]; then
    echo "最近日志：$LOG_PATH"
    /usr/bin/tail -n 40 "$LOG_PATH"
  fi
  # --no-wait 会留下一个已退出但仍加载的一次性 job；查看终态时顺手卸载。
  case "$latest" in
    ok\ *|rolled_back\ *|failed\ *)
      if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${JOB_LABEL}" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

acquire_lock() {
  local lock_dir="$1"
  if /bin/mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_dir/pid"
    return
  fi
  local owner=""
  if [[ -f "$lock_dir/pid" ]]; then
    owner="$(<"$lock_dir/pid")"
  fi
  if [[ "$owner" =~ ^[0-9]+$ ]] && /bin/kill -0 "$owner" 2>/dev/null; then
    fail "已有构建正在运行（pid=${owner}）"
  fi
  /bin/rm -f -- "$lock_dir/pid"
  /bin/rmdir "$lock_dir" 2>/dev/null || fail "存在无法确认的旧锁：$lock_dir"
  /bin/mkdir "$lock_dir"
  printf '%s\n' "$$" > "$lock_dir/pid"
}

cleanup_lock() {
  if [[ -n "$LOCK_DIR" ]]; then
    /bin/rm -f -- "$LOCK_DIR/pid"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

wait_for_handoff() {
  local run_status="$1"
  local attempts=58
  local value=""
  while (( attempts > 0 )); do
    if [[ -f "$run_status" ]]; then
      value="$(<"$run_status")"
      case "$value" in
        ok\ *)
          echo "开发版 agentd 已重启并通过 readyz：${value}"
          return 0
          ;;
        rolled_back\ *|failed\ *)
          echo "开发版 agentd 更新未完成：${value}" >&2
          show_status >&2
          return 1
          ;;
      esac
    fi
    attempts=$((attempts - 1))
    /bin/sleep 1
  done
  echo "交接仍在后台运行；稍后执行以下命令查看：" >&2
  echo "  bash ./scripts/restart-agentd-dev-macos.sh --status" >&2
  return 2
}

main() {
  local no_wait="false"
  case "${1:-}" in
    "") ;;
    --no-wait) no_wait="true" ;;
    --status) show_status; return ;;
    --self-test) self_test; return ;;
    -h|--help) usage; return ;;
    *) usage >&2; exit 2 ;;
  esac
  [[ $# -le 1 ]] || { usage >&2; exit 2; }
  [[ "$(uname -s)" == "Darwin" ]] || fail "只支持 macOS"

  for command_name in brew codesign file git go launchctl plutil security; do
    require_command "$command_name"
  done
  [[ -x "$SIGN_SCRIPT" && -x "$HANDOFF_SCRIPT" ]] || fail "签名或交接脚本缺失可执行权限"

  /bin/mkdir -p "$STATE_DIR" "$(dirname "$LOG_PATH")"
  /bin/chmod 700 "$STATE_DIR"
  LOCK_DIR="${STATE_DIR}/build.lock"
  acquire_lock "$LOCK_DIR"
  trap cleanup_lock EXIT

  local brew_prefix
  local target_binary
  local current_version
  local git_revision
  local new_version
  local run_dir
  local candidate
  local backup
  local service_target="gui/$(id -u)/${HOMEBREW_SERVICE_LABEL}"
  local job_target="gui/$(id -u)/${JOB_LABEL}"
  local job_details
  local brew_binary
  local handoff_plist

  brew_prefix="$(brew --prefix mimi-remote 2>/dev/null)" \
    || fail "尚未安装 Homebrew mimi-remote；请先执行 brew install gaixianggeng/tap/mimi-remote"
  brew_binary="$(command -v brew)"
  target_binary="${MIMI_AGENTD_INSTALL_PATH:-${brew_prefix}/bin/agentd}"
  [[ -f "$target_binary" && ! -L "$target_binary" && -x "$target_binary" ]] \
    || fail "Homebrew agentd 不是可替换的普通文件：$target_binary"
  current_version="$("$target_binary" version)"

  git_revision="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
  new_version="devel-${git_revision}"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    new_version="${new_version}-dirty"
  fi
  run_dir="${STATE_DIR}/run-$(date +%Y%m%d%H%M%S)-$$"
  /bin/mkdir "$run_dir"
  candidate="${run_dir}/agentd.candidate"
  backup="${run_dir}/agentd.previous"
  handoff_plist="${run_dir}/handoff.plist"

  echo "正在构建 ${new_version}..."
  (
    cd "$ROOT_DIR"
    CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X main.version=${new_version}" \
      -o "$candidate" ./cmd/agentd
  )
  /bin/chmod 755 "$candidate"
  bash "$SIGN_SCRIPT" "$candidate"
  [[ "$("$candidate" version)" == "$new_version" ]] || fail "候选二进制版本注入失败"
  /bin/cp -p "$target_binary" "$backup"

  job_details="$(launchctl print "$job_target" 2>/dev/null || true)"
  if grep -Fq 'state = running' <<<"$job_details"; then
    fail "已有 launchd 开发重启交接正在运行"
  fi
  launchctl bootout "$job_target" >/dev/null 2>&1 || true
  : > "$LOG_PATH"
  /bin/chmod 600 "$LOG_PATH"
  printf '%s\n' "submitted version=${new_version}" > "$LATEST_STATUS"
  /bin/chmod 600 "$LATEST_STATUS"

  # submit 子命令会隐式创建 KeepAlive job，即使脚本成功退出也可能重复执行。
  # 显式生成 KeepAlive=false 的一次性 LaunchAgent，确保替换/回滚最多执行一轮。
  plutil -create xml1 "$handoff_plist"
  plutil -insert Label -string "$JOB_LABEL" "$handoff_plist"
  plutil -insert ProgramArguments -json '[]' "$handoff_plist"
  local handoff_arguments=(
    /bin/bash "$HANDOFF_SCRIPT"
    "$run_dir" "$target_binary" "$service_target" "$new_version" "$current_version"
    "$candidate" "$backup" "$LATEST_STATUS" "$brew_binary"
  )
  local argument_index=0
  local argument
  for argument in "${handoff_arguments[@]}"; do
    plutil -insert "ProgramArguments.${argument_index}" -string "$argument" "$handoff_plist"
    argument_index=$((argument_index + 1))
  done
  plutil -insert RunAtLoad -bool true "$handoff_plist"
  plutil -insert KeepAlive -bool false "$handoff_plist"
  plutil -insert ProcessType -string Background "$handoff_plist"
  plutil -insert StandardOutPath -string "$LOG_PATH" "$handoff_plist"
  plutil -insert StandardErrorPath -string "$LOG_PATH" "$handoff_plist"
  plutil -lint "$handoff_plist" >/dev/null
  launchctl bootstrap "gui/$(id -u)" "$handoff_plist"

  echo "已把更新交给独立 launchd job：${JOB_LABEL}"
  echo "目标版本：${new_version}；失败时自动恢复：${current_version}"
  if [[ "$no_wait" == "true" ]]; then
    echo "旧连接可能在数秒后断开；重连后运行 --status 查看结果。"
    return
  fi
  local wait_status=0
  wait_for_handoff "${run_dir}/status" || wait_status=$?
  launchctl bootout "$job_target" >/dev/null 2>&1 || true
  return "$wait_status"
}

main "$@"
