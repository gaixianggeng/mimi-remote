#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "公开仓库门禁自测失败：$1" >&2
  exit 1
}

for command_name in bash chmod cp git grep mkdir mktemp printf rm rg; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-public-safety-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

assert_contains() {
  local output="$1"
  local expected="$2"
  printf '%s\n' "$output" | grep -Fq -- "$expected" \
    || fail "输出缺少：${expected}"
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  if printf '%s\n' "$output" | grep -Fq -- "$unexpected"; then
    fail "输出不应包含：${unexpected}"
  fi
}

create_repository() {
  local repository="$1"
  mkdir -p "$repository/scripts" "$repository/.github/workflows" \
    "$repository/ios/MimiRemote/MimiRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  cp scripts/check-public-repo-safety.sh "$repository/scripts/"
  chmod +x "$repository/scripts/check-public-repo-safety.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$repository/scripts/check-brand-identity.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$repository/scripts/check-pr-gate.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ -z "${THIRD_PARTY_MARKER:-}" ]] || : > "$THIRD_PARTY_MARKER"\n' \
    > "$repository/scripts/check-third-party-notices.sh"
  printf '# test repository\n' > "$repository/README.md"
  printf 'module example.invalid/test\n\ngo 1.25\n' > "$repository/go.mod"
  printf 'name: test\non:\n  push:\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5\n' \
    > "$repository/.github/workflows/test.yml"
  git -C "$repository" init -q
  git -C "$repository" config user.name "Mimi Safety Test"
  git -C "$repository" config user.email "safety-test@example.invalid"
  git -C "$repository" add .
  git -C "$repository" commit -q -m baseline
}

repository="$test_root/repository"
create_repository "$repository"
base_sha="$(git -C "$repository" rev-parse HEAD)"

mkdir -p "$repository/internal/example"
printf 'package example\n' > "$repository/internal/example/example.go"
git -C "$repository" add internal/example/example.go
git -C "$repository" commit -q -m ordinary-source
ordinary_head="$(git -C "$repository" rev-parse HEAD)"

plan_output="$(cd "$repository" && bash ./scripts/check-public-repo-safety.sh \
  --pull-request --base "$base_sha" --head "$ordinary_head" --plan)"
assert_contains "$plan_output" "mode=pull-request"
assert_contains "$plan_output" "third_party=false"

third_party_marker="$test_root/ordinary-third-party.marker"
ordinary_output="$(cd "$repository" && THIRD_PARTY_MARKER="$third_party_marker" \
  bash ./scripts/check-public-repo-safety.sh \
    --pull-request --base "$base_sha" --head "$ordinary_head")"
[[ ! -e "$third_party_marker" ]] \
  || fail "普通源码 PR 不应执行第三方许可检查。"
assert_contains "$ordinary_output" "PR 新增提交已扫描，third_party=false"

git -C "$repository" switch -q -c intermediate-secret "$base_sha"
printf -v fake_secret 'github_pat_%040d' 0
printf '%s\n' "$fake_secret" > "$repository/leaked-token.txt"
printf 'placeholder\n' > "$repository/release-signing.p8"
git -C "$repository" add leaked-token.txt release-signing.p8
git -C "$repository" commit -q -m add-sensitive-material
rm "$repository/leaked-token.txt" "$repository/release-signing.p8"
git -C "$repository" add -u
git -C "$repository" commit -q -m remove-sensitive-material
secret_head="$(git -C "$repository" rev-parse HEAD)"
secret_output_path="$test_root/intermediate-secret.output"
if (cd "$repository" && bash ./scripts/check-public-repo-safety.sh \
  --pull-request --base "$base_sha" --head "$secret_head") \
  >"$secret_output_path" 2>&1; then
  fail "PR 中间提交包含 secret 或签名产物时必须失败。"
fi
secret_output="$(<"$secret_output_path")"
assert_contains "$secret_output" "leaked-token.txt"
assert_contains "$secret_output" "release-signing.p8"
assert_not_contains "$secret_output" "$fake_secret"

invalid_output_path="$test_root/invalid-sha.output"
if (cd "$repository" && bash ./scripts/check-public-repo-safety.sh \
  --pull-request --base deadbeef --head "$secret_head" --plan) \
  >"$invalid_output_path" 2>&1; then
  fail "不存在的 base SHA 必须 fail closed。"
fi
assert_contains "$(<"$invalid_output_path")" "base 必须是完整 commit SHA"

git -C "$repository" switch -q -c dependency-change "$base_sha"
git -C "$repository" branch -D intermediate-secret >/dev/null
printf 'module example.invalid/test\n\ngo 1.25\n\nrequire example.invalid/dependency v1.0.0\n' \
  > "$repository/go.mod"
git -C "$repository" add go.mod
git -C "$repository" commit -q -m dependency-change
dependency_head="$(git -C "$repository" rev-parse HEAD)"
dependency_plan="$(cd "$repository" && bash ./scripts/check-public-repo-safety.sh \
  --pull-request --base "$base_sha" --head "$dependency_head" --plan)"
assert_contains "$dependency_plan" "third_party=true"

third_party_marker="$test_root/dependency-third-party.marker"
(cd "$repository" && THIRD_PARTY_MARKER="$third_party_marker" \
  bash ./scripts/check-public-repo-safety.sh \
    --pull-request --base "$base_sha" --head "$dependency_head" >/dev/null)
[[ -f "$third_party_marker" ]] \
  || fail "依赖相关 PR 必须执行第三方许可检查。"

rm -f "$third_party_marker"
(cd "$repository" && THIRD_PARTY_MARKER="$third_party_marker" \
  bash ./scripts/check-public-repo-safety.sh --full-history >/dev/null)
[[ -f "$third_party_marker" ]] \
  || fail "完整历史模式必须执行第三方许可检查。"

old_history_repository="$test_root/old-history-repository"
create_repository "$old_history_repository"
printf -v old_secret 'github_pat_%040d' 1
printf '%s\n' "$old_secret" > "$old_history_repository/old-token.txt"
git -C "$old_history_repository" add old-token.txt
git -C "$old_history_repository" commit -q -m old-sensitive-material
rm "$old_history_repository/old-token.txt"
git -C "$old_history_repository" add -u
git -C "$old_history_repository" commit -q -m remove-old-sensitive-material
old_base="$(git -C "$old_history_repository" rev-parse HEAD)"
printf 'safe\n' > "$old_history_repository/source.txt"
git -C "$old_history_repository" add source.txt
git -C "$old_history_repository" commit -q -m pull-request-change
old_head="$(git -C "$old_history_repository" rev-parse HEAD)"

(cd "$old_history_repository" && bash ./scripts/check-public-repo-safety.sh \
  --pull-request --base "$old_base" --head "$old_head" >/dev/null)
old_full_output_path="$test_root/old-full-history.output"
if (cd "$old_history_repository" && bash ./scripts/check-public-repo-safety.sh --full-history) \
  >"$old_full_output_path" 2>&1; then
  fail "完整历史模式必须发现 base 之前的历史 secret。"
fi
assert_contains "$(<"$old_full_output_path")" "old-token.txt"
assert_not_contains "$(<"$old_full_output_path")" "$old_secret"

rm -rf "$test_root"
trap - EXIT

echo "公开仓库门禁自测通过：PR 中间提交、完整历史、SHA 校验与第三方许可分流均符合预期。"
