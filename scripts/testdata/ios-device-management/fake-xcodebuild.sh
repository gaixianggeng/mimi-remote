#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${IOS_TEST_XCODEBUILD_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$IOS_TEST_XCODEBUILD_LOG"
fi
derived_data_path=""
destination=""
action=""
previous_argument=""
for argument in "$@"; do
  case "$previous_argument" in
    -derivedDataPath) derived_data_path="$argument" ;;
    -destination) destination="$argument" ;;
  esac
  previous_argument="$argument"
  action="$argument"
done
if [[ "${IOS_TEST_CREATE_APP:-0}" == "1" ]]; then
  if [[ -n "$derived_data_path" ]]; then
    product_suffix="iphoneos"
    [[ "$destination" == *"iOS Simulator"* ]] && product_suffix="iphonesimulator"
    mkdir -p "$derived_data_path/Build/Products/Debug-${product_suffix}/MimiRemote.app"
  fi
fi
if [[ "${IOS_TEST_CREATE_TEST_PRODUCTS:-0}" == "1" && "$action" == "build-for-testing" ]]; then
  mkdir -p "$derived_data_path/Build/Products"
  : > "$derived_data_path/Build/Products/MimiRemote_fixture.xctestrun"
fi
if [[ -n "${IOS_TEST_XCODEBUILD_STARTED:-}" ]]; then
  printf '%s\n' "$$" > "$IOS_TEST_XCODEBUILD_STARTED"
fi
if [[ "${IOS_TEST_XCODEBUILD_SLEEP_SECONDS:-0}" != "0" ]]; then
  sleep "$IOS_TEST_XCODEBUILD_SLEEP_SECONDS"
fi
