#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_SCRIPT="${SCRIPT_DIR}/ios-device-gui-handoff-macos.sh"

if [ "${1:-}" = "--exit-helper" ]; then
  shift
  if [ "$#" -ne 2 ] || [ "$1" != "argument with space" ] || [ "$2" != 'literal*value' ]; then
    printf 'argv 校验失败\n' >&2
    exit 66
  fi
  if [ -n "${SSH_CONNECTION-}" ] || [ -n "${SSH_CLIENT-}" ] || [ -n "${SSH_TTY-}" ]; then
    printf 'SSH 环境变量泄漏到 GUI worker\n' >&2
    exit 67
  fi
  printf 'FINAL_LOG_MARKER\n'
  exit 65
fi

if [ "${1:-}" = "--term-helper" ]; then
  pid_file="$2"
  printf '%s\n' "$$" >"$pid_file"
  trap 'exit 0' TERM
  while :; do
    sleep 1
  done
fi

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'SKIP：仅在 macOS 运行 GUI LaunchAgent 测试。\n'
  exit 0
fi

gui_domain="gui/$(id -u)"
if ! /bin/launchctl print "$gui_domain" >/dev/null 2>&1; then
  printf 'SKIP：当前没有可用 GUI 登录会话。\n'
  exit 0
fi

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-ios-gui-handoff-test.XXXXXX")"
chmod 700 "$test_dir"
cleanup_test() {
  rm -f "$test_dir/exit-output" "$test_dir/term-output" "$test_dir/helper-pid"
  rmdir "$test_dir" >/dev/null 2>&1 || true
}
trap cleanup_test EXIT

set +e
SSH_CONNECTION='127.0.0.1 1 127.0.0.1 2' \
SSH_CLIENT='127.0.0.1 1 2' \
SSH_TTY='/dev/ttys999' \
bash "$HANDOFF_SCRIPT" "$0" --exit-helper 'argument with space' 'literal*value' >"$test_dir/exit-output" 2>&1
exit_status=$?
set -e

if [ "$exit_status" -ne 65 ]; then
  printf 'FAIL：期望退出码 65，实际为 %s。\n' "$exit_status" >&2
  sed -n '1,200p' "$test_dir/exit-output" >&2
  exit 1
fi
if ! grep -q '^FINAL_LOG_MARKER$' "$test_dir/exit-output"; then
  printf 'FAIL：未收到 worker 最后一行日志。\n' >&2
  sed -n '1,200p' "$test_dir/exit-output" >&2
  exit 1
fi

bash "$HANDOFF_SCRIPT" "$0" --term-helper "$test_dir/helper-pid" >"$test_dir/term-output" 2>&1 &
launcher_pid=$!
wait_attempt=0
while [ ! -s "$test_dir/helper-pid" ] && [ "$wait_attempt" -lt 100 ]; do
  sleep 0.1
  wait_attempt=$((wait_attempt + 1))
done
if [ ! -s "$test_dir/helper-pid" ]; then
  printf 'FAIL：TERM helper 未启动。\n' >&2
  kill -TERM "$launcher_pid" >/dev/null 2>&1 || true
  wait "$launcher_pid" >/dev/null 2>&1 || true
  exit 1
fi

helper_pid="$(sed -n '1p' "$test_dir/helper-pid")"
kill -TERM "$launcher_pid"
set +e
wait "$launcher_pid"
term_status=$?
set -e
if [ "$term_status" -ne 143 ]; then
  printf 'FAIL：TERM 后期望退出码 143，实际为 %s。\n' "$term_status" >&2
  exit 1
fi
if grep -q 'No such file' "$test_dir/term-output"; then
  printf 'FAIL：TERM 清理重复访问了已经删除的临时文件。\n' >&2
  sed -n '1,200p' "$test_dir/term-output" >&2
  exit 1
fi

wait_attempt=0
while kill -0 "$helper_pid" >/dev/null 2>&1 && [ "$wait_attempt" -lt 50 ]; do
  sleep 0.1
  wait_attempt=$((wait_attempt + 1))
done
if kill -0 "$helper_pid" >/dev/null 2>&1; then
  printf 'FAIL：TERM 后 GUI command 仍然存活：%s。\n' "$helper_pid" >&2
  exit 1
fi
if /bin/launchctl print "$gui_domain" 2>/dev/null | grep -q 'com.gaixianggeng.mimi.ios-gui-handoff'; then
  printf 'FAIL：TERM 后仍残留 GUI handoff job。\n' >&2
  exit 1
fi

printf 'PASS：GUI handoff 参数、日志、退出码、环境隔离和 TERM 清理均通过。\n'
