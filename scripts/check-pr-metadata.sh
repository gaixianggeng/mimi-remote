#!/usr/bin/env bash
set -euo pipefail

# 独立的非必需 PR 元数据提示检查：
# 1. 仅通过环境变量 PR_BODY 与 PR_TITLE 读取输入，全程按不可信纯数据处理，
#    不依赖当前工作目录中的任何仓库文件，可在任意 cwd 下执行。
# 2. 正文 Refs # 校验（决定退出码）：
#    依据现行规范（AGENTS.md 与 docs/operations/agent-guides/issues.md），
#    PR 正文必须包含 Refs #<编号>（不区分大小写，匹配 \bRefs\s+#[0-9]+\b）。
#    若正文缺失，检查退出非零；若正文缺失但标题中出现 Refs #，明确区分并提示补入正文，
#    不对标题附加规范之外的硬禁。
# 3. 自动关闭词提示（独立提示，不单独导致失败）：
#    项目默认不使用自动关闭词，避免 PR 合并后在发布或 Worktree 清理完成前自动关闭 Issue。
#    GitHub 实际识别的自动关闭关键字范围包括：
#    - fix / fixed / fixes
#    - close / closed / closes
#    - resolve / resolved / resolves
#    - 支持带冒号形式（如 Fixes: #123、Closes:#123）
#    - 支持跨仓引用（如 owner/repo#123）及完整 GitHub Issue URL
#    另注：commit message 也是另一条自动关单入口；本检查仅扫描 PR 标题和正文，
#    不扫描 commit message。

usage() {
  cat <<'EOF'
用法：
  PR_TITLE="<PR 标题>" PR_BODY="<PR 正文>" bash ./scripts/check-pr-metadata.sh

说明：
  - 仅通过环境变量 PR_BODY 和 PR_TITLE 读取输入，不接受正文/标题作为命令行参数。
  - 正文缺少 Refs #<编号> 时退出非零；自动关闭词仅作独立提示，不单独导致失败。
  - GitHub 自动关闭关键字涵盖 fix/fixed/fixes、close/closed/closes、
    resolve/resolved/resolves、带冒号形式及跨仓引用（如 owner/repo#123）；
    commit message 也是另一条自动关单入口（本检查只看 PR 标题和正文）。
EOF
}

if [[ "$#" -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "PR 元数据检查失败：不接受未知命令行参数，请仅通过环境变量 PR_BODY 和 PR_TITLE 传入内容。" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "PR 元数据检查失败：未找到 python3。" >&2
  exit 1
fi

python3 - <<'PY'
import os
import re
import sys

# 仅读取环境变量，避免任何 shell 展开或参数注入。
pr_body = os.environ.get("PR_BODY", "")
pr_title = os.environ.get("PR_TITLE", "")

# 遵循 W7 指定的 \bRefs\s+#[0-9]+\b（仅启用 re.IGNORECASE，不启用 re.ASCII），
# 使用 Python 默认 Unicode 空白与词边界语义，既匹配 U+00A0/U+3000 等 Unicode 空白，
# 又避免 XRefs #123、Refs #123abc 或中文字符无分隔紧邻等误匹配。
REFS_PATTERN = re.compile(r"\bRefs\s+#[0-9]+\b", re.IGNORECASE)

# 覆盖 GitHub 识别的自动关闭关键字（含单复数/过去式、可选冒号、同仓 #123、
# 跨仓 owner/repo#123 及完整 GitHub Issue URL）。
AUTO_CLOSE_PATTERN = re.compile(
    r"\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)"
    r"(?::\s*|\s+)"
    r"(?:(?:[A-Za-z0-9-]+/[A-Za-z0-9._-]+)?#[0-9]+"
    r"|https?://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/issues/[0-9]+)\b",
    re.IGNORECASE | re.ASCII,
)


def find_auto_close_matches(text):
    seen = set()
    matches = []
    for match in AUTO_CLOSE_PATTERN.finditer(text):
        normalized = re.sub(r"\s+", " ", match.group(0)).strip()
        key = normalized.lower()
        if key not in seen:
            seen.add(key)
            matches.append(normalized)
    return matches


body_has_refs = REFS_PATTERN.search(pr_body) is not None
title_has_refs = REFS_PATTERN.search(pr_title) is not None
body_is_empty = pr_body.strip() == ""

body_auto_close = find_auto_close_matches(pr_body)
title_auto_close = find_auto_close_matches(pr_title)

exit_code = 0

if body_has_refs:
    print("[PASS] PR 正文包含 Refs #<编号> 引用。", flush=True)
else:
    exit_code = 1
    if title_has_refs:
        if body_is_empty:
            print(
                "[FAIL] PR 正文为空，缺少 Refs #<编号>；但 PR 标题中检测到 Refs # 引用。"
                "现行规范要求将 Refs #<编号> 写在 PR 正文中，请将引用补入正文"
                "（本检查不对标题附加规范之外的硬禁）。",
                file=sys.stderr,
                flush=True,
            )
        else:
            print(
                "[FAIL] PR 正文缺少 Refs #<编号>；仅在 PR 标题中检测到 Refs # 引用。"
                "现行规范要求将 Refs #<编号> 写在 PR 正文中，请将引用补入正文"
                "（本检查不对标题附加规范之外的硬禁）。",
                file=sys.stderr,
                flush=True,
            )
    elif body_is_empty:
        print(
            "[FAIL] PR 正文为空，缺少 Refs #<编号>（PR 标题中也未检测到 Refs # 引用）。"
            "请按现行规范在 PR 正文中补充 Refs #<编号>。",
            file=sys.stderr,
            flush=True,
        )
    else:
        print(
            "[FAIL] PR 正文缺少 Refs #<编号>（PR 标题中也未检测到 Refs # 引用）。"
            "请按现行规范在 PR 正文中补充 Refs #<编号>。",
            file=sys.stderr,
            flush=True,
        )

if body_auto_close or title_auto_close:
    locations = []
    combined_matches = []
    seen_combined = set()

    if body_auto_close:
        locations.append("PR 正文")
        for item in body_auto_close:
            key = item.lower()
            if key not in seen_combined:
                seen_combined.add(key)
                combined_matches.append(item)

    if title_auto_close:
        locations.append("PR 标题")
        for item in title_auto_close:
            key = item.lower()
            if key not in seen_combined:
                seen_combined.add(key)
                combined_matches.append(item)

    print(
        f"[NOTICE] 独立提示（不单独导致检查失败）：在{'、'.join(locations)}中检测到疑似自动关闭词："
        f"{', '.join(combined_matches)}。",
        flush=True,
    )
    print(
        "[NOTICE] 规范提示：项目默认不使用 Fixes / Closes 等自动关闭词，避免 PR 合并后在发布或 "
        "Worktree 清理完成前自动关闭 Issue。",
        flush=True,
    )
    print(
        "[NOTICE] 覆盖范围说明：GitHub 实际识别的自动关闭关键字包括 "
        "fix/fixed/fixes、close/closed/closes、resolve/resolved/resolves，"
        "含带冒号形式（如 Fixes: #123）及跨仓引用（如 owner/repo#123）；"
        "此外，commit message 也是另一条自动关单入口（本检查仅检查 PR 标题和正文，不扫描 commit message）。",
        flush=True,
    )

raise SystemExit(exit_code)
PY
