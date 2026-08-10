#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> iOS English localization smoke"
ios_test_action="${IOS_TEST_ACTION:-test}"
case "$ios_test_action" in
  test|test-without-building) ;;
  *)
    echo "IOS_TEST_ACTION 只支持 test 或 test-without-building：$ios_test_action" >&2
    exit 2
    ;;
esac
bash "$ROOT_DIR/scripts/ios-dev.sh" "$ios_test_action" \
  -quiet \
  -collect-test-diagnostics never \
  -testLanguage en \
  -testRegion US \
  -only-testing:MimiRemoteTests/LocalizationTests
