#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> iOS English localization smoke"
bash "$ROOT_DIR/scripts/ios-dev.sh" test \
  -quiet \
  -collect-test-diagnostics never \
  -testLanguage en \
  -testRegion US \
  -only-testing:MimiRemoteTests/LocalizationTests
