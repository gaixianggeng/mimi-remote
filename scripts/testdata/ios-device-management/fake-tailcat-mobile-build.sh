#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_TEST_TAILCAT_BUILD_LOG:-}" ]]; then
  printf '%s\n' "${IOS_TAILCAT_BUILD_ACTION:-unknown}" >> "$IOS_TEST_TAILCAT_BUILD_LOG"
fi
exit "${IOS_TEST_TAILCAT_BUILD_EXIT_CODE:-0}"
