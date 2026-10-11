#!/usr/bin/env bash
# Claude SDK 适配器检查：按锁文件安装依赖、类型检查、运行测试。本地分层验证与 CI 共用。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/bridges/claude-sdk"
REQUIRED_BUN="$(tr -d '[:space:]' < "$PACKAGE_DIR/.bun-version")"

if ! command -v bun >/dev/null 2>&1; then
  echo "缺少 bun ${REQUIRED_BUN}，安装方式见 https://bun.sh/docs/installation" >&2
  exit 127
fi
actual_bun="$(bun --version)"
if [[ "$actual_bun" != "$REQUIRED_BUN" ]]; then
  echo "提示：本机 bun ${actual_bun} 与固定版本 ${REQUIRED_BUN} 不同，结果以 CI 为准。" >&2
fi

cd "$PACKAGE_DIR"
# 适配器始终使用用户已安装的 claude，不需要 SDK 附带的平台二进制（约 240 MB）。
bun install --frozen-lockfile --omit optional
./node_modules/.bin/tsc --noEmit
bun test
