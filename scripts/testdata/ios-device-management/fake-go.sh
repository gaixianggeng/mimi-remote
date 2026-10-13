#!/usr/bin/env bash
set -euo pipefail

# 构建证据只读取 Go 工具链身份；版本通过环境变量模拟升级。
case "$*" in
  version)
    printf 'go version %s fake/arm64\n' "${IOS_TEST_GO_VERSION:-go1.99.0}"
    ;;
  "env GOVERSION GOHOSTOS GOHOSTARCH")
    printf '%s\nfake\narm64\n' "${IOS_TEST_GO_VERSION:-go1.99.0}"
    ;;
  *)
    echo "fake-go 不支持：$*" >&2
    exit 64
    ;;
esac
