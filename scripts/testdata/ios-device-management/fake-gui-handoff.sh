#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_TEST_GUI_HANDOFF_LOG:-}" ]]; then
  {
    printf 'handoff\n'
    for argument in "$@"; do
      printf 'arg\t%s\n' "$argument"
    done
  } >> "$IOS_TEST_GUI_HANDOFF_LOG"
fi

exec "$@"
