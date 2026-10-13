#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == --self-test ]]; then
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-macos-notices.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT
  mkdir -p "$temp_dir/repo/scripts" "$temp_dir/App.app/Contents/Resources"
  cp "$ROOT_DIR/scripts/check-macos-notices.sh" "$temp_dir/repo/scripts/"
  source_path="$temp_dir/repo/THIRD_PARTY_NOTICES.md"
  bundled_path="$temp_dir/App.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  checker="$temp_dir/repo/scripts/check-macos-notices.sh"
  printf 'Current third-party notices\n' > "$source_path"

  expect_failure() {
    if bash "$checker" "$temp_dir/App.app" > "$temp_dir/result.log" 2>&1; then
      echo "Mac 许可声明自测失败：$1 被放行。" >&2
      exit 1
    fi
    grep -Fq "$2" "$temp_dir/result.log"
  }

  expect_failure "缺失声明" "缺少非空许可声明"
  : > "$bundled_path"
  expect_failure "空文件" "缺少非空许可声明"
  printf ' \t\r\n' > "$bundled_path"
  expect_failure "纯空白声明" "缺少非空许可声明"
  printf 'Outdated notices\n' > "$bundled_path"
  expect_failure "过期声明" "与当前源码不一致"
  cp "$source_path" "$bundled_path"
  bash "$checker" "$temp_dir/App.app"
  : > "$source_path"
  expect_failure "空白源文件" "源码缺少非空许可声明"
  rm "$source_path"
  expect_failure "缺失源文件" "源码缺少非空许可声明"
  echo "Mac 许可声明自测通过（7 项）。"
  exit 0
fi

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "用法：check-macos-notices.sh <App 路径> | --self-test" >&2
  exit 2
fi

source_path="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
bundled_path="$1/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ ! -f "$source_path" ]] || ! LC_ALL=C grep -q '[^[:space:]]' "$source_path"; then
  echo "Mac 许可声明校验失败：源码缺少非空许可声明 THIRD_PARTY_NOTICES.md。" >&2
  exit 1
fi
if [[ ! -f "$bundled_path" ]] || ! LC_ALL=C grep -q '[^[:space:]]' "$bundled_path"; then
  echo "Mac 许可声明校验失败：App 缺少非空许可声明 THIRD_PARTY_NOTICES.md。" >&2
  exit 1
fi
# 构建与 DMG 验收共用这一检查，防止共享产物残留其他分支的旧声明。
if ! cmp -s "$source_path" "$bundled_path"; then
  echo "Mac 许可声明校验失败：App 内声明与当前源码不一致。" >&2
  exit 1
fi
