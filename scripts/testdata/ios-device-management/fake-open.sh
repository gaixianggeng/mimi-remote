#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_TEST_OPEN_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$IOS_TEST_OPEN_LOG"
fi
if [[ "${IOS_TEST_OPEN_FAIL:-0}" == "1" ]]; then
  echo "fake-open 模拟失败" >&2
  exit 23
fi
