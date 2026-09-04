#!/usr/bin/env bash
set -euo pipefail

LOCK_DIR="${1:-}"
[[ -n "$LOCK_DIR" ]] || { echo "开发缓存锁失败：缺少锁目录。" >&2; exit 2; }
shift
[[ "${1:-}" == "--" ]] || { echo "开发缓存锁失败：缺少 --。" >&2; exit 2; }
shift
[[ "$#" -gt 0 ]] || { echo "开发缓存锁失败：缺少要执行的命令。" >&2; exit 2; }

WAIT_SECONDS="${MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS:-300}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] \
  || { echo "开发缓存锁失败：等待秒数必须是非负整数。" >&2; exit 2; }

mkdir -p "$(dirname "$LOCK_DIR")"
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  owner_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ ! "$owner_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$owner_pid" 2>/dev/null; then
    rm -f -- "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    continue
  fi
  if (( waited >= WAIT_SECONDS )); then
    echo "开发缓存正被进程 ${owner_pid} 使用：${LOCK_DIR}" >&2
    exit 75
  fi
  sleep 1
  waited=$((waited + 1))
done

printf '%s\n' "$$" > "$LOCK_DIR/pid"
cleanup() {
  rm -f -- "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

"$@"
