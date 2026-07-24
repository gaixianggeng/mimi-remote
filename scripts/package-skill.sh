#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_NAME="install-mimi-remote"
SKILL_DIR="$ROOT_DIR/packaging/skill/$SKILL_NAME"
OUTPUT_DIR="${1:-$ROOT_DIR/dist-skill}"

fail() {
  echo "Skill 打包失败：$1" >&2
  exit 1
}

for command_name in cmp find grep mktemp ruby shasum unzip zip; do
  command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令 ${command_name}。"
done

[[ -f "$SKILL_DIR/SKILL.md" ]] || fail "缺少 $SKILL_DIR/SKILL.md。"
[[ -f "$SKILL_DIR/agents/openai.yaml" ]] || fail "缺少 $SKILL_DIR/agents/openai.yaml。"

# 完整源码仓库保留根 SKILL.md 方便直接阅读；发布包必须与它逐字一致，
# 防止维护时出现“仓库说明”和“用户安装到 Codex 的 Skill”两个版本。
if [[ -f "$ROOT_DIR/SKILL.md" ]] && ! cmp -s "$ROOT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"; then
  fail "根 SKILL.md 与独立 Skill 包内容不一致。"
fi

ruby - "$SKILL_DIR/SKILL.md" "$SKILL_DIR/agents/openai.yaml" "$SKILL_NAME" <<'RUBY'
skill_path, metadata_path, expected_name = ARGV
skill = File.read(skill_path, encoding: "UTF-8")
frontmatter = skill.match(/\A---\n(.*?)\n---\n/m)&.captures&.first
abort "Skill 打包失败：SKILL.md 缺少 YAML frontmatter。" unless frontmatter
name = frontmatter[/^name:\s*(.+)$/, 1]&.strip
description = frontmatter[/^description:\s*(.+)$/, 1]&.strip
abort "Skill 打包失败：Skill 名称必须为 #{expected_name}。" unless name == expected_name
abort "Skill 打包失败：Skill description 不能为空。" if description.to_s.empty?

metadata = File.read(metadata_path, encoding: "UTF-8")
%w[display_name short_description default_prompt].each do |key|
  abort "Skill 打包失败：agents/openai.yaml 缺少 #{key}。" unless metadata.match?(/^\s+#{key}:\s+".+"$/)
end
abort "Skill 打包失败：default_prompt 必须显式引用 $#{expected_name}。" unless metadata.include?("$#{expected_name}")
RUBY

unexpected_files="$(
  cd "$SKILL_DIR"
  find . -type f ! -path './SKILL.md' ! -path './agents/openai.yaml' -print
)"
[[ -z "$unexpected_files" ]] || fail "Skill 目录包含未声明文件：${unexpected_files}"

symlinks="$(find "$SKILL_DIR" -type l -print)"
[[ -z "$symlinks" ]] || fail "Skill 发布包不允许包含符号链接。"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
archive="$OUTPUT_DIR/$SKILL_NAME.zip"
checksum="$archive.sha256"
# 使用 BSD/GNU mktemp 都接受的完整模板，避免 Linux 发布 Runner 因 -t 语义差异失败。
stage="$(mktemp -d "${TMPDIR:-/tmp}/mimi-skill-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/$SKILL_NAME/agents"
cp "$SKILL_DIR/SKILL.md" "$stage/$SKILL_NAME/SKILL.md"
cp "$SKILL_DIR/agents/openai.yaml" "$stage/$SKILL_NAME/agents/openai.yaml"

rm -f "$archive" "$checksum"
(
  cd "$stage"
  zip -X -q -r "$archive" "$SKILL_NAME"
)
unzip -tq "$archive" >/dev/null
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$archive")" > "$(basename "$checksum")"
)

echo "Codex Skill 已打包：$archive"
echo "SHA-256：$checksum"
