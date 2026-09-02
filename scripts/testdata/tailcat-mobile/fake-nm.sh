#!/usr/bin/env bash
set -euo pipefail

binary="${@: -1}"
[[ -f "$binary" ]] || exit 1
echo "0000000000000000 T _TailcatmobileStartProxy"
