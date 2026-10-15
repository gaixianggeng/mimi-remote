#!/usr/bin/env bash
# Stdio smoke: drives `alleycat-claude-bridge` against the real `claude`
# CLI over stdin/stdout. Run from the repo root:
#
#   ./crates/claude-bridge/tests/smoke/stdio_smoke.sh
#
# Requires: `claude` on $PATH, `jq`, `cargo`. Reports PASS/FAIL per
# scenario. Each scenario gets its own bridge subprocess via a fifo so
# stdin stays open while we wait for claude to respond (the bridge ends
# its read loop on stdin EOF, so we cannot just pipe in frames).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT"

if ! command -v claude >/dev/null 2>&1; then
  echo "FAIL: claude not on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq not on PATH" >&2
  exit 1
fi

cargo build -q -p alleycat-claude-bridge
BRIDGE_BIN="$ROOT/target/debug/alleycat-claude-bridge"
[ -x "$BRIDGE_BIN" ] || { echo "FAIL: bridge binary not at $BRIDGE_BIN"; exit 1; }
echo "bridge: $BRIDGE_BIN"

WORK="$(mktemp -d -t claude-bridge-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CODEX_HOME="$WORK/codex_home"
mkdir -p "$CODEX_HOME"

# Drive a scenario by running the bridge with stdin attached to a fifo
# we keep open. We write frames to the fifo and tail stdout for
# specific id-tagged responses or method-tagged notifications.
#
# Usage:
#   bridge_run <name> <max_secs> <send_proc> <assert_proc>
#
# `send_proc` is a function that receives the fifo path as $1 and the
# stdout file as $2 — it should write frames to $1 and may peek at $2
# to discover thread ids etc. It returns when it's done sending.
#
# `assert_proc` is a function that receives the stdout file and returns
# 0 iff the scenario passed.
bridge_run() {
  local name="$1" max_secs="$2" send_proc="$3" assert_proc="$4"
  echo "--- scenario: $name ---"
  local in_fifo="$WORK/$name.in" out="$WORK/$name.out" err="$WORK/$name.err"
  mkfifo "$in_fifo"
  # Start the bridge with the fifo as stdin. Hold the fifo open from
  # this shell so the bridge does not see EOF until we explicitly close.
  "$BRIDGE_BIN" <"$in_fifo" >"$out" 2>"$err" &
  local bridge_pid=$!
  exec 7>"$in_fifo"
  # Run the scenario's send proc, then close stdin → bridge exits.
  if ! timeout "$max_secs" bash -c "$send_proc \"$in_fifo\" \"$out\""; then
    echo "FAIL: $name — send proc timed out (>${max_secs}s)"
    kill -TERM "$bridge_pid" 2>/dev/null
    wait "$bridge_pid" 2>/dev/null
    exec 7>&-
    rm -f "$in_fifo"
    tail -10 "$err"
    return 1
  fi
  exec 7>&-
  wait "$bridge_pid" 2>/dev/null
  rm -f "$in_fifo"
  if "$assert_proc" "$out"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name — assertion failed; output sample:"
    head -30 "$out"
    return 1
  fi
}

# Wait until `out` contains a JSON line whose id matches `$1`. Echos the
# matching line to stdout. Polls every 250ms up to 90s.
wait_for_id() {
  local target_id="$1" out="$2" deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$out" ]; then
      local line
      line="$(jq -c "select(.id==$target_id)" <"$out" 2>/dev/null | head -1)"
      if [ -n "$line" ] && [ "$line" != "null" ]; then
        echo "$line"
        return 0
      fi
    fi
    sleep 0.25
  done
  return 1
}

# Send a JSON line into the fifo via fd 7 (kept open for the lifetime of
# the scenario by `bridge_run`).
send_frame() {
  printf '%s\n' "$1" >&7
}

# === scenarios ===============================================================

text_only_send() {
  local fifo="$1" out="$2"
  send_frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"smoke","version":"0.0.1"}}}'
  if ! wait_for_id 1 "$out" >/dev/null; then
    echo "    initialize never responded" >&2
    return 1
  fi
  send_frame '{"jsonrpc":"2.0","id":2,"method":"thread/start","params":{"cwd":"/tmp"}}'
  local start_resp thread_id
  start_resp="$(wait_for_id 2 "$out")" || { echo "    thread/start never responded" >&2; return 1; }
  thread_id="$(echo "$start_resp" | jq -r '.result.thread.id')"
  echo "    thread_id=$thread_id" >&2
  if [ -z "$thread_id" ] || [ "$thread_id" = "null" ]; then
    return 1
  fi
  printf '{"jsonrpc":"2.0","id":3,"method":"turn/start","params":{"sandboxPolicy":{"type":"dangerFullAccess"},"threadId":"%s","input":[{"type":"text","text":"reply with the single word: hi"}]}}\n' "$thread_id" >&7
  if ! wait_for_id 3 "$out" >/dev/null; then
    echo "    turn/start never responded" >&2
    return 1
  fi
  # Wait for turn/completed (notification, not a response).
  local deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if jq -e 'select(.method=="turn/completed")' <"$out" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "    turn/completed never arrived" >&2
  return 1
}

assert_turn_completed_with_text() {
  local out="$1"
  jq -e 'select(.method=="turn/completed")' <"$out" >/dev/null \
    && jq -e 'select(.method=="item/agentMessage/delta" or .method=="item/completed")' <"$out" >/dev/null
}

model_list_send() {
  local fifo="$1" out="$2"
  send_frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"smoke","version":"0.0.1"}}}'
  wait_for_id 1 "$out" >/dev/null || return 1
  send_frame '{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}'
  wait_for_id 2 "$out" >/dev/null || return 1
}

assert_model_list_nonempty() {
  local out="$1"
  jq -e 'select(.id==2) | (.result.data // .result.models // []) | length > 0' <"$out" >/dev/null
}

# Cold-cache `skills/list`: the bridge must respond quickly with an empty
# page rather than spawning a utility claude and waiting on its init line
# (regression guard for #15 — the old path deadlocked for ~30s).
skills_list_cold_send() {
  local fifo="$1" out="$2"
  send_frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"smoke","version":"0.0.1"}}}'
  wait_for_id 1 "$out" >/dev/null || return 1
  send_frame '{"jsonrpc":"2.0","id":2,"method":"skills/list","params":{"cwds":["/tmp"]}}'
  wait_for_id 2 "$out" >/dev/null || return 1
}

assert_skills_list_empty_cold() {
  local out="$1"
  jq -e 'select(.id==2)
           | .result.data
           | length == 1
           and (.[0].skills | length == 0)
           and (.[0].errors | length == 0)' <"$out" >/dev/null
}

export -f wait_for_id send_frame text_only_send model_list_send skills_list_cold_send

# Scenario 1: text-only turn (warm-spawn + claude round-trip).
bridge_run "text-only" 180 text_only_send assert_turn_completed_with_text || true

# Scenario 2: model/list (no claude spawn — pure dispatch).
bridge_run "model-list" 30 model_list_send assert_model_list_nonempty || true

# Scenario 3: skills/list cold (no prior turns) — must complete within a
# few seconds, not 30s. 10s budget is generous; a regression to spawn-and-
# wait-for-init would blow this immediately.
bridge_run "skills-list-cold" 10 skills_list_cold_send assert_skills_list_empty_cold || true

echo "--- done ---"
