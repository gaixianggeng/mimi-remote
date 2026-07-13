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

make_release() {
  local destination="$1"
  local version="$2"
  local healthy="$3"
  mkdir -p "$destination/scripts" "$destination/packaging/systemd"
  cp "$ROOT_DIR/scripts/install-linux.sh" "$destination/scripts/install-linux.sh"
  cp "$ROOT_DIR/packaging/systemd/mimi-remote.service" \
    "$destination/packaging/systemd/mimi-remote.service"
  cat >"$destination/agentd" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$version" "\$*" >>"\$FAKE_AGENTD_LOG"
case "\${1:-}" in
  version)
    echo "$version"
    ;;
  setup)
    mkdir -p "\$HOME/.config/mimi-remote"
    printf '%s\n' '{"test":true}' >"\$HOME/.config/mimi-remote/config.json"
    printf 'Token：%s\n' "\$TEST_SECRET"
    printf '连接链接：mimiremote://connect?token=%s\n' "\$TEST_SECRET"
    ;;
  doctor)
    exit 0
    ;;
  status)
    if [[ "$healthy" == "true" ]]; then
      printf '%s\n' '{"service_ok":true,"doctor_ok":true}'
    else
      printf '{"service_ok":false,"doctor_ok":false,"service_error":"token=%s codex upstream unavailable"}\n' "\$TEST_SECRET"
      printf 'status authorization=Bearer %s\n' "\$TEST_SECRET" >&2
    fi
    ;;
  pair)
    if [[ "\${FAKE_PAIR_FAIL:-0}" == "1" ]]; then
      echo "fake pair 暂时失败" >&2
      exit 9
    fi
    if [[ "\${2:-}" != "--qr-only" ]]; then
      printf 'Token：%s\n' "\$TEST_SECRET"
      printf '连接链接：mimiremote://connect?token=%s\n' "\$TEST_SECRET"
    fi
    echo "短期配对二维码已就绪（${version}）"
    ;;
  *)
    echo "fake agentd 不支持：\${1:-}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$destination/agentd"
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

install_output="$(bash "$release_123/scripts/install-linux.sh" install 2>&1)"
grep -Fq '短期配对二维码已就绪（1.2.3）' <<<"$install_output"
grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' <<<"$install_output"
grep -Fq "状态：\"$HOME/.local/bin/agentd\" status" <<<"$install_output"
grep -Fq "配对：\"$HOME/.local/bin/agentd\" pair --qr-only" <<<"$install_output"
if grep -Fq "$TEST_SECRET" <<<"$install_output"; then
  echo "首次 setup 或安全配对输出泄漏了长期 Token。" >&2
  exit 1
fi
agentd_commands="$(<"$FAKE_AGENTD_LOG")"
[[ "$agentd_commands" == *$'1.2.3 status --json\n1.2.3 pair --qr-only'* ]] || {
  echo "首次配对必须在 readiness 成功后使用 --qr-only：$agentd_commands" >&2
  exit 1
}
assert_version "$HOME/.local/bin/agentd" "1.2.3"
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
    FAKE_PAIR_FAIL=1 \
    bash "$release_123/scripts/install-linux.sh" install 2>&1
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

bash "$release_124/scripts/install-linux.sh" upgrade >/dev/null
assert_version "$HOME/.local/bin/agentd" "1.2.4"
assert_version "$HOME/.local/bin/agentd.previous" "1.2.3"

bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback >/dev/null
assert_version "$HOME/.local/bin/agentd" "1.2.3"
assert_version "$HOME/.local/bin/agentd.previous" "1.2.4"

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
[[ -f "$FAKE_SYSTEMCTL_ACTIVE" ]]

grep -Fq 'restart mimi-remote.service' "$FAKE_SYSTEMCTL_LOG"

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

echo "Linux Release 安全配对、PATH 提示、去敏诊断、升级、回滚和安全卸载测试通过。"
