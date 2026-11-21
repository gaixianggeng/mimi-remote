#!/usr/bin/env bash
# 兼容入口：统一同步共享 bridges/appserver-kit 下的 Codex 协议类型。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../../appserver-kit/scripts/sync-protocol.sh" "$@"
