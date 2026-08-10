#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 文档 lane 只执行已有的确定性静态门禁，不启动语言构建、Simulator 或真机。
# 三项分别覆盖安装/发布命令、App Store 文案与 Nightly/Release 编排约束。
bash ./scripts/check-packaging.sh
bash ./scripts/check-app-store-metadata.sh
bash ./scripts/check-nightly-release.sh --check

echo "文档静态门禁通过：安装、App Store 与 Nightly/Release 说明保持一致。"
