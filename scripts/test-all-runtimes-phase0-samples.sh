#!/usr/bin/env bash
# 定向校验全部运行时 Phase 0 脱敏现网实录：
# 1) 校验 manifest 与 JSON 结构完整、标明基线提交与组件版本；
# 2) 校验脱敏边界（不含真实用户名主目录、疑似 Token/私钥或 Tailscale 地址）；
# 3) 断言 accepted 组 100% 接受且覆盖四项必选现网特征；
# 4) 断言 malformed 组 100% 显式拒绝并命中预期原因码。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/scripts/testdata/all-runtimes-phase0"

python3 - "$FIXTURE_DIR" <<'PY'
from __future__ import annotations
import base64
import json
import pathlib
import re
import sys

fixture_dir = pathlib.Path(sys.argv[1])
manifest_path = fixture_dir / "manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"缺少 manifest：{manifest_path}")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest.get("baselineCommit") == "2c6342fb", f"基线提交不匹配：{manifest.get('baselineCommit')}"
versions = manifest.get("componentVersions", {})
for required_key in (
    "go",
    "bun",
    "cargo",
    "codexCli",
    "claudeSdkAdapter",
    "claudeAgentSdk",
    "claudeLegacyRustBridge",
    "agyAcpAdapter",
):
    assert isinstance(versions.get(required_key), str) and versions[required_key].strip(), (
        f"缺少组件版本：{required_key}"
    )

# 脱敏扫描：覆盖整个夹具目录的 JSON 与 README
secret_re = re.compile(
    r"-----BEGIN (ENCRYPTED |RSA |EC |OPENSSH )?PRIVATE KEY-----"
    r"|github_pat_[A-Za-z0-9_]{40,}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}"
    r"|sk-(proj-)?[A-Za-z0-9_-]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|xox[baprs]-[A-Za-z0-9-]{20,}"
)
home_re = re.compile(r"/Users/(?!me/|you/|demo/)[A-Za-z0-9._-]+/|/home/(?!me/|user/|demo/)[A-Za-z0-9._-]+/")
tailscale_re = re.compile(r"100\.(?!64\.0\.0/10(?:[^0-9]|$))(6[4-9]|[78][0-9]|9[0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}")

for file_path in sorted(fixture_dir.rglob("*")):
    if not file_path.is_file():
        continue
    text = file_path.read_text(encoding="utf-8")
    rel = file_path.relative_to(fixture_dir)
    if secret_re.search(text):
        raise SystemExit(f"脱敏检查失败（疑似凭据）：{rel}")
    if home_re.search(text):
        raise SystemExit(f"脱敏检查失败（非脱敏主目录路径）：{rel}")
    if tailscale_re.search(text):
        raise SystemExit(f"脱敏检查失败（包含具体 Tailscale 地址）：{rel}")

MS_THRESHOLD = 10_000_000_000


def validate_appserver_page(response: dict) -> tuple[bool, str | None]:
    if not isinstance(response, dict):
        return False, "non_object_response"
    result = response.get("result")
    if not isinstance(result, dict):
        return False, "non_object_result"
    if "data" not in result or not isinstance(result["data"], list):
        return False, "non_array_data"
    if "nextCursor" not in result:
        return False, "missing_next_cursor_key"
    nc = result["nextCursor"]
    if nc is not None:
        if not isinstance(nc, str) or not nc.strip() or nc != nc.strip():
            return False, "invalid_next_cursor"

    seen_sec = False
    seen_ms = False
    for row in result["data"]:
        if not isinstance(row, dict):
            return False, "non_object_row"
        raw_id = row.get("id") or row.get("threadId") or row.get("sessionId")
        if not isinstance(raw_id, str) or not raw_id.strip() or raw_id != raw_id.strip():
            return False, "blank_thread_id"
        if "cwd" in row and row["cwd"] is not None:
            if not isinstance(row["cwd"], str):
                return False, "invalid_cwd_type"
            if row["cwd"] != "" and (row["cwd"] != row["cwd"].strip() or not row["cwd"].startswith("/")):
                return False, "invalid_cwd_path"
        for ts_field in ("createdAt", "updatedAt"):
            ts_val = row.get(ts_field)
            if isinstance(ts_val, (int, float)) and not isinstance(ts_val, bool) and ts_val > 0:
                if ts_val >= MS_THRESHOLD:
                    seen_ms = True
                else:
                    seen_sec = True
    if seen_sec and seen_ms:
        return False, "mixed_timestamp_units"
    return True, None


def validate_deepseek_snapshot(response: dict) -> tuple[bool, str | None]:
    if not isinstance(response, dict) or not isinstance(response.get("items"), list):
        return False, "non_array_items"
    prev_ts = None
    for item in response["items"]:
        if not isinstance(item, dict):
            return False, "non_object_item"
        sid = item.get("sessionId")
        cwd = item.get("cwd")
        ts = item.get("updatedAt")
        if not isinstance(sid, str) or not sid.strip():
            return False, "blank_session_id"
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            return False, "invalid_cwd"
        if not isinstance(ts, int) or ts < MS_THRESHOLD:
            return False, "expected_ms_timestamp"
        if prev_ts is not None and ts > prev_ts:
            return False, "not_descending"
        prev_ts = ts
    return True, None


accepted_files = manifest.get("accepted", [])
malformed_files = manifest.get("malformed", [])
assert accepted_files, "accepted 列表不能为空"
assert malformed_files, "malformed 列表不能为空"

coverage = {
    "unmarked_same_page_retry": False,
    "claude_sdk_empty_cwd": False,
    "rust_claude_ms": False,
    "codex_recency_null": False,
    "agy_current_no_list_meta": False,
    "deepseek_ms_snapshot": False,
}

for rel in accepted_files:
    doc = json.loads((fixture_dir / rel).read_text(encoding="utf-8"))
    assert doc.get("category") == "accepted", f"{rel} category 不是 accepted"
    assert doc.get("baselineCommit") == "2c6342fb", f"{rel} baselineCommit 不匹配"
    if doc.get("runtimeProvider") == "deepseek":
        ok, reason = validate_deepseek_snapshot(doc["response"])
        assert ok, f"{rel} 校验失败：{reason}"
        coverage["deepseek_ms_snapshot"] = True
        continue

    responses = []
    if "response" in doc:
        responses.append(("single", doc["response"]))
    for ex in doc.get("exchanges", []):
        responses.append((ex["label"], ex["response"]))
    assert responses, f"{rel} 缺少 response/exchanges"

    for label, resp in responses:
        ok, reason = validate_appserver_page(resp)
        assert ok, f"{rel} ({label}) 校验失败：{reason}"

    sid = doc.get("sampleId")
    if sid == "gateway-global-unmarked-same-page-retry":
        r1 = doc["exchanges"][0]["response"]["result"]
        r2 = doc["exchanges"][1]["response"]["result"]
        assert "listMeta" not in r1 and "listMeta" not in r2
        assert isinstance(r1["nextCursor"], str) and r1["nextCursor"].startswith("mimi_")
        assert r2["nextCursor"] is None
        assert len(r2["data"]) > len(r1["data"])
        assert r2["data"][0]["updatedAt"] > r1["data"][0]["updatedAt"]
        assert all("cliVersion" not in row for row in r1["data"] + r2["data"])
        coverage["unmarked_same_page_retry"] = True
    elif sid == "claude-sdk-empty-cwd":
        rows = doc["response"]["result"]["data"]
        assert any(row["cwd"] == "" for row in rows), "缺少 cwd: \"\" 行"
        assert any(row["cwd"].startswith("/") for row in rows), "缺少正常 cwd 行"
        assert all(row["updatedAt"] < MS_THRESHOLD for row in rows)
        assert all(row["cliVersion"].startswith("mimi-claude-adapter/") for row in rows)
        coverage["claude_sdk_empty_cwd"] = True
    elif sid == "claude-legacy-rust-ms":
        p1 = doc["exchanges"][0]["response"]["result"]
        p2 = doc["exchanges"][1]["response"]["result"]
        all_rows = p1["data"] + p2["data"]
        assert all(row["updatedAt"] >= MS_THRESHOLD for row in all_rows)
        assert all(row["cliVersion"].startswith("alleycat-claude-bridge/") for row in all_rows)
        # 校验同毫秒 thread_id ASC 跨页切分
        assert p1["data"][1]["updatedAt"] == p2["data"][0]["updatedAt"]
        assert p1["data"][1]["id"] < p2["data"][0]["id"]
        padded = p1["nextCursor"] + "=" * (-len(p1["nextCursor"]) % 4)
        cursor_obj = json.loads(base64.urlsafe_b64decode(padded))
        assert cursor_obj["ts"] == p1["data"][1]["updatedAt"] and cursor_obj["id"] == p1["data"][1]["id"]
        coverage["rust_claude_ms"] = True
    elif sid == "codex-recency-at-null":
        r_null = doc["exchanges"][0]["response"]["result"]["data"]
        assert any(row.get("recencyAt") is None for row in r_null), "缺少 recencyAt: null 行"
        assert any(isinstance(row.get("recencyAt"), int) and row["recencyAt"] > 0 for row in r_null)
        assert all(row["updatedAt"] < MS_THRESHOLD for row in r_null)
        coverage["codex_recency_null"] = True
    elif sid == "agy-acp-current-list":
        res = doc["response"]["result"]
        assert "listMeta" not in res
        assert all(row["updatedAt"] < MS_THRESHOLD for row in res["data"])
        assert all(row["cliVersion"].startswith("mimi-agy-adapter/") for row in res["data"])
        coverage["agy_current_no_list_meta"] = True

missing_cov = [k for k, v in coverage.items() if not v]
assert not missing_cov, f"现网实录覆盖缺失：{missing_cov}"

for rel in malformed_files:
    doc = json.loads((fixture_dir / rel).read_text(encoding="utf-8"))
    assert doc.get("category") == "malformed", f"{rel} category 不是 malformed"
    expected_reason = doc.get("expectedRejectionReason")
    assert isinstance(expected_reason, str) and expected_reason
    ok, actual_reason = validate_appserver_page(doc["response"])
    assert not ok, f"畸形夹具 {rel} 应被拒绝，却意外通过"
    assert actual_reason == expected_reason, (
        f"畸形夹具 {rel} 拒绝原因不匹配：expected={expected_reason}, actual={actual_reason}"
    )

print(
    f"Phase 0 现网实录校验通过：accepted={len(accepted_files)}/{len(accepted_files)}, "
    f"malformed_rejected={len(malformed_files)}/{len(malformed_files)}, "
    f"coverage={len(coverage)}/{len(coverage)}, sanitization=clean"
)
PY
