#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

HOME="$TEST_DIR/home"
export HOME
unset AGENTD_CONFIG XDG_CONFIG_HOME
mkdir -p "$HOME" "$TEST_DIR/bin" "$TEST_DIR/state"

export FAKE_SYSTEMCTL_ENABLED="$TEST_DIR/state/enabled"
export FAKE_SYSTEMCTL_ACTIVE="$TEST_DIR/state/active"
export FAKE_SYSTEMCTL_LOG="$TEST_DIR/state/systemctl.log"
export FAKE_AGENTD_LOG="$TEST_DIR/state/agentd.log"
export FAKE_JOURNALCTL_LOG="$TEST_DIR/state/journalctl.log"
export TEST_SECRET="test-sensitive-token-must-not-leak"

cat >"$TEST_DIR/bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
  *) echo "Linux" ;;
esac
SH

cat >"$TEST_DIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
if [[ "${1:-}" == "--user" ]]; then
  shift
fi
case "${1:-}" in
  is-enabled) [[ -f "$FAKE_SYSTEMCTL_ENABLED" ]] ;;
  is-active) [[ -f "$FAKE_SYSTEMCTL_ACTIVE" ]] ;;
  enable) : >"$FAKE_SYSTEMCTL_ENABLED" ;;
  disable)
    [[ "${FAKE_SYSTEMCTL_FAIL_DISABLE:-0}" != "1" ]] || exit 42
    rm -f "$FAKE_SYSTEMCTL_ENABLED"
    ;;
  start|restart) : >"$FAKE_SYSTEMCTL_ACTIVE" ;;
  stop)
    [[ "${FAKE_SYSTEMCTL_FAIL_STOP:-0}" != "1" ]] || exit 41
    rm -f "$FAKE_SYSTEMCTL_ACTIVE"
    ;;
  daemon-reload) : ;;
  *) echo "未知 fake systemctl 命令：$*" >&2; exit 2 ;;
esac
SH

cat >"$TEST_DIR/bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_JOURNALCTL_LOG"
printf 'codex app-server failed: authorization=Bearer %s\n' "$TEST_SECRET"
printf 'Token：%s\n' "$TEST_SECRET"
for ((line_number = 3; line_number <= 86; line_number++)); do
  printf 'journal-line-%d\n' "$line_number"
done
SH

cat >"$TEST_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
# 回归测试不需要真实等待。
exit 0
SH
chmod +x "$TEST_DIR/bin/uname" "$TEST_DIR/bin/systemctl" "$TEST_DIR/bin/journalctl" "$TEST_DIR/bin/sleep"
PATH="$TEST_DIR/bin:$PATH"
export PATH

# Darwin does not ship util-linux flock. Preserve real lock contention in
# the fake Linux host using the inherited file descriptor.
if ! command -v flock >/dev/null; then
  cat >"$TEST_DIR/bin/flock" <<'PY'
#!/usr/bin/env python3
import fcntl
import sys
try:
    fcntl.flock(int(sys.argv[2]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
PY
  chmod +x "$TEST_DIR/bin/flock"
fi

make_release() {
  local destination="$1"
  local version="$2"
  local healthy="$3"
  mkdir -p "$destination/scripts" "$destination/packaging/systemd"
  cp "$ROOT_DIR/scripts/install-linux.sh" "$destination/scripts/install-linux.sh"
  cp "$ROOT_DIR/packaging/systemd/mimi-remote.service" \
    "$destination/packaging/systemd/mimi-remote.service"
  printf '#!/usr/bin/env bash\nset -eu\nversion=%q\nhealthy=%q\n' "$version" "$healthy" >"$destination/agentd"
  cat >>"$destination/agentd" <<'SH'
if [[ "$1" == preflight ]]; then
  [[ "${0##*/}" != agentd.previous && -z "${FAKE_AGENTD_LOG:-}" ]]
  [[ "$*" == "preflight --stage setup --json --installer-smoke --config $HOME/config.json --scan-root $HOME --browse-root $HOME" ]]
  [[ "$HOME" == "$TMPDIR" && "$HOME" == "$XDG_CONFIG_HOME" && ! -e "$HOME/config.json" ]]
  if [[ -f "${0%/*}/fail-preflight" ]]; then
    cat "${0%/*}/fail-preflight" >&2
    exit 17
  fi
  echo '{"schema":"mimi.onboarding.preflight/v1","stage":"setup","ok":true,"configured":false}'
  exit 0
fi
printf '%s %s\n' "$version" "$*" >>"$FAKE_AGENTD_LOG"
case "$1" in
  version) echo "$version" ;;
  setup)
    [[ "$*" == *'--no-pair --json'* ]]
    path="$HOME/.config/mimi-remote/config.json"
    [[ ! -e "$path" ]]
    mkdir -p "${path%/*}"
    printf '{"auth":{"token":"%s"},"unknown":"preserve"}\n' "$TEST_SECRET" >"$path"
    chmod 600 "$path"
    printf 'Token：%s\n' "$TEST_SECRET"
    ;;
  check-config)
    [[ "$2" == --config && "$3" != "$HOME/.config/mimi-remote/config.json" && -s "$3" ]]
    [[ "${FAKE_INCOMPATIBLE_VERSION:-}" != "$version" ]]
    ;;
  start|restart)
    [[ "$*" == "$1 --no-pair --wait 60s" ]]
    systemctl --user "$1" mimi-remote.service
    [[ "${FAKE_FAIL_RESTORED_VERSION:-}" != "$version" ]] || exit 19
    [[ "$healthy" == true ]] || exit 18
    echo '{"service_ok":true,"ok":true}'
    ;;
  status)
    if [[ "${2:-}" == "--pairing" ]]; then
      case "${FAKE_STATUS_PAIRING_MODE:-unavailable}" in
        fail)
          echo "flag provided but not defined: -pairing" >&2
          exit 2
          ;;
        ready)
          echo "配对：可用，运行 agentd pair --qr-only"
          ;;
        tailcat_ready)
          echo "配对：可用，运行 agentd tailcat pair --qr-only"
          ;;
        *)
          cat <<'EOF'
配对：暂不可用
  - 没有可用助手（至少需要一个已安装并登录的助手，例如 Codex 或 Claude Code）
    修复：安装并登录 Codex（codex login）或 Claude Code 后，运行 agentd runtime --codex=enabled && agentd restart --no-pair
  - 没有可达的手机连接方式
    修复：同一局域网：agentd network --lan-enabled=true && agentd restart --no-pair；Tailscale：agentd network --tailscale-enabled=true && agentd restart --no-pair；联网时也可用 Tailcat：agentd tailcat enable 后运行 agentd tailcat pair
EOF
          ;;
      esac
      exit 0
    fi
    if [[ "$healthy" == true ]]; then
      echo '{"service_ok":true,"doctor_ok":false}'
    else
      printf '{"service_ok":false,"doctor_ok":false,"service_error":"token=%s core unavailable"}\n' "$TEST_SECRET"
      printf 'status authorization=Bearer %s\n' "$TEST_SECRET" >&2
    fi
    ;;
  pair)
    [[ "$*" == 'pair --qr-only' ]]
    if [[ "${FAKE_PAIR_FAIL:-0}" == 1 ]]; then exit 9; fi
    echo "短期配对二维码已就绪（${version}）"
    ;;
  tailcat)
    [[ "$*" == 'tailcat pair --qr-only' ]]
    if [[ "${FAKE_TAILCAT_PAIR_FAIL:-0}" == 1 ]]; then exit 11; fi
    echo "Tailcat 短期配对二维码已就绪（${version}）"
    ;;
  *) echo "fake agentd 不支持：$1" >&2; exit 2 ;;
esac
SH
  cat >"$destination/mimi-tailcat-experiment" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" == version ]] || exit 2
echo "$version"
SH
  chmod +x "$destination/agentd" "$destination/mimi-tailcat-experiment"
}

assert_version() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$("$path" version)"
  [[ "$actual" == "$expected" ]] || {
    echo "版本断言失败：$path actual=$actual expected=$expected" >&2
    exit 1
  }
}

release_123="$TEST_DIR/release-1.2.3"
release_124="$TEST_DIR/release-1.2.4"
release_125_bad="$TEST_DIR/release-1.2.5-bad"
make_release "$release_123" "1.2.3" "true"
make_release "$release_124" "1.2.4" "true"
make_release "$release_125_bad" "1.2.5" "false"

# 只读预检必须在创建安装目录、替换二进制或调用 systemd 前失败。
preflight_failure_home="$TEST_DIR/preflight-failure-home"
preflight_failure_state="$TEST_DIR/preflight-failure-state"
mkdir -p "$preflight_failure_home" "$preflight_failure_state"
printf 'authorization=Bearer %s\n' "$TEST_SECRET" >"$release_123/fail-preflight"
set +e
preflight_failure_output="$(
  HOME="$preflight_failure_home" \
    FAKE_SYSTEMCTL_ENABLED="$preflight_failure_state/enabled" \
    FAKE_SYSTEMCTL_ACTIVE="$preflight_failure_state/active" \
    FAKE_SYSTEMCTL_LOG="$preflight_failure_state/systemctl.log" \
    FAKE_AGENTD_LOG="$preflight_failure_state/agentd.log" \
    bash "$release_123/scripts/install-linux.sh" install 2>&1
)"
preflight_failure_status=$?
set -e
[[ "$preflight_failure_status" -ne 0 ]] || {
  echo "隔离预检失败没有阻止安装。" >&2
  exit 1
}
grep -Fq '安装包隔离预检失败' <<<"$preflight_failure_output"
rm "$release_123/fail-preflight"
if grep -Fq "$TEST_SECRET" <<<"$preflight_failure_output"; then
  echo "隔离预检失败诊断泄漏了测试 Token。" >&2
  exit 1
fi
[[ ! -e "$preflight_failure_home/.local/bin/agentd" ]]
[[ ! -e "$preflight_failure_home/.config/systemd/user/mimi-remote.service" ]]
[[ ! -s "$preflight_failure_state/systemctl.log" ]]

unset AGENTD_APP_SERVER_SSH_TARGET

# 首次安装失败必须移除两个新二进制及 unit，不留下半套安装。
if bash "$release_125_bad/scripts/install-linux.sh" install >"$TEST_DIR/first-failure.log" 2>&1; then
  echo '首次安装失败没有中止事务。' >&2
  exit 1
fi
[[ ! -e "$HOME/.local/bin/agentd" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment" ]]
[[ ! -e "$HOME/.local/bin/agentd.previous" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment.previous" ]]
[[ ! -e "$HOME/.config/systemd/user/mimi-remote.service" ]]
[[ ! -e "$FAKE_SYSTEMCTL_ACTIVE" ]]
[[ ! -e "$FAKE_SYSTEMCTL_ENABLED" ]]
# 首次启动失败保留身份，再次安装必须复用同一配置。
cp "$HOME/.config/mimi-remote/config.json" "$TEST_DIR/committed-config"
grep -Fq "$TEST_SECRET" "$TEST_DIR/committed-config"
: > "$FAKE_AGENTD_LOG"

install_output="$(bash "$release_123/scripts/install-linux.sh" install 2>&1)"
[[ "$install_output" != *'短期配对二维码已就绪'* ]]
cmp "$TEST_DIR/committed-config" "$HOME/.config/mimi-remote/config.json"
grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' <<<"$install_output"
grep -Fq "状态：\"$HOME/.local/bin/agentd\" status" <<<"$install_output"
grep -Fq '配对：暂不可用' <<<"$install_output"
grep -Fq '没有可用助手' <<<"$install_output"
grep -Fq '没有可达的手机连接方式' <<<"$install_output"
if grep -Fq "配对：\"$HOME/.local/bin/agentd\" pair --qr-only" <<<"$install_output"; then
  echo "全新离线安装不应无条件输出旧的直接配对提示。" >&2
  exit 1
fi
if grep -Fq "$TEST_SECRET" <<<"$install_output"; then
  echo "首次 setup 或安全配对输出泄漏了长期 Token。" >&2
  exit 1
fi
agentd_commands="$(<"$FAKE_AGENTD_LOG")"
[[ "$agentd_commands" != *'--app-server-ssh-target'* ]] || {
  echo "Linux 本机安装不应向 setup 传递 SSH target：$agentd_commands" >&2
  exit 1
}
[[ "$agentd_commands" == *'1.2.3 start --no-pair --wait 60s'* ]]
[[ "$agentd_commands" != *'1.2.3 pair '* && "$agentd_commands" != *'1.2.3 setup '* && "$agentd_commands" != *' doctor '* ]]
assert_version "$HOME/.local/bin/agentd" "1.2.3"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.3"
[[ -f "$HOME/.config/systemd/user/mimi-remote.service" ]]
[[ -f "$HOME/.config/mimi-remote/config.json" ]]
[[ -f "$FAKE_SYSTEMCTL_ACTIVE" ]]

# 配对属于事务提交后的交互步骤；失败时安装必须保持成功，不能删除已就绪服务。
pair_failure_home="$TEST_DIR/pair-failure-home"
pair_failure_state="$TEST_DIR/pair-failure-state"
mkdir -p "$pair_failure_home" "$pair_failure_state"
set +e
pair_failure_output="$(
  HOME="$pair_failure_home" \
    FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
    FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" \
    FAKE_SYSTEMCTL_LOG="$pair_failure_state/systemctl.log" \
    FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
    AGENTD_APP_SERVER_SSH_TARGET=linux-share-host \
    FAKE_PAIR_FAIL=1 \
    bash "$release_123/scripts/install-linux.sh" install --pair 2>&1
)"
pair_failure_status=$?
set -e
[[ "$pair_failure_status" -eq 0 ]] || {
  echo "pair 失败不应把已成功安装回滚：$pair_failure_output" >&2
  exit 1
}
grep -Fq "服务已安装并就绪，但暂时无法生成配对信息" <<<"$pair_failure_output"
assert_version "$pair_failure_home/.local/bin/agentd" "1.2.3"
[[ -f "$pair_failure_state/active" ]]
grep -Fq 'setup --no-pair --json --app-server-ssh-target linux-share-host' "$pair_failure_state/agentd.log"
[[ "$(grep -c '1.2.3 setup ' "$pair_failure_state/agentd.log")" == 1 ]]
[[ "$(grep -c 'start mimi-remote.service' "$pair_failure_state/systemctl.log")" == 1 ]]
[[ "$(cat "$pair_failure_state/agentd.log")" == *$'start --no-pair --wait 60s\n1.2.3 status --pairing\n1.2.3 pair --qr-only'* ]]
[[ "$pair_failure_output" != *"$TEST_SECRET"* ]]

# status --pairing 返回可用状态时，安装器原样输出。
ready_hint_output="$(
  HOME="$pair_failure_home" \
    FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
    FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" \
    FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
    FAKE_STATUS_PAIRING_MODE=ready \
    bash "$release_123/scripts/install-linux.sh" upgrade 2>&1
)"
grep -Fqx '配对：可用，运行 agentd pair --qr-only' <<<"$ready_hint_output"

# 旧版本不支持 status --pairing 时，安装器必须回退到静态提示且不能回滚或失败。
fallback_hint_output="$(
  HOME="$pair_failure_home" \
    FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
    FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" \
    FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
    FAKE_STATUS_PAIRING_MODE=fail \
    bash "$release_123/scripts/install-linux.sh" upgrade 2>&1
)"
grep -Fqx '配对需要：至少一个可用助手（Codex 已安装并登录）+ 同一局域网或 Tailscale（联网时也可用 Tailcat）。检查：agentd status' <<<"$fallback_hint_output"
if grep -Fq 'flag provided but not defined' <<<"$fallback_hint_output"; then
  echo "status --pairing 失败回退不应把旧版参数错误泄露到输出。" >&2
  exit 1
fi
assert_version "$pair_failure_home/.local/bin/agentd" "1.2.3"
[[ -f "$pair_failure_state/active" ]]

success_pair="$(HOME="$pair_failure_home" FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
  FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
  bash "$release_123/scripts/install-linux.sh" install --pair 2>&1)"
grep -Fq '短期配对二维码已就绪（1.2.3）' <<<"$success_pair"
[[ "$success_pair" != *"$TEST_SECRET"* ]]

# 仅 Tailcat 可用时，--pair 必须调用 tailcat pair --qr-only，且失败重试提示也指向 tailcat pair。
: >"$pair_failure_state/agentd.log"
tailcat_pair_ok="$(
  HOME="$pair_failure_home" \
    FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
    FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" \
    FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
    FAKE_STATUS_PAIRING_MODE=tailcat_ready \
    bash "$release_123/scripts/install-linux.sh" upgrade --pair 2>&1
)"
grep -Fq '配对：可用，运行 agentd tailcat pair --qr-only' <<<"$tailcat_pair_ok"
grep -Fq 'Tailcat 短期配对二维码已就绪（1.2.3）' <<<"$tailcat_pair_ok"
grep -Fq '1.2.3 tailcat pair --qr-only' "$pair_failure_state/agentd.log"
if grep -Fq '1.2.3 pair --qr-only' "$pair_failure_state/agentd.log"; then
  echo "仅 Tailcat 可用时 --pair 不应调用直连 pair --qr-only。" >&2
  exit 1
fi

: >"$pair_failure_state/agentd.log"
tailcat_pair_fail="$(
  HOME="$pair_failure_home" \
    FAKE_AGENTD_LOG="$pair_failure_state/agentd.log" \
    FAKE_SYSTEMCTL_ACTIVE="$pair_failure_state/active" \
    FAKE_SYSTEMCTL_ENABLED="$pair_failure_state/enabled" \
    FAKE_STATUS_PAIRING_MODE=tailcat_ready \
    FAKE_TAILCAT_PAIR_FAIL=1 \
    bash "$release_123/scripts/install-linux.sh" upgrade --pair 2>&1
)"
grep -Fq "请重试：\"$pair_failure_home/.local/bin/agentd\" tailcat pair --qr-only" <<<"$tailcat_pair_fail"
if grep -Fq "请重试：\"$pair_failure_home/.local/bin/agentd\" pair --qr-only" <<<"$tailcat_pair_fail"; then
  echo "Tailcat --pair 失败时重试提示不应指向直连 pair --qr-only。" >&2
  exit 1
fi

bash "$release_124/scripts/install-linux.sh" upgrade >/dev/null
assert_version "$HOME/.local/bin/agentd" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.4"
assert_version "$HOME/.local/bin/agentd.previous" "1.2.3"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.3"

bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback >/dev/null
assert_version "$HOME/.local/bin/agentd" "1.2.3"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.3"
assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"

set +e
failure_output="$(bash "$release_125_bad/scripts/install-linux.sh" upgrade 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || {
  echo "失败升级没有返回非零状态。" >&2
  exit 1
}
grep -Fq '正在恢复安装前版本' <<<"$failure_output"
grep -Fq '就绪检查失败，最后一次去敏状态摘要' <<<"$failure_output"
grep -Fq '"service_ok":false' <<<"$failure_output"
grep -Fq 'codex app-server failed: <redacted>' <<<"$failure_output"
grep -Fq 'journal-line-80' <<<"$failure_output"
if grep -Fq 'journal-line-81' <<<"$failure_output"; then
  echo "journalctl 诊断超过 80 行边界。" >&2
  exit 1
fi
if grep -Fq "$TEST_SECRET" <<<"$failure_output"; then
  echo "失败诊断泄漏了测试 Token。" >&2
  exit 1
fi
grep -Fq -- '--user -u mimi-remote.service -n 80 --no-pager' "$FAKE_JOURNALCTL_LOG"
assert_version "$HOME/.local/bin/agentd" "1.2.3"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.3"
[[ -f "$FAKE_SYSTEMCTL_ACTIVE" ]]

cmp "$TEST_DIR/committed-config" "$HOME/.config/mimi-remote/config.json"
if grep -q ' setup ' "$FAKE_AGENTD_LOG"; then exit 1; fi

# 失败升级也不能覆盖之前的回滚目标。
assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"

grep -Fq 'restart mimi-remote.service' "$FAKE_SYSTEMCTL_LOG"

# 恢复的二进制读不到当前配置时停止服务并保留身份与回滚备份。
if FAKE_INCOMPATIBLE_VERSION=1.2.3 bash "$release_125_bad/scripts/install-linux.sh" upgrade >"$TEST_DIR/recovery.log" 2>&1; then exit 1; fi
grep -Fq '配置恢复需要人工处理' "$TEST_DIR/recovery.log"
[[ ! -e "$FAKE_SYSTEMCTL_ACTIVE" && ! -e "$FAKE_SYSTEMCTL_ENABLED" ]]
cmp "$TEST_DIR/committed-config" "$HOME/.config/mimi-remote/config.json"
assert_version "$HOME/.local/bin/agentd" 1.2.3
assert_version "$HOME/.local/bin/agentd.previous" 1.2.4
systemctl --user enable mimi-remote.service
systemctl --user start mimi-remote.service

if FAKE_FAIL_RESTORED_VERSION=1.2.3 bash "$release_125_bad/scripts/install-linux.sh" upgrade >"$TEST_DIR/failed-restart.log" 2>&1; then exit 1; fi
grep -Fq '恢复的后台服务未就绪' "$TEST_DIR/failed-restart.log"
[[ ! -e "$FAKE_SYSTEMCTL_ACTIVE" && ! -e "$FAKE_SYSTEMCTL_ENABLED" ]]
cmp "$TEST_DIR/committed-config" "$HOME/.config/mimi-remote/config.json"

(
  exec 9>>"$HOME/.local/share/mimi-remote/installer.lock"
  flock -n 9
  if bash "$release_124/scripts/install-linux.sh" upgrade >"$TEST_DIR/locked.log" 2>&1; then exit 1; fi
)
grep -Fq '另一个安装或恢复操作' "$TEST_DIR/locked.log"
systemctl --user enable mimi-remote.service
systemctl --user start mimi-remote.service

# 不完整、不可执行、版本错配的 Release 必须在改安装或调用 systemd 前被拒绝。
for broken in missing permission mismatch exec; do
  release_broken="$TEST_DIR/release-$broken"
  make_release "$release_broken" "1.2.6" "true"
  case "$broken" in
    missing) rm "$release_broken/mimi-tailcat-experiment" ;;
    permission) chmod -x "$release_broken/mimi-tailcat-experiment" ;;
    mismatch) cp "$release_124/mimi-tailcat-experiment" "$release_broken/mimi-tailcat-experiment" ;;
    exec) printf '#!/usr/bin/env bash\nexit 17\n' > "$release_broken/mimi-tailcat-experiment" ;;
  esac
  cp "$FAKE_SYSTEMCTL_LOG" "$TEST_DIR/systemctl.before"
  if bash "$release_broken/scripts/install-linux.sh" upgrade >"$TEST_DIR/broken.log" 2>&1; then
    echo "错误的 Tailcat Release 未拒绝：$broken" >&2
    exit 1
  fi
  cmp "$FAKE_SYSTEMCTL_LOG" "$TEST_DIR/systemctl.before"
  assert_version "$HOME/.local/bin/agentd" "1.2.3"
  assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.3"
  assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"
  assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"
done

# 在第二个二进制落盘时失败，要同时恢复当前安装与上一版备份。
real_mv="$(command -v mv)"
export REAL_MV="$real_mv"
cat >"$TEST_DIR/bin/mv" <<'SH'
#!/usr/bin/env bash
if [[ "${FAKE_FAIL_TAILCAT_RENAME:-0}" == 1 && "${2:-}" == *'/mimi-tailcat-experiment.new.'* ]]; then
  exit 43
fi
if [[ "${FAKE_FAIL_RESTORE_RENAME:-0}" == 1 && "${2:-}" == *'/agentd.restore.'* ]]; then
  exit 44
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$TEST_DIR/bin/mv"
if FAKE_FAIL_TAILCAT_RENAME=1 bash "$release_124/scripts/install-linux.sh" upgrade >"$TEST_DIR/rename.log" 2>&1; then
  echo 'Tailcat 替换失败没有中止事务。' >&2
  exit 1
fi
assert_version "$HOME/.local/bin/agentd" "1.2.3"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.3"
assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"

# A failed restore leaves the original payloads for recovery and must not
# restart the mixed installation.
: >"$FAKE_AGENTD_LOG"
if FAKE_FAIL_RESTORE_RENAME=1 bash "$release_125_bad/scripts/install-linux.sh" upgrade >"$TEST_DIR/restore.log" 2>&1; then
  exit 1
fi
grep -Fq '自动恢复未完成' "$TEST_DIR/restore.log"
recovery_dir="$(sed -n 's/^自动恢复未完成.*：//p' "$TEST_DIR/restore.log")"
cmp "$release_123/agentd" "$recovery_dir/before-0"
cmp "$release_123/mimi-tailcat-experiment" "$recovery_dir/before-1"
[[ ! -e "$FAKE_SYSTEMCTL_ACTIVE" && ! -e "$FAKE_SYSTEMCTL_ENABLED" ]]
[[ "$(grep -c ' restart ' "$FAKE_AGENTD_LOG")" == 1 ]]
cmp "$TEST_DIR/committed-config" "$HOME/.config/mimi-remote/config.json"
bash "$release_123/scripts/install-linux.sh" upgrade >/dev/null
# Restore the earlier rollback target for the subsequent scenarios.
cp "$recovery_dir/before-3" "$HOME/.local/bin/agentd.previous"
cp "$recovery_dir/before-4" "$HOME/.local/bin/mimi-tailcat-experiment.previous"

# 从旧的无 sidecar 安装升级，失败时仍无 sidecar，成功后可回到确切的旧状态。
rm "$HOME/.local/bin/mimi-tailcat-experiment"
if bash "$release_125_bad/scripts/install-linux.sh" upgrade >"$TEST_DIR/legacy-failure.log" 2>&1; then
  exit 1
fi
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment" ]]
assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"
bash "$release_124/scripts/install-linux.sh" upgrade >/dev/null
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.4"
[[ -f "$HOME/.local/bin/mimi-tailcat-experiment.previous.absent" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment.previous" ]]
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback >"$TEST_DIR/legacy-rollback.log"
grep -Fq '已恢复未包含 Tailcat 的旧安装' "$TEST_DIR/legacy-rollback.log"
assert_version "$HOME/.local/bin/agentd" "1.2.3"
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment" ]]
assert_version "$HOME/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment.previous.absent" ]]
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback >/dev/null
assert_version "$HOME/.local/bin/agentd" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.4"

# 没有 absent 标记的丢失备份不能被误认为合法旧安装。
rm "$HOME/.local/bin/mimi-tailcat-experiment.previous.absent"
if bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback >"$TEST_DIR/incomplete-backup.log" 2>&1; then
  exit 1
fi
grep -Fq '上一版 Tailcat 备份不完整' "$TEST_DIR/incomplete-backup.log"
assert_version "$HOME/.local/bin/agentd" "1.2.4"
assert_version "$HOME/.local/bin/mimi-tailcat-experiment" "1.2.4"


# stop/disable 任一失败都必须在删除安装文件前中止。
for failure in stop disable; do
  failure_home="$TEST_DIR/uninstall-${failure}-home"
  failure_state="$TEST_DIR/uninstall-${failure}-state"
  mkdir -p \
    "$failure_home/.local/bin" \
    "$failure_home/.local/share/mimi-remote" \
    "$failure_home/.config/systemd/user" \
    "$failure_home/.config/mimi-remote" \
    "$failure_state"
  cp "$release_123/agentd" "$failure_home/.local/bin/agentd"
  cp "$release_123/mimi-tailcat-experiment" "$failure_home/.local/bin/mimi-tailcat-experiment"
  cp "$release_124/mimi-tailcat-experiment" "$failure_home/.local/bin/mimi-tailcat-experiment.previous"
  cp "$release_124/agentd" "$failure_home/.local/bin/agentd.previous"
  cp "$release_123/packaging/systemd/mimi-remote.service" \
    "$failure_home/.config/systemd/user/mimi-remote.service"
  cp "$release_124/packaging/systemd/mimi-remote.service" \
    "$failure_home/.config/systemd/user/mimi-remote.service.previous"
  cp "$release_123/scripts/install-linux.sh" \
    "$failure_home/.local/share/mimi-remote/install-linux.sh"
  printf '%s\n' 'keep-config' >"$failure_home/.config/mimi-remote/config.json"
  : >"$failure_state/enabled"
  : >"$failure_state/active"

  fail_stop="0"
  fail_disable="0"
  if [[ "$failure" == "stop" ]]; then
    fail_stop="1"
  else
    fail_disable="1"
  fi
  set +e
  failure_output="$(
    HOME="$failure_home" \
      FAKE_SYSTEMCTL_ENABLED="$failure_state/enabled" \
      FAKE_SYSTEMCTL_ACTIVE="$failure_state/active" \
      FAKE_SYSTEMCTL_LOG="$failure_state/systemctl.log" \
      FAKE_SYSTEMCTL_FAIL_STOP="$fail_stop" \
      FAKE_SYSTEMCTL_FAIL_DISABLE="$fail_disable" \
      bash "$release_123/scripts/install-linux.sh" uninstall 2>&1
  )"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || {
    echo "uninstall ${failure} 失败没有返回非零状态。" >&2
    exit 1
  }
  grep -Fq "${failure}" "$failure_state/systemctl.log"
  grep -Fq '未删除任何安装文件' <<<"$failure_output"
  [[ -x "$failure_home/.local/bin/agentd" ]]
  [[ -x "$failure_home/.local/bin/agentd.previous" ]]
  assert_version "$failure_home/.local/bin/mimi-tailcat-experiment" "1.2.3"
  assert_version "$failure_home/.local/bin/mimi-tailcat-experiment.previous" "1.2.4"
  [[ -f "$failure_home/.config/systemd/user/mimi-remote.service" ]]
  [[ -f "$failure_home/.config/systemd/user/mimi-remote.service.previous" ]]
  [[ -f "$failure_home/.local/share/mimi-remote/install-linux.sh" ]]
  [[ "$(<"$failure_home/.config/mimi-remote/config.json")" == "keep-config" ]]
done

# 正常卸载先停用 user service，删除当前/上一版安装文件，但完整保留配置目录。
printf '%s\n' "$TEST_SECRET" >"$HOME/.config/mimi-remote/app-server-ws-token"
mkdir -p "$HOME/.config/mimi-remote/local-state"
printf '%s\n' 'keep-local-state' >"$HOME/.config/mimi-remote/local-state/state.json"
uninstall_output="$(bash "$HOME/.local/share/mimi-remote/install-linux.sh" uninstall 2>&1)"
grep -Fq 'Mimi Remote Linux uninstall 完成' <<<"$uninstall_output"
grep -Fq "已保留配置和 Token：$HOME/.config/mimi-remote" <<<"$uninstall_output"
grep -Fq 'rm -rf -- "$HOME/.config/mimi-remote"' <<<"$uninstall_output"
[[ ! -e "$HOME/.local/bin/agentd" ]]
[[ ! -e "$HOME/.local/bin/agentd.previous" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment.previous" ]]
[[ ! -e "$HOME/.local/bin/mimi-tailcat-experiment.previous.absent" ]]
[[ ! -e "$HOME/.config/systemd/user/mimi-remote.service" ]]
[[ ! -e "$HOME/.config/systemd/user/mimi-remote.service.previous" ]]
[[ ! -e "$HOME/.local/share/mimi-remote/install-linux.sh" ]]
[[ ! -e "$FAKE_SYSTEMCTL_ACTIVE" ]]
[[ ! -e "$FAKE_SYSTEMCTL_ENABLED" ]]
[[ -f "$HOME/.config/mimi-remote/config.json" ]]
[[ "$(<"$HOME/.config/mimi-remote/app-server-ws-token")" == "$TEST_SECRET" ]]
[[ "$(<"$HOME/.config/mimi-remote/local-state/state.json")" == "keep-local-state" ]]
grep -Fq 'stop mimi-remote.service' "$FAKE_SYSTEMCTL_LOG"
grep -Fq 'disable mimi-remote.service' "$FAKE_SYSTEMCTL_LOG"
grep -Fq 'daemon-reload' "$FAKE_SYSTEMCTL_LOG"

# helper 已删除时仍可从 Release 包再运行，无安装文件应幂等成功。
second_uninstall_output="$(bash "$release_123/scripts/install-linux.sh" uninstall 2>&1)"
grep -Fq '已处于未安装状态' <<<"$second_uninstall_output"
grep -Fq "已保留配置和 Token：$HOME/.config/mimi-remote" <<<"$second_uninstall_output"
[[ -f "$HOME/.config/mimi-remote/config.json" ]]
[[ "$(<"$HOME/.config/mimi-remote/app-server-ws-token")" == "$TEST_SECRET" ]]

# 验证 packaging/systemd/mimi-remote.service 中 ExecStartPre 的 POSIX 语法与非阻断暂存绑定校验（#1163）。
service_template="$ROOT_DIR/packaging/systemd/mimi-remote.service"
grep -Fqx 'BindPaths=-%t/mimi-remote/codex-daemon:/tmp/codex-daemon-%U' "$service_template" || {
  echo "systemd unit 缺少通过已校验暂存链接绑定的 BindPaths=-%t/mimi-remote/codex-daemon:/tmp/codex-daemon-%U。" >&2
  exit 1
}
exec_pre_raw="$(awk '/^ExecStartPre=/{ sub(/^ExecStartPre=/, ""); print; exit }' "$service_template")"
[[ "$exec_pre_raw" == "-+/bin/sh -c '"*"'" ]] || {
  echo "systemd ExecStartPre 未使用不阻断启动的 -+/bin/sh -c 单引号形式：$exec_pre_raw" >&2
  exit 1
}
exec_pre_script="${exec_pre_raw#"-+/bin/sh -c '"}"
exec_pre_script="${exec_pre_script%"'"}"
# 还原 systemd 的 specifier 与环境变量转义（%U -> UID，%t -> XDG_RUNTIME_DIR，%% -> %，$$ -> $）。
exec_pre_expanded="$(python3 - "$exec_pre_script" <<'PY'
import sys
s = sys.argv[1]
s = s.replace("%%", "\x00PERCENT\x00").replace("%U", "1000").replace("%t", "/run/user/1000").replace("\x00PERCENT\x00", "%")
s = s.replace("$$", "$")
sys.stdout.write(s)
PY
)"
/bin/sh -n -c "$exec_pre_expanded"

python3_bin="$(command -v python3)"
printf '#!%s\n' "$python3_bin" >"$TEST_DIR/fake-stat"
cat >>"$TEST_DIR/fake-stat" <<'PY'
import os, stat, sys
# 仅实现 ExecStartPre 使用的 GNU/BusyBox stat -c %F:%u -- <path> 子集（基于 lstat）。
fmt = sys.argv[2]
path = sys.argv[4]
st = os.lstat(path)
mode = st.st_mode
if stat.S_ISLNK(mode):
    ftype = "symbolic link"
elif stat.S_ISDIR(mode):
    ftype = "directory"
elif stat.S_ISREG(mode):
    ftype = "regular file"
else:
    ftype = "other"
uid = os.environ.get("FAKE_STAT_UID", "1000")
print(fmt.replace("%F", ftype).replace("%u", uid))
PY
chmod +x "$TEST_DIR/fake-stat"

exec_pre_root="$TEST_DIR/codex-daemon-test"
runtime_root="$exec_pre_root/runtime"
mkdir -p "$exec_pre_root" "$runtime_root"
target_codex_dir="$exec_pre_root/codex-daemon-1000"
stage_link="$runtime_root/mimi-remote/codex-daemon"
unsafe_marker="$runtime_root/mimi-remote/codex-daemon.unsafe"
exec_pre_testable="$(python3 - "$exec_pre_expanded" "$target_codex_dir" "$runtime_root" "$TEST_DIR/fake-stat" <<'PY'
import sys
script, target, runtime_root, fake_stat = sys.argv[1:5]
script = script.replace("/tmp/codex-daemon-1000", target)
script = script.replace("/run/user/1000", runtime_root)
script = script.replace("/usr/bin/stat", fake_stat).replace("/bin/stat", fake_stat)
sys.stdout.write(script)
PY
)"

# 1. 目录不存在时，在空 PATH 下也能创建 0700 目录与暂存链接，且不写不安全标记。
PATH="" /bin/sh -c "$exec_pre_testable"
[[ -d "$target_codex_dir" && ! -L "$target_codex_dir" ]]
[[ "$(python3 -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o777))' "$target_codex_dir")" == "0o700" ]]
[[ -L "$stage_link" && "$(readlink "$stage_link")" == "$target_codex_dir" ]]
[[ ! -e "$unsafe_marker" ]]

# 2. 已存在且属主匹配但权限偏宽的目录，校验通过并收紧到 0700，保留暂存链接。
chmod 0755 "$target_codex_dir"
PATH="" /bin/sh -c "$exec_pre_testable"
[[ "$(python3 -c 'import os,sys; print(oct(os.lstat(sys.argv[1]).st_mode & 0o777))' "$target_codex_dir")" == "0o700" ]]
[[ -L "$stage_link" && "$(readlink "$stage_link")" == "$target_codex_dir" ]]
[[ ! -e "$unsafe_marker" ]]

# 3. 属主不是当前用户时必须失败、移除旧暂存链接（跳过 BindPaths）并写入不安全标记。
if wrong_owner_out="$(PATH="" FAKE_STAT_UID=2000 /bin/sh -c "$exec_pre_testable" 2>&1)"; then
  echo "ExecStartPre 未拒绝他人属主目录。" >&2
  exit 1
fi
grep -Fq 'expected directory:1000' <<<"$wrong_owner_out"
[[ ! -e "$stage_link" && ! -L "$stage_link" ]]
[[ -f "$unsafe_marker" ]]

# 4. 符号链接（即使指向合法目录或悬空链接）必须被拒绝，暂存链接保持缺失并写入不安全标记。
rmdir "$target_codex_dir"
mkdir -p "$exec_pre_root/real-target"
ln -s "$exec_pre_root/real-target" "$target_codex_dir"
if symlink_out="$(PATH="" /bin/sh -c "$exec_pre_testable" 2>&1)"; then
  echo "ExecStartPre 未拒绝符号链接。" >&2
  exit 1
fi
grep -Fq 'ignoring unsafe symlink' <<<"$symlink_out"
[[ ! -e "$stage_link" && ! -L "$stage_link" ]]
[[ -f "$unsafe_marker" ]]
rm "$target_codex_dir"

# 5. 非目录（普通文件）必须被拒绝，暂存链接保持缺失并写入不安全标记。
: >"$target_codex_dir"
if file_out="$(PATH="" /bin/sh -c "$exec_pre_testable" 2>&1)"; then
  echo "ExecStartPre 未拒绝普通文件。" >&2
  exit 1
fi
grep -Fq 'not a directory' <<<"$file_out"
[[ ! -e "$stage_link" && ! -L "$stage_link" ]]
[[ -f "$unsafe_marker" ]]

# 6. 清理占位并重新运行后，应自动清除不安全标记并恢复暂存链接。
rm -f "$target_codex_dir"
PATH="" /bin/sh -c "$exec_pre_testable"
[[ -L "$stage_link" && "$(readlink "$stage_link")" == "$target_codex_dir" ]]
[[ ! -e "$unsafe_marker" ]]

echo "Linux Release 安全配对、PATH 提示、去敏诊断、升级、回滚和安全卸载测试通过。"
