#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path("docs/app-store")
errors = []

limits = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "promotional_text.txt": 170,
    "keywords.txt": 100,
    "description.txt": 4000,
    "release_notes.txt": 4000,
}

for locale in ("en-US", "zh-Hans"):
    locale_root = root / locale
    for filename, limit in limits.items():
        metadata_file = locale_root / filename
        if not metadata_file.is_file():
            errors.append(f"Missing App Store metadata: {metadata_file}")
            continue
        value = metadata_file.read_text(encoding="utf-8").strip()
        if not value:
            errors.append(f"Empty App Store metadata: {metadata_file}")
        elif len(value) > limit:
            errors.append(f"{metadata_file} has {len(value)} characters; limit is {limit}")

        # 中国大陆首发的公开元数据不使用被上一轮审核明确指出的品牌词。
        if re.search(r"\b(?:OpenAI|ChatGPT)\b", value, re.IGNORECASE):
            errors.append(f"{metadata_file} contains a China-mainland high-risk brand term")
        if filename == "subtitle.txt" and re.search(
            r"\b(?:Mac|MacBook|iPhone|iPad|OpenAI|ChatGPT|Codex|Claude)\b",
            value,
            re.IGNORECASE,
        ):
            errors.append(f"{metadata_file} contains a third-party product name in the subtitle")

expected_names = {
    "en-US": "Mimi Remote",
    "zh-Hans": "Mimi Remote",
}
for locale, expected_name in expected_names.items():
    actual_name = (root / locale / "name.txt").read_text(encoding="utf-8").strip()
    if actual_name != expected_name:
        errors.append(f"{locale}/name.txt must match the localized App Store name: {expected_name}")

required_documents = (
    Path("docs/privacy-policy.md"),
    Path("docs/terms-of-use.md"),
    Path("docs/support.md"),
    root / "app-review-notes.md",
    root / "review-environment-checklist.md",
    root / "china-mainland-submission-checklist.md",
)
for document in required_documents:
    if not document.is_file() or not document.read_text(encoding="utf-8").strip():
        errors.append(f"Missing or empty public/review document: {document}")

link_source = Path("ios/MimiRemote/Sources/Core/AppExternalLinks.swift").read_text(encoding="utf-8")
for relative_path in ("privacy-policy.md", "terms-of-use.md", "support.md"):
    expected = f"https://github.com/gaixianggeng/mimi-remote/blob/main/docs/{relative_path}"
    if expected not in link_source:
        errors.append(f"AppExternalLinks.swift is missing stable URL: {expected}")

review_notes = (root / "app-review-notes.md").read_text(encoding="utf-8")
for placeholder in (
    "<REVIEW_HTTPS_ENDPOINT>",
    "<REVIEW_ACCESS_TOKEN>",
    "<START_DATE_UTC>",
    "<END_DATE_UTC>",
    "<REVIEW_CONTACT_NAME>",
    "<REVIEW_CONTACT_PHONE>",
):
    if placeholder not in review_notes:
        errors.append(f"Review notes template is missing placeholder: {placeholder}")

# 审核凭据只允许填入 App Store Connect，仓库模板不得出现真实私网地址或疑似 Token。
if re.search(r"\b100\.(?:6[4-9]|[78]\d|9\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b", review_notes):
    errors.append("Review notes template contains a concrete Tailscale IP")
if re.search(r"\b(?:sk-|github_pat_|gh[pousr]_)[A-Za-z0-9_-]{16,}\b", review_notes):
    errors.append("Review notes template contains a possible credential")

project_spec = Path("ios/MimiRemote/project.yml").read_text(encoding="utf-8")
if 'SWIFT_EMIT_LOC_STRINGS: "NO"' not in project_spec:
    errors.append("project.yml must disable automatic Swift string extraction")
build_match = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', project_spec)
if not build_match or int(build_match.group(1)) < 100048:
    errors.append("CURRENT_PROJECT_VERSION must be numeric and at least 100048")

if errors:
    print("App Store metadata gate failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print("App Store metadata gate passed for en-US and zh-Hans.")
PY
