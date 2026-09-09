#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "--sdk iphoneos --show-sdk-build-version") echo "${TAILCAT_TEST_SDK_VERSION:-23F81a}" ;;
  "--sdk iphonesimulator --show-sdk-build-version") echo "${TAILCAT_TEST_SDK_VERSION:-23F81a}" ;;
  *) exit 64 ;;
esac
