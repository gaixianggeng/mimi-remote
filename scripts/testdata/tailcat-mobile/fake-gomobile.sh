#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
[[ -n "${TAILCAT_TEST_GOMOBILE_LOG:-}" ]] \
  && printf '%s\n' "$command_name" >> "$TAILCAT_TEST_GOMOBILE_LOG"

case "$command_name" in
  init)
    exit 0
    ;;
  bind)
    exit_code="${TAILCAT_TEST_BIND_EXIT_CODE:-0}"
    [[ "$exit_code" == "0" ]] || exit "$exit_code"
    shift
    output=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "-o" ]]; then
        output="$2"
        break
      fi
      shift
    done
    [[ -n "$output" ]] || exit 64
    for slice in ios-arm64 ios-arm64_x86_64-simulator; do
      framework="$output/$slice/TailcatMobile.framework"
      mkdir -p "$framework/Headers"
      printf 'void TailcatmobileStartProxy(void);\n' > "$framework/Headers/TailcatMobile.h"
      printf 'fake binary\n' > "$framework/TailcatMobile"
    done
    ;;
  *)
    exit 64
    ;;
esac
