#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-development-cache.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  echo "开发缓存自测失败：$1" >&2
  exit 1
}

cache_path="$({
  MIMI_DEVELOPMENT_CACHE_ROOT="$TEMP_DIR/cache" \
    bash "$ROOT_DIR/scripts/development-cache-path.sh" xcode/ios/Debug
})"
[[ "$cache_path" == "$TEMP_DIR/cache/"*"/xcode/ios/Debug" ]] \
  || fail "共享缓存没有使用显式根目录和组件名称：$cache_path"
[[ "$cache_path" != "$ROOT_DIR/"* ]] \
  || fail "默认开发缓存不得写入 Worktree"

expected_path="$cache_path"
while IFS= read -r worktree_root; do
  actual_path="$({
    MIMI_DEVELOPMENT_CACHE_ROOT="$TEMP_DIR/cache" \
    MIMI_DEVELOPMENT_CACHE_REPO_ROOT="$worktree_root" \
      bash "$ROOT_DIR/scripts/development-cache-path.sh" xcode/ios/Debug
  })"
  [[ "$actual_path" == "$expected_path" ]] \
    || fail "同一 Git 仓库的 Worktree 必须解析到同一缓存：$worktree_root"
done < <(git -C "$ROOT_DIR" worktree list --porcelain | awk '/^worktree / { sub(/^worktree /, ""); print }')

if bash "$ROOT_DIR/scripts/development-cache-path.sh" ../outside >/dev/null 2>&1; then
  fail "缓存组件不得逃逸共享缓存根目录"
fi

result_file="$TEMP_DIR/result"
lock_file="$TEMP_DIR/cache.lock"
bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- \
  bash -c 'printf completed > "$1"' _ "$result_file"
[[ "$(cat "$result_file")" == "completed" ]] || fail "缓存锁没有执行命令"
[[ -f "$lock_file" ]] || fail "锁文件必须保留，避免等待者锁住不同 inode"
bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- true

bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- \
  bash -c 'touch "$1"; while [[ ! -f "$2" ]]; do sleep 0.1; done' \
  _ "$TEMP_DIR/ready" "$TEMP_DIR/release" &
owner_pid=$!
for attempt in {1..100}; do
  [[ -f "$TEMP_DIR/ready" ]] && break
  sleep 0.1
done
[[ -f "$TEMP_DIR/ready" ]] || fail "测试进程未及时取得锁"
set +e
MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS=0 \
  bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- true \
  >"$TEMP_DIR/busy.log" 2>&1
busy_status=$?
set -e
[[ "$busy_status" -eq 75 ]] || fail "活跃缓存锁必须明确失败"
touch "$TEMP_DIR/release"
wait "$owner_pid"

# 同时启动多个真实进程，检查临界区不能重叠，而非只模拟 PID 文件。
pids=()
for attempt in {1..12}; do
  bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- \
    bash -euc 'mkdir "$1"; sleep 0.02; rmdir "$1"' _ "$TEMP_DIR/critical" &
  pids+=("$!")
done
for child_pid in "${pids[@]}"; do
  wait "$child_pid" || fail "并发进程同时进入了共享缓存临界区"
done
set +e
bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- bash -c 'exit 42'
failure_status=$?
set -e
[[ "$failure_status" -eq 42 ]] || fail "没有保留构建失败的退出码"
MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS=0 \
  bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_file" -- true

bash "$ROOT_DIR/scripts/test-macos-local-cache.sh"

echo "开发缓存路径、跨 Worktree 复用和写入锁自测通过。"
