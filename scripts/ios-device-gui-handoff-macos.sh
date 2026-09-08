#!/usr/bin/env bash

set -u

readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
readonly LAUNCHCTL_BIN="${IOS_GUI_HANDOFF_LAUNCHCTL_BIN:-/bin/launchctl}"
readonly PLUTIL_BIN="${IOS_GUI_HANDOFF_PLUTIL_BIN:-/usr/bin/plutil}"
readonly MKTEMP_BIN="${IOS_GUI_HANDOFF_MKTEMP_BIN:-/usr/bin/mktemp}"

write_status() {
  status_file="$1"
  status_code="$2"
  status_tmp="${status_file}.tmp.$$"
  printf '%s\n' "$status_code" >"$status_tmp" || return 1
  mv -f "$status_tmp" "$status_file"
}

run_worker() {
  status_file="$1"
  shift

  if [ "$#" -eq 0 ]; then
    write_status "$status_file" 64
    exit 64
  fi

  # 不使用 shell 命令字符串，确保参数边界与调用方完全一致。
  "$@"
  worker_status=$?
  if ! write_status "$status_file" "$worker_status"; then
    printf '无法写入 GUI 编译任务状态：%s\n' "$status_file" >&2
    exit 74
  fi
  exit "$worker_status"
}

if [ "${1:-}" = "--worker" ]; then
  if [ "$#" -lt 3 ]; then
    printf 'GUI worker 参数不足。\n' >&2
    exit 64
  fi
  worker_status_file="$2"
  shift 2
  run_worker "$worker_status_file" "$@"
fi

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'GUI 编译交接仅支持 macOS。\n' >&2
  exit 69
fi

if [ "$#" -eq 0 ]; then
  printf '用法：bash %s <command> [args...]\n' "$0" >&2
  exit 64
fi

gui_uid="$(id -u)"
gui_domain="gui/${gui_uid}"
if ! "$LAUNCHCTL_BIN" print "$gui_domain" >/dev/null 2>&1; then
  printf '当前用户没有可用的 macOS GUI 登录会话：%s\n' "$gui_domain" >&2
  exit 69
fi

handoff_tmp_root="${TMPDIR:-/tmp}"
handoff_dir="$($MKTEMP_BIN -d "${handoff_tmp_root%/}/mimi-ios-gui-handoff.XXXXXX")"
if [ -z "$handoff_dir" ] || [ ! -d "$handoff_dir" ]; then
  printf '无法创建 GUI 编译任务的私有临时目录。\n' >&2
  exit 73
fi
chmod 700 "$handoff_dir" || {
  printf '无法保护 GUI 编译任务的临时目录：%s\n' "$handoff_dir" >&2
  exit 73
}

label="com.gaixianggeng.mimi.ios-gui-handoff.$$.${RANDOM}"
service_target="${gui_domain}/${label}"
plist_file="${handoff_dir}/job.plist"
status_file="${handoff_dir}/status"
log_file="${handoff_dir}/output.log"
touch "$log_file"
chmod 600 "$log_file"

job_loaded=0
log_offset=0

flush_log() {
  log_size="$(wc -c <"$log_file" | tr -d '[:space:]')"
  case "$log_size" in
    ''|*[!0-9]*) return ;;
  esac
  if [ "$log_size" -le "$log_offset" ]; then
    return
  fi

  # 限定本次读取的字节数，避免并发追加造成重复或遗漏。
  log_count=$((log_size - log_offset))
  /usr/bin/tail -c "+$((log_offset + 1))" "$log_file" | /usr/bin/head -c "$log_count"
  log_offset="$log_size"
}

job_is_running() {
  "$LAUNCHCTL_BIN" print "$service_target" 2>/dev/null | grep -Eq 'state = running'
}

stop_job() {
  if [ "$job_loaded" -eq 1 ]; then
    # launchd 负责终止该 job 及其后代；给正常退出留出短暂窗口。
    "$LAUNCHCTL_BIN" kill SIGTERM "$service_target" >/dev/null 2>&1 || true
    stop_attempt=0
    while job_is_running && [ "$stop_attempt" -lt 20 ]; do
      sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
    if job_is_running; then
      "$LAUNCHCTL_BIN" kill SIGKILL "$service_target" >/dev/null 2>&1 || true
    fi
    "$LAUNCHCTL_BIN" bootout "$service_target" >/dev/null 2>&1 || true
    job_loaded=0
  fi
}

cleanup() {
  stop_job
  flush_log
  # 只删除本脚本创建的已知文件，避免测试注入的 mktemp 实现扩大删除范围。
  rm -f "$plist_file" "$status_file" "${status_file}.tmp.$$" "$log_file"
  rmdir "$handoff_dir" >/dev/null 2>&1 || true
}

handle_signal() {
  trap - INT TERM HUP
  # 让唯一的 EXIT trap 完成清理，避免重复读取已经删除的日志文件。
  exit "$1"
}

trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP
trap cleanup EXIT

if ! "$PLUTIL_BIN" -create xml1 "$plist_file"; then
  printf '无法创建 GUI 编译任务配置。\n' >&2
  exit 73
fi

"$PLUTIL_BIN" -insert Label -string "$label" "$plist_file" || exit 73
"$PLUTIL_BIN" -insert ProcessType -string Interactive "$plist_file" || exit 73
"$PLUTIL_BIN" -insert RunAtLoad -bool true "$plist_file" || exit 73
"$PLUTIL_BIN" -insert KeepAlive -bool false "$plist_file" || exit 73
"$PLUTIL_BIN" -insert WorkingDirectory -string "$PWD" "$plist_file" || exit 73
"$PLUTIL_BIN" -insert StandardOutPath -string "$log_file" "$plist_file" || exit 73
"$PLUTIL_BIN" -insert StandardErrorPath -string "$log_file" "$plist_file" || exit 73
"$PLUTIL_BIN" -insert ProgramArguments -array "$plist_file" || exit 73

argument_index=0
for argument in "$SCRIPT_PATH" "--worker" "$status_file" "$@"; do
  "$PLUTIL_BIN" -insert "ProgramArguments.${argument_index}" -string "$argument" "$plist_file" || exit 73
  argument_index=$((argument_index + 1))
done

"$PLUTIL_BIN" -insert EnvironmentVariables -dictionary "$plist_file" || exit 73
for environment_name in HOME PATH TMPDIR USER LOGNAME SHELL LANG LC_ALL; do
  environment_value="${!environment_name-}"
  if [ -n "$environment_value" ]; then
    "$PLUTIL_BIN" -insert "EnvironmentVariables.${environment_name}" -string "$environment_value" "$plist_file" || exit 73
  fi
done

# bootstrap 可能已经加载 job 后才被信号中断，因此提前允许 cleanup bootout。
job_loaded=1
if ! "$LAUNCHCTL_BIN" bootstrap "$gui_domain" "$plist_file"; then
  printf '无法在 macOS GUI 会话启动编译任务。\n' >&2
  exit 70
fi

not_running_count=0
while [ ! -f "$status_file" ]; do
  flush_log
  job_state="$($LAUNCHCTL_BIN print "$service_target" 2>/dev/null)"
  print_status=$?
  if [ "$print_status" -ne 0 ]; then
    not_running_count=$((not_running_count + 1))
  elif printf '%s\n' "$job_state" | grep -Eq 'state = (exited|not running)'; then
    not_running_count=$((not_running_count + 1))
  else
    not_running_count=0
  fi

  if [ "$not_running_count" -ge 5 ]; then
    printf 'GUI 编译任务已经退出，但没有写入退出状态。\n' >&2
    exit 70
  fi
  sleep 0.1
done

# status 由 worker 在命令退出后写入。最后一次读取保证末尾日志先于返回码交付。
flush_log

worker_exit_code="$(sed -n '1p' "$status_file")"
case "$worker_exit_code" in
  ''|*[!0-9]*)
    printf 'GUI 编译任务返回了无效退出状态：%s\n' "$worker_exit_code" >&2
    exit 70
    ;;
esac

if [ "$worker_exit_code" -gt 255 ]; then
  printf 'GUI 编译任务返回了超出范围的退出状态：%s\n' "$worker_exit_code" >&2
  exit 70
fi

exit "$worker_exit_code"
