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
    case "${2:-}" in
      golang.org/x/mobile/cmd/gomobile@*)
        cp "${TAILCAT_TEST_FAKE_GOMOBILE:?}" "$GOBIN/gomobile"
        chmod +x "$GOBIN/gomobile"
        ;;
      golang.org/x/mobile/cmd/gobind@*)
        printf '#!/usr/bin/env bash\nexit 0\n' > "$GOBIN/gobind"
        chmod +x "$GOBIN/gobind"
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
