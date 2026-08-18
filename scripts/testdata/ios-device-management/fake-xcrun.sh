#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SIMULATORS_JSON="${IOS_TEST_SIMULATORS_JSON:-$ROOT_DIR/scripts/testdata/ios-device-management/simulators.json}"
PHYSICAL_JSON="${IOS_TEST_PHYSICAL_JSON:-$ROOT_DIR/scripts/testdata/ios-device-management/physical-devices.json}"

if [[ -n "${IOS_TEST_XCRUN_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$IOS_TEST_XCRUN_LOG"
fi

case "$*" in
  "simctl list devices available -j")
    /bin/cat "$SIMULATORS_JSON"
    ;;
  "simctl list devices available")
    ruby -rjson -e '
      JSON.parse(File.read(ARGV.fetch(0))).fetch("devices").each do |runtime, devices|
        puts "== Devices -- #{runtime} =="
        devices.each { |device| puts "    #{device.fetch("name")} (#{device.fetch("udid")}) (#{device.fetch("state")})" }
      end
    ' "$SIMULATORS_JSON"
    ;;
  "simctl list devices booted -j")
    printf '{"devices":{}}\n'
    ;;
  "devicectl list devices --json-output - --quiet --timeout 5")
    /bin/cat "$PHYSICAL_JSON"
    ;;
  simctl\ boot\ *|simctl\ bootstatus\ *|simctl\ install\ *|simctl\ launch\ *)
    ;;
  devicectl\ device\ *)
    ;;
  *)
    echo "fake-xcrun 不支持：$*" >&2
    exit 64
    ;;
esac
