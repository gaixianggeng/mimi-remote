#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# xcodebuild 对不存在的 -only-testing 类或方法静默执行 0 个用例并报告通过，
# 所以 selector、每晚集合与隔离清单只能靠源码静态校验兜底。规则见
# scripts/ios-test-inventory.py 与 docs/critical-user-journey-regressions.md。
command -v python3 >/dev/null 2>&1 || {
  echo "iOS 测试 selector 检查失败：缺少命令 python3。" >&2
  exit 1
}

python3 ./scripts/ios-test-inventory.py check
