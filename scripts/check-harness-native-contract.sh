#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "原生 Harness 契约检查失败：未找到 python3。" >&2
  exit 1
fi

# 只校验 manifest 自身声明的不变量：夹具可解析、登记集合与目录双向一致、SHA-256 摘要一致。
# 不做协议语义断言——Go/iOS 是否按契约实现由 harnessclient/httpapi 的测试覆盖，不在这里冒充。
python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys

CONTRACT_DIR = "contracts/harness-native"
EXPECTED_FIXTURE_ROOT = f"{CONTRACT_DIR}/fixtures"

root = pathlib.Path(sys.argv[1])
contract_dir = root / CONTRACT_DIR
manifest_path = contract_dir / "manifest.json"
errors = []


def fail(message):
    errors.append(message)


try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    print(f"原生 Harness 契约检查失败：缺少 {manifest_path}。", file=sys.stderr)
    raise SystemExit(1)
except Exception as exc:
    print(f"原生 Harness 契约检查失败：manifest.json 无法解析：{exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(manifest, dict):
    print("原生 Harness 契约检查失败：manifest.json 顶层必须是对象。", file=sys.stderr)
    raise SystemExit(1)

fixtures = manifest.get("fixtures")
if not isinstance(fixtures, dict):
    print("原生 Harness 契约检查失败：manifest 缺少 fixtures 段。", file=sys.stderr)
    raise SystemExit(1)

declared_root = fixtures.get("root")
if declared_root != EXPECTED_FIXTURE_ROOT:
    fail(f"fixtures.root 期望 {EXPECTED_FIXTURE_ROOT}，实际 {declared_root!r}")

declared_files = fixtures.get("files")
if not isinstance(declared_files, list) or not declared_files:
    print("原生 Harness 契约检查失败：fixtures.files 必须是非空数组。", file=sys.stderr)
    raise SystemExit(1)

digests = manifest.get("fixtureDigests")
if not isinstance(digests, dict) or not digests:
    print("原生 Harness 契约检查失败：fixtureDigests 必须是非空对象。", file=sys.stderr)
    raise SystemExit(1)

if fixtures.get("digestAlgorithm") != "sha256":
    fail(f"digestAlgorithm 期望 sha256，实际 {fixtures.get('digestAlgorithm')!r}")

declared_set = set()
for entry in declared_files:
    if not isinstance(entry, str) or not entry:
        fail(f"fixtures.files 含非法条目：{entry!r}")
        continue
    if entry in declared_set:
        fail(f"fixtures.files 含重复条目：{entry}")
    declared_set.add(entry)

digest_set = set(digests)

for missing in sorted(declared_set - digest_set):
    fail(f"{missing} 已在 fixtures.files 登记，但缺少摘要")
for orphan in sorted(digest_set - declared_set):
    fail(f"{orphan} 有摘要，但未在 fixtures.files 登记")

fixture_root = root / declared_root if declared_root else root / EXPECTED_FIXTURE_ROOT
actual_set = set()
if fixture_root.is_dir():
    for path in sorted(fixture_root.rglob("*")):
        if path.is_file():
            actual_set.add(path.relative_to(contract_dir).as_posix())
else:
    fail(f"夹具目录不存在：{declared_root!r}")

for missing in sorted(declared_set - actual_set):
    fail(f"{missing} 已登记，但文件缺失")
for unlisted in sorted(actual_set - declared_set):
    fail(f"{unlisted} 存在于夹具目录，但未在 fixtures.files 登记（未登记夹具会让契约与仓库漂移）")

for relative in sorted(declared_set & actual_set):
    path = contract_dir / relative
    raw = path.read_bytes()
    expected = digests.get(relative)
    actual = hashlib.sha256(raw).hexdigest()
    if expected != actual:
        fail(f"{relative} 摘要不符：manifest={expected} 实际={actual}（夹具被改写必须同步更新摘要）")
    try:
        json.loads(raw.decode("utf-8"))
    except Exception as exc:
        fail(f"{relative} 不是合法 JSON：{exc}")

if errors:
    print("原生 Harness 契约检查失败：", file=sys.stderr)
    for item in errors:
        print(f"  - {item}", file=sys.stderr)
    raise SystemExit(1)

print(f"原生 Harness 契约夹具检查通过：{len(declared_set)} 个夹具摘要与 manifest 一致。")
PY
