#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    if [[ "${2:-}" == -m ]]; then
      [[ -f "$3.version" ]] || exit 1
      printf '\tmod\tgolang.org/x/mobile\t%s\tfake-hash\n' "$(cat "$3.version")"
    else
      echo "go version ${TAILCAT_TEST_GO_VERSION:-go1.26.0} darwin/arm64"
    fi
    ;;
  env)
    printf '%s\ndarwin\narm64\n' "${TAILCAT_TEST_GO_VERSION:-go1.26.0}"
    ;;
  list)
    [[ "${TAILCAT_TEST_LIST_EXIT_CODE:-0}" == 0 ]] || exit "$TAILCAT_TEST_LIST_EXIT_CODE"
    # 使用真实 Go 解析夹具依赖，防止假工具把错误的输入范围也判为通过。
    exec "${TAILCAT_TEST_REAL_GO:?}" "$@"
    ;;
  install)
    [[ -n "${GOBIN:-}" ]] || exit 64
    [[ "$2" != *@latest ]] || exit 65
    printf '%s\n' "$2" >> "${TAILCAT_TEST_INSTALL_LOG:?}"
    mkdir -p "$GOBIN"
    tool="${2%%@*}"
    tool="${tool##*/}"
    printf '%s\n' "${2#*@}" > "$GOBIN/$tool.version"
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
