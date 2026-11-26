#!/usr/bin/env bash
# 定向校验全部运行时 Phase 0 脱敏现网实录：
# 1) 校验 manifest 与 JSON 结构完整、标明基线提交与组件版本；
# 2) 校验脱敏边界（覆盖原文与解码后的 JSON 字符串/URL 编码，不含真实用户名主目录、疑似 Token/私钥或 Tailscale 地址）；
# 3) 断言 accepted 组 100% 接受且严格覆盖全部必选现网/协议特征（含游标连续性、显式 null/0、无分页裁剪快照与同秒 tie 排序）；
# 4) 断言 malformed 组 100% 显式拒绝并命中预期原因码（不依赖 Python assert，PYTHONOPTIMIZE=1 下仍严格生效）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/scripts/testdata/all-runtimes-phase0"

python3 - "$FIXTURE_DIR" <<'PY'
from __future__ import annotations
import base64
import ipaddress
import json
import pathlib
import re
import sys
import urllib.parse

fixture_dir = pathlib.Path(sys.argv[1])
manifest_path = fixture_dir / "manifest.json"


def require(cond: bool, message: str) -> None:
    if not cond:
        raise SystemExit(message)


def is_plain_int(value: object) -> bool:
    return type(value) is int


require(manifest_path.is_file(), f"缺少 manifest：{manifest_path}")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
require(manifest.get("baselineCommit") == "2c6342fb", f"基线提交不匹配：{manifest.get('baselineCommit')}")
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
    val = versions.get(required_key)
    require(isinstance(val, str) and bool(val.strip()), f"缺少组件版本：{required_key}")

# 脱敏扫描：覆盖整个夹具目录的原文与解码后的 JSON 字符串（含路径末尾无斜杠、URL 编码路径与 IPv4/IPv6 Tailscale 地址）
secret_re = re.compile(
    r"-----BEGIN (ENCRYPTED |RSA |EC |OPENSSH )?PRIVATE KEY-----"
    r"|github_pat_[A-Za-z0-9_]{40,}"
    r"|gh[pousr]_[A-Za-z0-9]{30,}"
    r"|sk-(proj-)?[A-Za-z0-9_-]{20,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|xox[baprs]-[A-Za-z0-9-]{20,}"
)
home_re = re.compile(
    r"/Users/(?!(?:me|you|demo)(?=/|$|[^A-Za-z0-9._-]))[A-Za-z0-9._-]+"
    r"|/home/(?!(?:me|user|demo)(?=/|$|[^A-Za-z0-9._-]))[A-Za-z0-9._-]+"
)
TAILSCALE_IPV4_NET = ipaddress.ip_network("100.64.0.0/10")
TAILSCALE_IPV6_NET = ipaddress.ip_network("fd7a:115c:a1e0::/48")
ipv4_candidate_re = re.compile(
    r"(?<![0-9])(?<!\d\.)(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2})(?![0-9A-Za-z/]))?(?![0-9]|\.[0-9])"
)
bracketed_ipv6_re = re.compile(
    r"\[([0-9A-Fa-f:.]+)(?:%[A-Za-z0-9._-]+)?\](?::(\d{1,5}))?"
)
unbracketed_ipv6_re = re.compile(
    r"(?:(?<![0-9A-Za-z])([0-9A-Fa-f]{1,4}:[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)|(?<![0-9A-Fa-f:])(::[0-9A-Fa-f:.]*))"
    r"(?:%[A-Za-z0-9._-]+)?(?:/(\d{1,3})(?![0-9A-Za-z/]))?(?![0-9A-Za-z])"
)


class SanitizationError(ValueError):
    pass


def decode_url_variants(text: str, max_rounds: int = 3) -> list[str]:
    variants = [text]
    cur = text
    for _ in range(max_rounds):
        nxt = urllib.parse.unquote(cur)
        if nxt == cur:
            break
        variants.append(nxt)
        cur = nxt
    return variants


def is_tailscale_ipv6(addr: ipaddress.IPv6Address, prefix_str: str | None = None) -> bool:
    if addr in TAILSCALE_IPV6_NET:
        if prefix_str == "48" and addr == TAILSCALE_IPV6_NET.network_address:
            return False
        return True
    mapped = addr.ipv4_mapped
    if mapped is not None and mapped in TAILSCALE_IPV4_NET:
        return True
    return False


def parse_ipv6_variants(raw: str) -> list[ipaddress.IPv6Address]:
    cleaned = raw.rstrip(".")
    if cleaned.startswith(":") and not cleaned.startswith("::"):
        cleaned = cleaned[1:]
    if cleaned.endswith(":") and not cleaned.endswith("::"):
        cleaned = cleaned[:-1]
    candidates = [cleaned]
    if ":" in cleaned:
        head, tail = cleaned.rsplit(":", 1)
        if tail.isdigit() and 0 <= int(tail) <= 65535 and ":" in head:
            candidates.append(head)
    parsed: list[ipaddress.IPv6Address] = []
    for item in candidates:
        try:
            parsed.append(ipaddress.IPv6Address(item))
        except ValueError:
            continue
    return parsed


def has_tailscale_address(text: str) -> bool:
    for m in ipv4_candidate_re.finditer(text):
        addr_str, prefix_str = m.group(1), m.group(2)
        try:
            addr4 = ipaddress.IPv4Address(addr_str)
        except ValueError:
            continue
        if addr4 in TAILSCALE_IPV4_NET:
            if prefix_str == "10" and addr4 == TAILSCALE_IPV4_NET.network_address:
                continue
            return True

    for m in bracketed_ipv6_re.finditer(text):
        for addr6 in parse_ipv6_variants(m.group(1)):
            if is_tailscale_ipv6(addr6):
                return True

    for m in unbracketed_ipv6_re.finditer(text):
        raw = m.group(1) or m.group(2)
        prefix_str = m.group(3)
        if not raw:
            continue
        for addr6 in parse_ipv6_variants(raw):
            if is_tailscale_ipv6(addr6, prefix_str):
                return True

    return False


def scan_text(text: str, location: str) -> None:
    for candidate in decode_url_variants(text):
        if secret_re.search(candidate):
            raise SanitizationError(f"脱敏检查失败（疑似凭据）：{location}")
        if home_re.search(candidate):
            raise SanitizationError(f"脱敏检查失败（非脱敏主目录路径）：{location}")
        if has_tailscale_address(candidate):
            raise SanitizationError(f"脱敏检查失败（包含具体 Tailscale 地址）：{location}")


def iter_json_strings(node: object, prefix: str = "$") -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    if isinstance(node, str):
        found.append((prefix, node))
    elif isinstance(node, dict):
        for idx, (k, v) in enumerate(node.items()):
            entry_path = f"{prefix}.field[{idx}]"
            if isinstance(k, str):
                found.append((f"{entry_path}.key", k))
            found.extend(iter_json_strings(v, f"{entry_path}.value"))
    elif isinstance(node, list):
        for idx, item in enumerate(node):
            found.extend(iter_json_strings(item, f"{prefix}[{idx}]"))
    return found


def scan_document(text: str, rel: str, is_json: bool) -> None:
    scan_text(text, rel)
    if is_json:
        parsed = json.loads(text)
        for field_path, val in iter_json_strings(parsed):
            scan_text(val, f"{rel}:{field_path}")


def run_sanitization_selftest() -> None:
    # 1) 验证 Unicode 转义的疑似凭据 JSON 键被拒绝，且错误信息仅含字段序号路径，绝不回显输入（原串/解码串/键名）
    synth_secret = "gh" + "p_" + ("A1b2C3" * 6)
    escaped_secret_key = "".join(f"\\u{ord(ch):04x}" for ch in synth_secret)
    raw_secret_key_json = '{"' + escaped_secret_key + '": {"nested": "ok"}}'
    err_msg: str | None = None
    try:
        scan_document(raw_secret_key_json, "selftest/key.json", is_json=True)
    except SanitizationError as exc:
        err_msg = str(exc)
    require(err_msg is not None, "脱敏自检失败：未拒绝 Unicode 转义凭据键")
    require("疑似凭据" in err_msg and "selftest/key.json:$.field[0].key" in err_msg, f"脱敏自检失败：定位路径异常：{err_msg}")
    require(synth_secret not in err_msg and escaped_secret_key not in err_msg, "脱敏自检失败：错误信息回显了凭据键输入")

    # 2) 验证敏感值嵌套在自定义键名下时，错误信息不回显键名或敏感值
    custom_key = "sensitive_custom_field_alpha"
    synth_home = "/Us" + "ers/" + "alice_private/project"
    escaped_home = "".join(f"\\u{ord(ch):04x}" for ch in synth_home)
    raw_home_val_json = '{"' + custom_key + '": ["ok", "' + escaped_home + '"]}'
    err_msg = None
    try:
        scan_document(raw_home_val_json, "selftest/val.json", is_json=True)
    except SanitizationError as exc:
        err_msg = str(exc)
    require(err_msg is not None, "脱敏自检失败：未拒绝非脱敏主目录值")
    require("selftest/val.json:$.field[0].value[1]" in err_msg, f"脱敏自检失败：值定位路径异常：{err_msg}")
    require(
        custom_key not in err_msg and synth_home not in err_msg and escaped_home not in err_msg,
        "脱敏自检失败：错误信息回显了自定义键名或路径输入",
    )

    # 3) 验证 Tailscale IPv4 与 IPv6（全写、压缩、大小写、带端口、无括号带端口、zone、URL 编码、双重编码、IPv4-mapped）均被拦截且不回显
    ts_v4_prefix = "100." + "64."
    ts_v6_prefix = "fd7a" + ":115c:" + "a1e0"
    ts_cases = [
        ("v4-plain", ts_v4_prefix + "12.34"),
        ("v4-trailing-period", "Connected to " + ts_v4_prefix + "12.34."),
        ("v4-sentence-period-space", "Peer " + ts_v4_prefix + "12.34. Next hop ready"),
        ("v4-ellipsis", "Peer " + ts_v4_prefix + "12.34..."),
        ("v4-trailing-comma", "peer=" + ts_v4_prefix + "12.34, ok"),
        ("v4-trailing-semicolon", "peer=" + ts_v4_prefix + "12.34;"),
        ("v4-trailing-excl", "reachable at " + ts_v4_prefix + "12.34!"),
        ("v4-trailing-question", "is it " + ts_v4_prefix + "12.34?"),
        ("v4-trailing-paren-period", "(via " + ts_v4_prefix + "12.34.)"),
        ("v4-leading-non-digit-period", "node." + ts_v4_prefix + "12.34."),
        ("v4-port", "http://" + ts_v4_prefix + "12.34:8080/ws"),
        ("v4-urlencoded", urllib.parse.quote("http://" + ts_v4_prefix + "12.34:8080/ws", safe="")),
        ("v6-compressed", ts_v6_prefix + "::1"),
        ("v6-compressed-upper", (ts_v6_prefix + "::ab12:1").upper()),
        ("v6-full", ts_v6_prefix + ":ab12:4843:cd96:6258:0001"),
        ("v6-bracket-port", "https://[" + ts_v6_prefix + "::1]:8443/api"),
        ("v6-unbracket-port", ts_v6_prefix + ":0000:0000:0000:0000:0001:8080"),
        ("v6-zone-port", "http://[" + ts_v6_prefix + "::1%25utun3]:8080/ws"),
        ("v6-urlencoded", urllib.parse.quote("https://[" + ts_v6_prefix + "::1]:8443/api", safe="")),
        ("v6-double-urlencoded", urllib.parse.quote(urllib.parse.quote("[" + ts_v6_prefix + "::1]:8080", safe=""), safe="")),
        ("v6-bare-urlencoded", urllib.parse.quote(ts_v6_prefix + "::1", safe="")),
        ("v6-label-prefix", "via:" + ts_v6_prefix + "::1"),
        ("v6-ipv4-mapped-dotted", "https://[::ffff:" + ts_v4_prefix + "1.2]:443"),
        ("v6-ipv4-mapped-hex", "[::ffff:" + "6440:" + "0102]:443"),
    ]
    for case_name, sample in ts_cases:
        escaped_sample = "".join(f"\\u{ord(ch):04x}" for ch in sample)
        payload = '{"peer": "' + escaped_sample + '"}'
        err_msg = None
        try:
            scan_document(payload, f"selftest/{case_name}.json", is_json=True)
        except SanitizationError as exc:
            err_msg = str(exc)
        require(err_msg is not None, f"脱敏自检失败：未拦截 Tailscale 用例 {case_name}")
        require(
            "Tailscale" in err_msg and f"selftest/{case_name}.json:$.field[0].value" in err_msg,
            f"脱敏自检失败：Tailscale 定位异常（{case_name}）：{err_msg}",
        )
        require(
            sample not in err_msg and escaped_sample not in err_msg and "peer" not in err_msg,
            f"脱敏自检失败：Tailscale 错误信息回显输入（{case_name}）",
        )

    # 3b) 回归测试：未转义 JSON 夹具中紧跟句点的 Tailnet IPv4 地址（589f1946 拒绝、b6abef12 误报 clean）必须被拒绝且不回显
    plain_period_ip = ts_v4_prefix + "12.34"
    plain_period_fixture = json.dumps(
        {"notes": f"Connected via {plain_period_ip}.", "category": "accepted"},
        ensure_ascii=False,
    )
    err_msg = None
    try:
        scan_document(plain_period_fixture, "selftest/v4-plain-trailing-period.json", is_json=True)
    except SanitizationError as exc:
        err_msg = str(exc)
    require(err_msg is not None, "脱敏自检失败：未拦截未转义夹具中紧跟句点的 Tailnet IPv4")
    require("Tailscale" in err_msg and "selftest/v4-plain-trailing-period.json" in err_msg, f"脱敏自检失败：定位异常：{err_msg}")
    require(plain_period_ip not in err_msg and "notes" not in err_msg, "脱敏自检失败：句点回归报错回显了输入")

    # 4) 验证非 Tailscale 地址、多余数字 octet 与文档网段字面量（含句末句点）不误报
    safe_samples = [
        "100." + "64.0.0/10",
        "Tailscale uses 100." + "64.0.0/10.",
        ts_v6_prefix + "::/48",
        "100." + "63.255.255",
        "100." + "128.0.1",
        ts_v4_prefix + "12.34.5",
        ts_v4_prefix + "12.34.5.",
        "1." + ts_v4_prefix + "12.34",
        "0." + ts_v4_prefix + "12.34.5",
        ts_v4_prefix + "12.345",
        ts_v4_prefix + "12.345.",
        "fd7a" + ":115c:a1e1::1",
        "[2001:db8::1]:8080",
        "[::ffff:192.0.2.1]:443",
        "2026-11-26T17:44:09Z",
    ]
    for safe_idx, safe_val in enumerate(safe_samples):
        scan_document(json.dumps({"ok": safe_val}), f"selftest/safe-{safe_idx}.json", is_json=True)


run_sanitization_selftest()

for file_path in sorted(fixture_dir.rglob("*")):
    if not file_path.is_file():
        continue
    text = file_path.read_text(encoding="utf-8")
    rel = str(file_path.relative_to(fixture_dir))
    try:
        scan_document(text, rel, is_json=(file_path.suffix == ".json"))
    except SanitizationError as exc:
        raise SystemExit(str(exc))

MS_THRESHOLD = 10_000_000_000
ALLOWED_DEEPSEEK_PROJECTION_KEYS = {"title", "turnOutline", "modelSelection"}


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
    if not isinstance(response, dict):
        return False, "non_object_response"
    if set(response.keys()) != {"items"}:
        return False, "unexpected_pagination_or_top_level_keys"
    items = response.get("items")
    if not isinstance(items, list) or len(items) == 0:
        return False, "empty_or_non_array_items"
    prev_ts = None
    seen_ids: set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            return False, "non_object_item"
        sid = item.get("sessionId")
        cwd = item.get("cwd")
        ts = item.get("updatedAt")
        blank = item.get("blank")
        running = item.get("running")
        if not isinstance(sid, str) or not sid.strip() or sid != sid.strip():
            return False, "blank_session_id"
        if sid in seen_ids:
            return False, "duplicate_session_id"
        seen_ids.add(sid)
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            return False, "invalid_cwd"
        if blank is not False:
            return False, "unfiltered_blank_session"
        if not isinstance(running, bool):
            return False, "invalid_running_flag"
        if not is_plain_int(ts) or ts < MS_THRESHOLD:
            return False, "expected_ms_timestamp"
        if prev_ts is not None and ts > prev_ts:
            return False, "not_descending"
        prev_ts = ts
        proj = item.get("projections")
        if proj is not None:
            if not isinstance(proj, dict) or not is_plain_int(proj.get("asOfSeq")):
                return False, "invalid_projections"
            values = proj.get("values")
            if not isinstance(values, dict):
                return False, "invalid_projection_values"
            unknown_keys = set(values.keys()) - ALLOWED_DEEPSEEK_PROJECTION_KEYS
            if unknown_keys:
                return False, f"unmodeled_projection_keys:{','.join(sorted(unknown_keys))}"
    return True, None


accepted_files = manifest.get("accepted", [])
malformed_files = manifest.get("malformed", [])
require(bool(accepted_files), "accepted 列表不能为空")
require(bool(malformed_files), "malformed 列表不能为空")

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
    require(doc.get("category") == "accepted", f"{rel} category 不是 accepted")
    require(doc.get("baselineCommit") == "2c6342fb", f"{rel} baselineCommit 不匹配")
    if doc.get("runtimeProvider") == "deepseek":
        ok, reason = validate_deepseek_snapshot(doc["response"])
        require(ok, f"{rel} 校验失败：{reason}")
        items = doc["response"]["items"]
        require(len(items) == 3, f"{rel} 应保留源快照全部 3 条非空行，实际 {len(items)}")
        req_cwd = doc.get("request", {}).get("cwd")
        require(isinstance(req_cwd, str) and all(item["cwd"] == req_cwd for item in items), f"{rel} cwd 与请求目录不一致")
        coverage["deepseek_ms_snapshot"] = True
        continue

    responses = []
    if "response" in doc:
        responses.append(("single", doc["response"]))
    for ex in doc.get("exchanges", []):
        responses.append((ex["label"], ex["response"]))
    require(bool(responses), f"{rel} 缺少 response/exchanges")

    for label, resp in responses:
        ok, reason = validate_appserver_page(resp)
        require(ok, f"{rel} ({label}) 校验失败：{reason}")

    sid = doc.get("sampleId")
    if sid == "gateway-global-unmarked-same-page-retry":
        exchanges = doc.get("exchanges", [])
        require(len(exchanges) == 2, f"{rel} 需要 2 轮同页重试交互")
        req1_params = exchanges[0]["request"]["params"]
        req2_params = exchanges[1]["request"]["params"]
        r1 = exchanges[0]["response"]["result"]
        r2 = exchanges[1]["response"]["result"]
        require("cursor" not in req1_params or req1_params["cursor"] is None, f"{rel} 第 1 轮不应携带 cursor")
        require("listMeta" not in r1 and "listMeta" not in r2, f"{rel} 现网响应不应包含 listMeta")
        require("pageDisposition" not in r1 and "pageDisposition" not in r2, f"{rel} 现网响应不应包含 pageDisposition")
        require(isinstance(r1["nextCursor"], str) and r1["nextCursor"].startswith("mimi_"), f"{rel} 缺少 mimi_* 重试游标")
        require(req2_params.get("cursor") == r1["nextCursor"], f"{rel} 第 2 轮请求 cursor 未延续第 1 轮 nextCursor")
        require(r2["nextCursor"] is None, f"{rel} 第 2 轮收口后 nextCursor 应为 null")
        require(len(r2["data"]) > len(r1["data"]), f"{rel} 第 2 轮应补出新 settled 条目")
        r1_ids = {row["id"] for row in r1["data"]}
        r2_ids = {row["id"] for row in r2["data"]}
        require(r1_ids.issubset(r2_ids), f"{rel} 第 2 轮同页重试未包含第 1 轮已返回条目")
        require(r2["data"][0]["updatedAt"] > r1["data"][0]["updatedAt"], f"{rel} 第 2 轮首条未出现更晚 updatedAt")
        require(all("cliVersion" not in row for row in r1["data"] + r2["data"]), f"{rel} 全局发现当前应裁剪 cliVersion")
        coverage["unmarked_same_page_retry"] = True
    elif sid == "claude-sdk-empty-cwd":
        rows = doc["response"]["result"]["data"]
        require(any(row["cwd"] == "" for row in rows), f"{rel} 缺少 cwd: \"\" 行")
        require(any(row["cwd"].startswith("/") for row in rows), f"{rel} 缺少正常 cwd 行")
        require(all(is_plain_int(row["updatedAt"]) and row["updatedAt"] < MS_THRESHOLD for row in rows), f"{rel} 应为秒级时间戳")
        require(all(row["cliVersion"].startswith("mimi-claude-adapter/") for row in rows), f"{rel} cliVersion 不匹配")
        require(all("recencyAt" in row and row["recencyAt"] is None for row in rows), f"{rel} 应显式包含 recencyAt: null")
        # 校验同秒并列按 id DESC 排序
        tied_pair_found = False
        for prev_row, cur_row in zip(rows, rows[1:]):
            require(prev_row["updatedAt"] >= cur_row["updatedAt"], f"{rel} updatedAt 未按降序排列")
            if prev_row["updatedAt"] == cur_row["updatedAt"]:
                require(prev_row["id"] > cur_row["id"], f"{rel} 同秒并列未按 id DESC 排序")
                tied_pair_found = True
        require(tied_pair_found, f"{rel} 缺少同秒 updatedAt 并列样本以验证 id DESC")
        coverage["claude_sdk_empty_cwd"] = True
    elif sid == "claude-legacy-rust-ms":
        exchanges = doc.get("exchanges", [])
        require(len(exchanges) == 2, f"{rel} 需要 2 页跨页交互")
        p1 = exchanges[0]["response"]["result"]
        p2 = exchanges[1]["response"]["result"]
        require(exchanges[1]["request"]["params"].get("cursor") == p1["nextCursor"], f"{rel} 第 2 页 cursor 未延续第 1 页 nextCursor")
        all_rows = p1["data"] + p2["data"]
        require(all(is_plain_int(row["updatedAt"]) and row["updatedAt"] >= MS_THRESHOLD for row in all_rows), f"{rel} 应为毫秒时间戳")
        require(all(row["cliVersion"].startswith("alleycat-claude-bridge/") for row in all_rows), f"{rel} cliVersion 不匹配")
        require(all("recencyAt" not in row for row in all_rows), f"{rel} 应省略 recencyAt")
        # 校验同毫秒 thread_id ASC 跨页切分
        require(p1["data"][1]["updatedAt"] == p2["data"][0]["updatedAt"], f"{rel} 缺少同毫秒跨页切分")
        require(p1["data"][1]["id"] < p2["data"][0]["id"], f"{rel} 同毫秒跨页应按 thread_id ASC")
        padded = p1["nextCursor"] + "=" * (-len(p1["nextCursor"]) % 4)
        cursor_obj = json.loads(base64.urlsafe_b64decode(padded))
        require(
            cursor_obj["ts"] == p1["data"][1]["updatedAt"] and cursor_obj["id"] == p1["data"][1]["id"],
            f"{rel} 游标解码内容与页尾不匹配",
        )
        coverage["rust_claude_ms"] = True
    elif sid == "codex-recency-at-null":
        exchanges = doc.get("exchanges", [])
        require(len(exchanges) >= 2, f"{rel} 需包含 recencyAt: null（schema 派生）与 recencyAt: 0（StateDB 未回填）两组交互")
        ex_null = exchanges[0]
        ex_zero = exchanges[1]
        require(ex_null["request"]["params"].get("sortKey") == "recency_at", f"{rel} exchange[0] sortKey 必须为 recency_at")
        require(ex_zero["request"]["params"].get("sortKey") == "recency_at", f"{rel} exchange[1] sortKey 必须为 recency_at")
        r_null = ex_null["response"]["result"]["data"]
        r_zero = ex_zero["response"]["result"]["data"]
        require(any("recencyAt" in row and row["recencyAt"] is None for row in r_null), f"{rel} exchange[0] 缺少显式 recencyAt: null 行")
        require(any("recencyAt" in row and is_plain_int(row["recencyAt"]) and row["recencyAt"] > 0 for row in r_null), f"{rel} exchange[0] 缺少正常正整数 recencyAt 行")
        require(any("recencyAt" in row and is_plain_int(row["recencyAt"]) and row["recencyAt"] == 0 for row in r_zero), f"{rel} exchange[1] 缺少显式 StateDB recencyAt: 0 行")
        require(any("recencyAt" in row and is_plain_int(row["recencyAt"]) and row["recencyAt"] > 0 for row in r_zero), f"{rel} exchange[1] 缺少正常正整数 recencyAt 行")
        require(all(is_plain_int(row["updatedAt"]) and row["updatedAt"] < MS_THRESHOLD for row in r_null + r_zero), f"{rel} 应为秒级时间戳")
        coverage["codex_recency_null"] = True
    elif sid == "agy-acp-current-list":
        res = doc["response"]["result"]
        require("listMeta" not in res, f"{rel} 现网响应不应包含 listMeta")
        require(all(is_plain_int(row["updatedAt"]) and row["updatedAt"] < MS_THRESHOLD for row in res["data"]), f"{rel} 应为秒级时间戳")
        require(all(row["cliVersion"].startswith("mimi-agy-adapter/") for row in res["data"]), f"{rel} cliVersion 不匹配")
        coverage["agy_current_no_list_meta"] = True

missing_cov = [k for k, v in coverage.items() if not v]
require(not missing_cov, f"现网实录覆盖缺失：{missing_cov}")

for rel in malformed_files:
    doc = json.loads((fixture_dir / rel).read_text(encoding="utf-8"))
    require(doc.get("category") == "malformed", f"{rel} category 不是 malformed")
    expected_reason = doc.get("expectedRejectionReason")
    require(isinstance(expected_reason, str) and bool(expected_reason), f"{rel} 缺少 expectedRejectionReason")
    ok, actual_reason = validate_appserver_page(doc["response"])
    require(not ok, f"畸形夹具 {rel} 应被拒绝，却意外通过")
    require(
        actual_reason == expected_reason,
        f"畸形夹具 {rel} 拒绝原因不匹配：expected={expected_reason}, actual={actual_reason}",
    )

print(
    f"Phase 0 现网实录校验通过：accepted={len(accepted_files)}/{len(accepted_files)}, "
    f"malformed_rejected={len(malformed_files)}/{len(malformed_files)}, "
    f"coverage={len(coverage)}/{len(coverage)}, sanitization=clean"
)
PY
