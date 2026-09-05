#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="${1:-}"
[[ -n "$LOCK_FILE" ]] || { echo "开发缓存锁失败：缺少锁文件。" >&2; exit 2; }
shift
[[ "${1:-}" == "--" ]] || { echo "开发缓存锁失败：缺少 --。" >&2; exit 2; }
shift
[[ "$#" -gt 0 ]] || { echo "开发缓存锁失败：缺少要执行的命令。" >&2; exit 2; }

WAIT_SECONDS="${MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS:-300}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] \
  || { echo "开发缓存锁失败：等待秒数必须是非负整数。" >&2; exit 2; }

mkdir -p "$(dirname "$LOCK_FILE")"
# 由系统原子获取和释放锁，不再把尚未写入 PID 的锁误认成死锁。
# 锁文件必须保留：删除后重建会让等待者锁住不同的 inode，失去互斥。
if [[ "$(uname -s)" == Darwin ]]; then
  exec lockf -k -t "$WAIT_SECONDS" "$LOCK_FILE" "$@"
else
  exec flock -E 75 -w "$WAIT_SECONDS" "$LOCK_FILE" "$@"
fi
