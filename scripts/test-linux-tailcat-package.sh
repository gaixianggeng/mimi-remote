#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 1 && -x "$1" ]] || { echo '用法：test-linux-tailcat-package.sh <已解压的 Linux Tailcat 可执行文件>' >&2; exit 2; }
sidecar="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
# 此 fixture 依赖 Tailcat module，不能作为主 module 的 Go package 被发现。
cp "$ROOT_DIR/scripts/testdata/linux-tailcat/packaged_test.go.in" "$test_dir/packaged_test.go"
cd "$ROOT_DIR/experiments/tailcat"
# 使用独立 module 的工具链和 Go 全局缓存，不在 Worktree 下载工具或建立缓存。
MIMI_TEST_TAILCAT_BINARY="$sidecar" GOTOOLCHAIN=auto go test \
  "$test_dir/packaged_test.go" -run '^TestPackagedTailcatStartsAndPairs$' -count=1 -timeout=60s
