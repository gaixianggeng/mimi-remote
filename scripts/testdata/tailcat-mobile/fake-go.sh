#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    echo "go version go1.26.0 darwin/arm64"
    ;;
  env)
    printf 'go1.26.0\ndarwin\narm64\n'
    ;;
  install)
    [[ -n "${GOBIN:-}" ]] || exit 64
    mkdir -p "$GOBIN"
    cp "${TAILCAT_TEST_FAKE_GOMOBILE:?}" "$GOBIN/gomobile"
    chmod +x "$GOBIN/gomobile"
    ;;
  *)
    exit 64
    ;;
esac
