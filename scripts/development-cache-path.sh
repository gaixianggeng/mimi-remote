#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MIMI_DEVELOPMENT_CACHE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
COMPONENT="${1:-}"

case "$COMPONENT" in
  ""|/*|..|../*|*/../*|*/..)
    echo "开发缓存路径失败：必须提供仓库内使用的相对组件名称。" >&2
    exit 2
    ;;
esac

for command_name in env git shasum awk basename dirname; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { echo "开发缓存路径失败：缺少 ${command_name}。" >&2; exit 1; }
done

# DEVELOPER_DIR 只属于 Xcode 工具链选择。测试或兼容性构建可能把它指向
# 临时 Xcode 目录，不能让 macOS 的 git shim 因此失效。
git_common_dir="$(env -u DEVELOPER_DIR git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
repository_name="$(basename "$(dirname "$git_common_dir")")"
repository_hash="$(printf '%s' "$git_common_dir" | shasum -a 256 | awk '{ print substr($1, 1, 12) }')"

if [[ -n "${MIMI_DEVELOPMENT_CACHE_ROOT:-}" ]]; then
  cache_parent="${MIMI_DEVELOPMENT_CACHE_ROOT%/}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  cache_parent="${XDG_CACHE_HOME:-$HOME/Library/Caches}/MimiRemote/Development"
else
  cache_parent="${XDG_CACHE_HOME:-$HOME/.cache}/mimi-remote/development"
fi

# Git common-dir 在同一仓库的所有 Worktree 中相同。路径哈希让这些 Worktree
# 复用缓存，同时避免另一份 clone 意外写入同一个构建数据库。
printf '%s/%s-%s/%s\n' \
  "$cache_parent" "$repository_name" "$repository_hash" "$COMPONENT"
