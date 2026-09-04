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
lock_dir="$TEMP_DIR/cache.lock"
bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_dir" -- \
  bash -c 'printf completed > "$1"' _ "$result_file"
[[ "$(cat "$result_file")" == "completed" ]] || fail "缓存锁没有执行命令"
[[ ! -e "$lock_dir" ]] || fail "命令结束后没有释放缓存锁"

mkdir "$lock_dir"
printf '99999999\n' > "$lock_dir/pid"
bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_dir" -- true
[[ ! -e "$lock_dir" ]] || fail "过期缓存锁没有被清理"

mkdir "$lock_dir"
printf '%s\n' "$$" > "$lock_dir/pid"
set +e
MIMI_DEVELOPMENT_CACHE_LOCK_WAIT_SECONDS=0 \
  bash "$ROOT_DIR/scripts/development-cache-lock.sh" "$lock_dir" -- true \
  >"$TEMP_DIR/busy.log" 2>&1
busy_status=$?
set -e
[[ "$busy_status" -eq 75 ]] || fail "活跃缓存锁必须明确失败"
rm -f "$lock_dir/pid"
rmdir "$lock_dir"

echo "开发缓存路径、跨 Worktree 复用和写入锁自测通过。"
