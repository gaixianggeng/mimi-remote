#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/check-public-repo-safety.sh [--full-history] [--plan] [--github-output <path>]
  bash ./scripts/check-public-repo-safety.sh --pull-request --base <sha> --head <sha> [--plan] [--github-output <path>]
EOF
}

fail() {
  echo "公开仓库门禁失败：$1" >&2
  exit 1
}

mode="full-history"
mode_explicit=0
base_sha=""
head_sha=""
plan_only=0
github_output=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --full-history)
      [[ "$mode_explicit" -eq 0 ]] || fail "只能选择一种扫描模式。"
      mode="full-history"
      mode_explicit=1
      shift
      ;;
    --pull-request)
      [[ "$mode_explicit" -eq 0 ]] || fail "只能选择一种扫描模式。"
      mode="pull-request"
      mode_explicit=1
      shift
      ;;
    --base)
      [[ "$#" -ge 2 ]] || fail "--base 缺少 SHA。"
      base_sha="$2"
      shift 2
      ;;
    --head)
      [[ "$#" -ge 2 ]] || fail "--head 缺少 SHA。"
      head_sha="$2"
      shift 2
      ;;
    --plan)
      plan_only=1
      shift
      ;;
    --github-output)
      [[ "$#" -ge 2 ]] || fail "--github-output 缺少路径。"
      github_output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数 $1。"
      ;;
  esac
done

for command_name in awk git mktemp sort; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

git rev-parse --git-dir >/dev/null 2>&1 \
  || fail "当前目录不是 Git 仓库。"

temporary_paths=""
history_temporary_root=""
cleanup() {
  [[ -z "$temporary_paths" ]] || rm -f "$temporary_paths"
  [[ -z "$history_temporary_root" ]] || rm -rf "$history_temporary_root"
}
trap cleanup EXIT

third_party=true
if [[ "$mode" == "pull-request" ]]; then
  [[ -n "$base_sha" && -n "$head_sha" ]] \
    || fail "pull-request 模式必须同时提供 --base 与 --head。"
  [[ "$base_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] \
    || fail "base 必须是完整 commit SHA。"
  [[ "$head_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] \
    || fail "head 必须是完整 commit SHA。"
  git cat-file -e "${base_sha}^{commit}" 2>/dev/null \
    || fail "base commit 不存在：$base_sha"
  git cat-file -e "${head_sha}^{commit}" 2>/dev/null \
    || fail "head commit 不存在：$head_sha"
  merge_base="$(git merge-base "$base_sha" "$head_sha")" \
    || fail "base 与 head 没有共同祖先。"

  temporary_paths="$(mktemp "${TMPDIR:-/tmp}/mimi-public-safety-paths.XXXXXX")"
  # 许可证证明只取决于最终依赖图和打包入口；中间提交的 secret 由下方逐 tree 扫描兜底。
  git diff --name-only -z --no-renames "$merge_base" "$head_sha" > "$temporary_paths" \
    || fail "无法收集 PR 变更路径。"
  third_party=false
  while IFS= read -r -d '' changed_path; do
    case "$changed_path" in
      go.mod|go.sum|THIRD_PARTY_NOTICES.md|.goreleaser.yml|scripts/check-third-party-notices.sh|ios/MimiRemote/project.yml|ios/MimiRemote/MimiRemote.xcodeproj/project.pbxproj|ios/MimiRemote/MimiRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
        third_party=true
        break
        ;;
    esac
  done < "$temporary_paths"
elif [[ -n "$base_sha" || -n "$head_sha" ]]; then
  fail "--base/--head 只能与 --pull-request 一起使用。"
fi

plan_output="$(printf 'mode=%s\nthird_party=%s\n' "$mode" "$third_party")"
if [[ "$plan_only" -eq 1 ]]; then
  printf '%s\n' "$plan_output"
  if [[ -n "$github_output" ]]; then
    printf '%s\n' "$plan_output" >> "$github_output"
  fi
  exit 0
fi

for command_name in bash rg; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

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
if [[ "$mode" == "pull-request" ]]; then
  history_revision="${base_sha}..${head_sha}"
  history_label="PR 新增提交"
else
  history_revision="--all"
  history_label="完整 Git 历史"
fi
if ! history_trees="$(git log "$history_revision" --format='%T %H' | awk '!seen[$1]++')"; then
  fail "无法枚举${history_label} tree。"
fi
# Full-history content is prefiltered once per unique blob. Force text here so
# binary attributes cannot hide a candidate; the original tree-aware git grep
# below remains the final authority (including attributes and path exclusions).
# The synthetic tree is unreachable, contains only existing object IDs, and does
# not change refs, the index, or the worktree.
if [[ "$mode" == "full-history" ]]; then
  history_temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-public-safety-history.XXXXXX")"
  if ! printf '%s\n' "$history_trees" | awk '{ print $1 }' \
    | git rev-list --objects --no-object-names --stdin \
    | git cat-file --batch-check='%(objectname) %(objecttype)' \
    | awk '$2 == "blob" { printf "100644 blob %s\t%s\n", $1, $1 }
           $2 !~ /^(blob|tree|commit|tag)$/ { exit 1 }' \
    > "$history_temporary_root/blobs"; then
    fail "Cannot enumerate full-history blobs."
  fi
  blob_tree="$(git mktree < "$history_temporary_root/blobs")" \
    || fail "Cannot prepare full-history blob scan."
  if git grep -a -l -E -- "$secret_pattern" "$blob_tree" -- . \
    > "$history_temporary_root/matches"; then
    :
  else
    grep_status=$?
    [[ "$grep_status" -eq 1 ]] || fail "Cannot scan full-history blobs."
  fi
  awk -F: '{ print $2 }' "$history_temporary_root/matches" \
    > "$history_temporary_root/matched-blobs"
fi

while read -r tree_id commit_id; do
  [[ -n "$tree_id" && -n "$commit_id" ]] || continue

  scan_tree=true
  if [[ "$mode" == "full-history" ]]; then
    # Keep every tree/path/commit occurrence, including renames, deleted paths,
    # and identical blobs at both excluded and non-excluded paths. Git's normal
    # path quoting and the baseline read -r whitespace trimming are preserved.
    if ! tree_plan="$(git ls-tree -r "$tree_id" | awk \
      -v matches_file="$history_temporary_root/matched-blobs" '
        BEGIN {
          while ((status = (getline oid < matches_file)) > 0) matched[oid] = 1
          if (status < 0) exit 1
          close(matches_file)
        }
        {
          # Preserve the original behavior if submodule recursion is configured.
          if ($2 == "commit" || $3 in matched) scan = 1
          path = substr($0, index($0, "\t") + 1)
          sub(/^[ \t]+/, "", path)
          sub(/[ \t]+$/, "", path)
          if (path ~ /(^|\/)(\.env($|\.)|\.npmrc$|\.netrc$|config\.json$|id_rsa$|id_ed25519$)|\.(key|p8|p12|mobileprovision|ipa)$/ &&
              path !~ /(^|\/)\.env\.(example|sample|template)$/)
            print "path " path
        }
        END { if (scan) print "scan" }
      ')"; then
      fail "Cannot read Git tree $tree_id."
    fi
    scan_tree=false
    while IFS= read -r finding; do
      case "$finding" in
        scan) scan_tree=true ;;
        'path '*) history_findings+="${commit_id} ${finding#path }"$'\n' ;;
      esac
    done <<<"$tree_plan"
  fi

  if [[ "$scan_tree" == true ]]; then
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
        fail "无法扫描 Git tree ${tree_id}。"
      fi
    fi

  fi

  [[ "$mode" == "full-history" ]] && continue

  if ! tree_paths="$(git ls-tree -r --name-only "$tree_id")"; then
    fail "无法读取 Git tree $tree_id 的路径。"
  fi
  while read -r historical_path; do
    [[ -n "$historical_path" ]] || continue
    if [[ "$historical_path" =~ (^|/)(\.env($|\.)|\.npmrc$|\.netrc$|config\.json$|id_rsa$|id_ed25519$)|\.(key|p8|p12|mobileprovision|ipa)$ ]] \
      && [[ ! "$historical_path" =~ (^|/)\.env\.(example|sample|template)$ ]]; then
      history_findings+="${commit_id} ${historical_path}"$'\n'
    fi
  done <<<"$tree_paths"
done <<<"$history_trees"
history_findings="${history_findings%$'\n'}"
if [[ -n "$history_findings" ]]; then
  history_findings="$(printf '%s\n' "$history_findings" | sort -u)"
fi
report_matches "Git 历史包含疑似凭据或敏感产物" "$history_findings"

artifact_matches="$(git ls-files -co --exclude-standard | \
  rg '(^|/)(\.env($|\.)|\.npmrc$|\.netrc$|config\.json$|id_rsa$|id_ed25519$)|\.(key|p8|p12|mobileprovision|ipa)$' | \
  rg -v '(^|/)\.env\.(example|sample|template)$' || true)"
report_matches "发现不应进入仓库的凭据或签名产物" "$artifact_matches"

public_text_paths=(README.md)
[[ -d docs ]] && public_text_paths+=(docs)
[[ -d config/automations ]] && public_text_paths+=(config/automations)
[[ -f ios/MimiRemote/README.md ]] && public_text_paths+=(ios/MimiRemote/README.md)
private_endpoint_matches="$(rg -l --pcre2 \
  '100\.(?!64\.0\.0/10(?:[^0-9]|$))(6[4-9]|[78][0-9]|9[0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' \
  "${public_text_paths[@]}" || true)"
report_matches "公开文本包含具体 Tailscale 地址" "$private_endpoint_matches"

home_path_matches="$(rg -l --pcre2 '/Users/(?!me/|you/|demo/)[A-Za-z0-9._-]+/|/home/(?!me/|user/|demo/)[A-Za-z0-9._-]+/' \
  "${public_text_paths[@]}" || true)"
report_matches "公开文本包含真实用户主目录" "$home_path_matches"

unpinned_action_matches="$(rg -n --pcre2 'uses:\s+(?!\./)[^\s]+@(?![0-9a-f]{40}(?:\s|$))[^\s]+' \
  .github/workflows || true)"
report_matches "GitHub Action 未固定到完整 commit SHA" "$unpinned_action_matches"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

# 品牌身份门禁独立扫描仓库地址、商店名称和 AppExternalLinks；它不回调本安全门禁，避免递归。
bash ./scripts/check-brand-identity.sh
if [[ "$third_party" == true ]]; then
  bash ./scripts/check-third-party-notices.sh
else
  echo "第三方许可门禁跳过：PR 未修改依赖、许可清单或打包入口。"
fi
bash ./scripts/check-pr-gate.sh

echo "公开仓库安全门禁通过：${history_label}已扫描，third_party=${third_party}。"
