#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0

report_matches() {
  local title="$1"
  local matches="$2"
  if [[ -n "$matches" ]]; then
    echo "公开仓库门禁失败：$title" >&2
    printf '%s\n' "$matches" >&2
    failures=$((failures + 1))
  fi
}

# 正则本身放在本脚本中，因此扫描时排除本文件，避免规则自匹配。
secret_pattern='-----BEGIN (ENCRYPTED |RSA |EC |OPENSSH )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{30,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{20,}'
# 只输出命中文件名，绝不把疑似凭据所在的整行复制到公开 CI 日志。
secret_matches="$(rg -l --hidden --pcre2 \
  --glob '!.git/**' \
  --glob '!scripts/check-public-repo-safety.sh' \
  -- "$secret_pattern" . || true)"
report_matches "发现疑似私钥或访问令牌" "$secret_matches"

history_findings=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  if ! history_trees="$(git log --all --format='%T %H' | awk '!seen[$1]++')"; then
    echo "公开仓库门禁失败：无法枚举 Git 历史 tree。" >&2
    exit 1
  fi
  while read -r tree_id commit_id; do
    [[ -n "$tree_id" && -n "$commit_id" ]] || continue

    # git grep 在 tree 内部批量扫描，不使用 producer | rg -q，避免命中大 blob 时 SIGPIPE 反而漏报。
    if tree_matches="$(git grep -I -l -E -- "$secret_pattern" "$tree_id" -- . \
      ':(exclude)scripts/check-public-repo-safety.sh' 2>/dev/null)"; then
      while read -r matched_path; do
        [[ -n "$matched_path" ]] || continue
        matched_path="${matched_path#*:}"
        history_findings+="${commit_id} ${matched_path}"$'\n'
      done <<<"$tree_matches"
    else
      grep_status=$?
      if [[ "$grep_status" -ne 1 ]]; then
        echo "公开仓库门禁失败：无法扫描 Git tree ${tree_id}。" >&2
        exit 1
      fi
    fi

    if ! tree_paths="$(git ls-tree -r --name-only "$tree_id")"; then
      echo "公开仓库门禁失败：无法读取 Git tree $tree_id 的路径。" >&2
      exit 1
    fi
    while read -r historical_path; do
      [[ -n "$historical_path" ]] || continue
      if [[ "$historical_path" =~ (^|/)(\.env($|\.)|\.npmrc$|\.netrc$|config\.json$|id_rsa$|id_ed25519$)|\.(key|p8|p12|mobileprovision|ipa)$ ]] \
        && [[ ! "$historical_path" =~ (^|/)\.env\.(example|sample|template)$ ]]; then
        history_findings+="${commit_id} ${historical_path}"$'\n'
      fi
    done <<<"$tree_paths"
  done <<<"$history_trees"
fi
history_findings="${history_findings%$'\n'}"
if [[ -n "$history_findings" ]]; then
  history_findings="$(printf '%s\n' "$history_findings" | sort -u)"
fi
report_matches "Git 历史包含疑似凭据或敏感产物" "$history_findings"

artifact_matches="$(git ls-files -co --exclude-standard | \
  rg '(^|/)(\.env($|\.)|\.npmrc$|\.netrc$|config\.json$|id_rsa$|id_ed25519$)|\.(key|p8|p12|mobileprovision|ipa)$' | \
  rg -v '(^|/)\.env\.(example|sample|template)$' || true)"
report_matches "发现不应进入仓库的凭据或签名产物" "$artifact_matches"

docs_paths=(README.md)
[[ -d docs ]] && docs_paths+=(docs)
private_endpoint_matches="$(rg -l --pcre2 \
  '100\.(?!64\.0\.0/10(?:[^0-9]|$))(6[4-9]|[78][0-9]|9[0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' \
  "${docs_paths[@]}" || true)"
report_matches "公开文档包含具体 Tailscale 地址" "$private_endpoint_matches"

home_path_matches="$(rg -l --pcre2 '/Users/(?!me/|you/)[A-Za-z0-9._-]+/|/home/(?!me/|user/)[A-Za-z0-9._-]+/' \
  "${docs_paths[@]}" || true)"
report_matches "公开文档包含真实用户主目录" "$home_path_matches"

unpinned_action_matches="$(rg -n --pcre2 'uses:\s+(?!\./)[^\s]+@(?![0-9a-f]{40}(?:\s|$))[^\s]+' \
  .github/workflows || true)"
report_matches "GitHub Action 未固定到完整 commit SHA" "$unpinned_action_matches"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

bash ./scripts/check-third-party-notices.sh

echo "公开仓库安全门禁通过。"
