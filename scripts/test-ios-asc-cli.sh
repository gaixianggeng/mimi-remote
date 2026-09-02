#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimi-asc-cli-test.XXXXXX")"
FAKE_BIN_DIR="$TEST_DIR/bin"
FAKE_ASC="$TEST_DIR/asc"
FAKE_KEY="$TEST_DIR/AuthKey_TEST.p8"
PIN_CONFIG="$TEST_DIR/ios-asc-cli.env"
TRACE_FILE="$TEST_DIR/asc-trace.txt"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

fail_test() {
  echo "ios-asc-cli test failed: $1" >&2
  exit 1
}

assert_line() {
  local expected="$1"
  local content="$2"
  printf '%s\n' "$content" | grep -Fqx "$expected" \
    || fail_test "missing line: $expected"
}

mkdir -p "$FAKE_BIN_DIR"
printf '%s\n' 'test-key' > "$FAKE_KEY"

cat > "$FAKE_ASC" <<'FAKE_ASC_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  version)
    echo "3.4.1 (commit: test, date: 2026-08-01T00:00:00Z)"
    ;;
  builds)
    [[ "${2:-}" == "next-build-number" ]]
    {
      printf 'ASC_TELEMETRY_DISABLED=%s\n' "${ASC_TELEMETRY_DISABLED:-}"
      printf 'ASC_BYPASS_KEYCHAIN=%s\n' "${ASC_BYPASS_KEYCHAIN:-}"
      printf 'ASC_STRICT_AUTH=%s\n' "${ASC_STRICT_AUTH:-}"
      printf 'ASC_KEY_ID=%s\n' "${ASC_KEY_ID:-}"
      printf 'ASC_ISSUER_ID=%s\n' "${ASC_ISSUER_ID:-}"
      printf 'ASC_PRIVATE_KEY_PATH=%s\n' "${ASC_PRIVATE_KEY_PATH:-}"
      printf 'ARGS=%s\n' "$*"
    } > "$FAKE_ASC_TRACE"
    if [[ -n "${FAKE_ASC_JSON+x}" ]]; then
      printf '%s\n' "$FAKE_ASC_JSON"
    else
      printf '%s\n' '{}'
    fi
    ;;
  *)
    echo "unexpected fake asc command: $*" >&2
    exit 2
    ;;
esac
FAKE_ASC_SCRIPT
chmod 700 "$FAKE_ASC"

cat > "$FAKE_BIN_DIR/codesign" <<'FAKE_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --verify)
    exit 0
    ;;
  -dv)
    echo "Authority=Developer ID Application: Test (TESTTEAM)" >&2
    echo "TeamIdentifier=TESTTEAM" >&2
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
FAKE_CODESIGN
chmod 700 "$FAKE_BIN_DIR/codesign"

cat > "$FAKE_BIN_DIR/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-m" ]]; then
  echo arm64
else
  /usr/bin/uname "$@"
fi
FAKE_UNAME
chmod 700 "$FAKE_BIN_DIR/uname"

fake_sha="$(shasum -a 256 "$FAKE_ASC" | awk '{print $1}')"
cat > "$PIN_CONFIG" <<PIN_CONFIG_CONTENT
ASC_CLI_VERSION=3.4.1
ASC_CLI_RELEASE_BASE_URL=https://example.invalid/releases/download
ASC_CLI_MACOS_ARM64_ASSET=asc_3.4.1_macOS_arm64
ASC_CLI_MACOS_ARM64_SHA256=$fake_sha
ASC_CLI_MACOS_AMD64_ASSET=asc_3.4.1_macOS_amd64
ASC_CLI_MACOS_AMD64_SHA256=$fake_sha
ASC_CLI_SIGNING_TEAM_ID=TESTTEAM
PIN_CONFIG_CONTENT

common_env=(
  "PATH=$FAKE_BIN_DIR:$PATH"
  "ASC_CLI_PIN_CONFIG=$PIN_CONFIG"
  "ASC_CLI_BIN=$FAKE_ASC"
  "APP_STORE_CONNECT_API_KEY_ID=KEY123"
  "APP_STORE_CONNECT_API_ISSUER_ID=ISSUER123"
  "APP_STORE_CONNECT_API_KEY_PATH=$FAKE_KEY"
  "FAKE_ASC_TRACE=$TRACE_FILE"
)

check_output="$(env "${common_env[@]}" bash "$ROOT_DIR/scripts/ios_asc_cli.sh" check)"
assert_line "ASC_CLI_CHECK=ok" "$check_output"
assert_line "ASC_CLI_VERSION=3.4.1" "$check_output"
assert_line "ASC_CLI_SIGNING_TEAM_ID=TESTTEAM" "$check_output"

# 已存在且完全匹配的目标必须直接复用，不能重新下载或覆盖。
install_output="$(
  env "${common_env[@]}" \
    bash "$ROOT_DIR/scripts/ios_asc_cli.sh" install --destination "$FAKE_ASC"
)"
assert_line "ios-asc-cli install ok: pinned binary already exists at $FAKE_ASC" "$install_output"

fake_json='{"latestProcessedBuildNumber":"100","latestUploadBuildNumber":"101","latestObservedBuildNumber":"101","nextBuildNumber":"102","sourcesConsidered":["processedBuilds","buildUploads"]}'
query_output="$(
  env "${common_env[@]}" "FAKE_ASC_JSON=$fake_json" \
    bash "$ROOT_DIR/scripts/ios_asc_cli.sh" next-build-number \
      --bundle-id com.gaixianggeng.mimi \
      --version 1.2.0 \
      --build 99
)"
assert_line "ASC_CLI_LATEST_UPLOAD_BUILD_NUMBER=101" "$query_output"
assert_line "ASC_CLI_NEXT_BUILD_NUMBER=102" "$query_output"
assert_line "ASC_CLI_SUGGESTED_BUILD_NUMBER=102" "$query_output"

# 本地工程号更大时，影子建议应保留本地号，避免制造无意义 mismatch。
query_output="$(
  env "${common_env[@]}" "FAKE_ASC_JSON=$fake_json" \
    bash "$ROOT_DIR/scripts/ios_asc_cli.sh" next-build-number \
      --bundle-id com.gaixianggeng.mimi \
      --version 1.2.0 \
      --build 105
)"
assert_line "ASC_CLI_SUGGESTED_BUILD_NUMBER=105" "$query_output"

trace="$(cat "$TRACE_FILE")"
assert_line "ASC_TELEMETRY_DISABLED=1" "$trace"
assert_line "ASC_BYPASS_KEYCHAIN=1" "$trace"
assert_line "ASC_STRICT_AUTH=1" "$trace"
assert_line "ASC_KEY_ID=KEY123" "$trace"
assert_line "ASC_ISSUER_ID=ISSUER123" "$trace"
assert_line "ASC_PRIVATE_KEY_PATH=$FAKE_KEY" "$trace"
assert_line "ARGS=builds next-build-number --app com.gaixianggeng.mimi --version 1.2.0 --platform IOS --output json" "$trace"

if env "${common_env[@]}" "FAKE_ASC_JSON={}" \
  bash "$ROOT_DIR/scripts/ios_asc_cli.sh" next-build-number \
    --bundle-id com.gaixianggeng.mimi \
    --version 1.2.0 \
    --build 99 >/dev/null 2>&1; then
  fail_test "malformed JSON unexpectedly passed"
fi

bad_pin_config="$TEST_DIR/bad-ios-asc-cli.env"
sed "s/$fake_sha/0000000000000000000000000000000000000000000000000000000000000000/g" \
  "$PIN_CONFIG" > "$bad_pin_config"
if env \
  "PATH=$FAKE_BIN_DIR:$PATH" \
  "ASC_CLI_PIN_CONFIG=$bad_pin_config" \
  "ASC_CLI_BIN=$FAKE_ASC" \
  bash "$ROOT_DIR/scripts/ios_asc_cli.sh" check >/dev/null 2>&1; then
  fail_test "bad checksum unexpectedly passed"
fi

# 静态确认两次影子调用分别位于 Archive 与 altool 前，且实际 build_number
# 仍来自 Ruby preflight 输出，不从 ASC_CLI_* 字段赋值。
ruby - "$ROOT_DIR/scripts/ios_testflight_ci.sh" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
first_shadow = source.index('run_asc_build_number_shadow "before-archive"') or abort("missing before-archive shadow")
archive = source.index('xcodebuild archive') or abort("missing archive")
second_shadow = source.index('run_asc_build_number_shadow "before-upload"') or abort("missing before-upload shadow")
altool = source.index('xcrun altool --', second_shadow) or abort("missing altool after shadow")
abort("before-archive shadow ordering is wrong") unless first_shadow < archive
abort("before-upload shadow ordering is wrong") unless archive < second_shadow && second_shadow < altool
abort("asc unexpectedly assigns real build_number") if source.match?(/build_number=.*ASC_CLI_/)
abort("Xcode build settings parser can still close the pipe early") if source.match?(/MARKETING_VERSION[^\n]*;\s*exit\}/) || source.match?(/CURRENT_PROJECT_VERSION[^\n]*;\s*exit\}/)
abort("Xcode build settings parser does not consume the full pipe") unless source.include?("!found && /^[[:space:]]*MARKETING_VERSION") && source.include?("!found && /^[[:space:]]*CURRENT_PROJECT_VERSION")
RUBY

# 本地 --ref 发布必须从目标提交的隔离 worktree 校验 asc pin，不能读取当前
# checkout 的脚本或未提交配置。
ruby - "$ROOT_DIR/scripts/ios_testflight_local.sh" <<'RUBY'
path = ARGV.fetch(0)
source = File.read(path)
worktree = source.index('git -C "$REPO_ROOT" worktree add --detach --quiet "$source_dir" "$release_commit"') or abort("missing release worktree")
asc_check = source.index('bash "$source_dir/scripts/ios_asc_cli.sh" check') or abort("asc check does not use release worktree")
check_exit = source.index('if [[ "$LOCAL_RELEASE_MODE" == "check" ]]', asc_check) or abort("check mode exits before release asc validation")
abort("release asc validation ordering is wrong") unless worktree < asc_check && asc_check < check_exit
abort("local asc check still uses current checkout") if source.include?('bash "$SCRIPT_DIR/ios_asc_cli.sh" check')
RUBY

echo "ios-asc-cli tests passed"
