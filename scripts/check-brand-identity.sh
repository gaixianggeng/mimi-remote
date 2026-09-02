#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCRIPT_PATH="scripts/check-brand-identity.sh"
RENAME_RUNBOOK_PATH="docs/operations/github-repository-rename-runbook.zh-CN.md"
failures=0

fail() {
  echo "品牌身份门禁失败：$1" >&2
  failures=$((failures + 1))
}

# 只返回文件名，不输出命中行，避免把公开文本中的其他内容带入 CI 日志。
tracked_text_matches() {
  local pattern="$1"
  local allow_runbook="${2:-0}"
  local matches
  local status
  local -a pathspecs=(
    .
    ":(exclude)$SCRIPT_PATH"
  )

  if [[ "$allow_runbook" == "1" ]]; then
    pathspecs+=(":(exclude)$RENAME_RUNBOOK_PATH")
  fi

  # 使用单次 git grep 批量扫描 Git 跟踪的文本文件，避免按文件启动数千个 grep 进程。
  if matches="$(git grep -I -i -l -F -- "$pattern" -- "${pathspecs[@]}")"; then
    printf '%s\n' "$matches"
    return 0
  else
    status=$?
  fi

  # git grep 退出码 1 表示没有匹配，不是门禁执行失败。
  if [[ "$status" -eq 1 ]]; then
    return 0
  fi
  return "$status"
}

assert_no_global_match() {
  local label="$1"
  local pattern="$2"
  local allow_runbook="${3:-0}"
  local matches
  matches="$(tracked_text_matches "$pattern" "$allow_runbook")"
  if [[ -n "$matches" ]]; then
    fail "$label（命中文件：$(printf '%s' "$matches" | tr '\n' ' ')）"
  fi
}

assert_file_value() {
  local path="$1"
  local expected="$2"
  local actual
  if [[ ! -f "$path" ]]; then
    fail "缺少 $path。"
    return
  fi
  actual="$(tr -d '\r\n' < "$path")"
  if [[ "$actual" != "$expected" ]]; then
    fail "$path 必须严格等于指定品牌值。"
  fi
}

# 旧 canonical owner/repo 只允许出现在描述迁移步骤的 runbook，脚本本身排除以免自匹配。
assert_no_global_match "发现旧 canonical 仓库地址" "gaixianggeng/codex-ipad-agent" 1
# 旧的 Console 品牌不属于任何当前文案；不要把裸 codex-ipad-agent 兼容输入列入此规则。
assert_no_global_match "发现已废弃的中文 Console 品牌" "咪咪 Console"
assert_no_global_match "发现已废弃的英文 Console 品牌" "Mimi Console"

if ! grep -Fqx '    owner: gaixianggeng' .goreleaser.yml; then
  fail ".goreleaser.yml 的 release.github.owner 不是 gaixianggeng。"
fi
if ! grep -Fqx '    name: mimi-remote' .goreleaser.yml; then
  fail ".goreleaser.yml 的 release.github.name 不是 mimi-remote。"
fi
grep -Fqx 'repository = "https://github.com/gaixianggeng/mimi-remote"' Cargo.toml \
  || fail "Cargo.toml repository 不是 Mimi Remote 主仓库。"
grep -Fqx 'homepage = "https://github.com/gaixianggeng/mimi-remote"' Cargo.toml \
  || fail "Cargo.toml homepage 不是 Mimi Remote 主仓库。"
assert_file_value docs/app-store/zh-Hans/name.txt 'Mimi Remote'
assert_file_value docs/app-store/en-US/name.txt 'Mimi Remote'
assert_file_value docs/app-store/en-US/subtitle.txt 'Remote coding workspace'
assert_file_value docs/app-store/zh-Hans/subtitle.txt 'AI 编程远程工作台'

app_links="ios/MimiRemote/Sources/Core/AppExternalLinks.swift"
for expected_url in \
  "https://github.com/gaixianggeng/mimi-remote" \
  "https://github.com/gaixianggeng/mimi-remote/releases/latest" \
  "https://github.com/gaixianggeng/mimi-remote/releases/latest/download/Mimi-Remote-Mac.dmg" \
  "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/privacy-policy.md" \
  "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/terms-of-use.md" \
  "https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md"; do
  if [[ ! -f "$app_links" ]] || ! grep -Fq "$expected_url" "$app_links"; then
    fail "${app_links} 缺少 canonical URL：${expected_url}。"
  fi
done

grep -Fq 'https://github.com/gaixianggeng/mimi-remote' README.md \
  || fail "README.md 缺少 Mimi Remote canonical URL。"
grep -Fq 'https://github.com/gaixianggeng/mimi-remote' README.zh-CN.md \
  || fail "README.zh-CN.md 缺少 Mimi Remote canonical URL。"

if [[ ! -f SKILL.md || ! -f packaging/skill/install-mimi-remote/SKILL.md ]] \
  || ! cmp -s SKILL.md packaging/skill/install-mimi-remote/SKILL.md; then
  fail "根 SKILL.md 与独立安装 Skill 内容不一致。"
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "品牌身份门禁通过：canonical 仓库、App Store 品牌、公开链接和安装 Skill 保持一致。"
