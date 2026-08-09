#!/usr/bin/env bash
set -euo pipefail

readonly EXPECTED_REPOSITORY="gaixianggeng/mimi-remote"
readonly SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly REPOSITORY_ROOT="${MIMI_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "Release 来源信任门失败：$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令 $1。"
}

verify_source() {
  require_command git

  cd "$REPOSITORY_ROOT"

  [[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" ]] \
    || fail "只能在官方仓库 ${EXPECTED_REPOSITORY} 运行。"
  [[ "${GITHUB_EVENT_NAME:-}" == "repository_dispatch" ]] \
    || fail "只能通过默认分支上的受信 repository_dispatch 入口发布。"
  [[ "${GITHUB_REF:-}" == "refs/heads/main" && "${GITHUB_REF_NAME:-}" == "main" ]] \
    || fail "发布工作流必须固定从 main 分支加载。"
  [[ "${RELEASE_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "tag 必须使用 vX.Y.Z 格式。"
  [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] \
    || fail "workflow SHA 不是完整的小写 commit SHA。"

  local head_sha
  local workflow_sha
  local tag_sha
  local main_sha
  head_sha="$(git rev-parse --verify 'HEAD^{commit}')" \
    || fail "无法解析 checkout commit。"
  workflow_sha="$(git rev-parse --verify "${GITHUB_SHA}^{commit}")" \
    || fail "无法把 workflow SHA 解析为 commit。"
  tag_sha="$(git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}")" \
    || fail "无法把发布 tag 解析为 commit。"

  [[ "$head_sha" == "$workflow_sha" ]] \
    || fail "trust job 没有 checkout 受信 workflow commit。"

  # 核心边界：只从官方 origin 读取 main，不信任 runner 上可能陈旧的本地引用。
  git fetch --quiet --no-tags origin \
    +refs/heads/main:refs/remotes/origin/main \
    || fail "无法读取官方 origin/main。"
  main_sha="$(git rev-parse --verify 'refs/remotes/origin/main^{commit}')" \
    || fail "无法解析 origin/main。"
  [[ "$workflow_sha" == "$main_sha" ]] \
    || fail "workflow 不是从当前 origin/main 加载；请从 main 重新触发。"
  git merge-base --is-ancestor "$tag_sha" "$main_sha" \
    || fail "tag commit 尚未进入 origin/main。"

  # 下游只 checkout 已验证的不可变 SHA，避免 tag 在 job 之间发生 TOCTOU 漂移。
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'tag_sha=%s\n' "$tag_sha" >> "$GITHUB_OUTPUT"
  fi

  echo "Release 来源信任门通过：受信 workflow ${workflow_sha} 从 main 加载；${RELEASE_TAG} -> ${tag_sha} 已包含于 origin/main。"
}

run_self_test() {
  require_command git
  require_command mktemp

  local test_root
  local origin_path
  local seed_path
  local checkout_path
  local release_sha
  local previous_main_sha
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/mimi-release-source-self-test.XXXXXX")"
  origin_path="$test_root/origin.git"
  seed_path="$test_root/seed"
  checkout_path="$test_root/checkout"
  trap 'rm -rf "$test_root"' RETURN

  git init --quiet --bare "$origin_path"
  git init --quiet "$seed_path"
  git -C "$seed_path" config user.name "Mimi Release Self Test"
  git -C "$seed_path" config user.email "release-self-test@example.invalid"
  git -C "$seed_path" checkout --quiet -b main
  printf 'main-1\n' > "$seed_path/source.txt"
  git -C "$seed_path" add source.txt
  git -C "$seed_path" commit --quiet -m "main one"
  previous_main_sha="$(git -C "$seed_path" rev-parse HEAD)"
  printf 'main-2\n' >> "$seed_path/source.txt"
  git -C "$seed_path" commit --quiet -am "main two"
  release_sha="$(git -C "$seed_path" rev-parse HEAD)"
  git -C "$seed_path" tag v1.2.3
  git -C "$seed_path" remote add origin "$origin_path"
  git -C "$seed_path" push --quiet origin main refs/tags/v1.2.3

  git -C "$seed_path" checkout --quiet -b off-main
  printf 'off-main\n' >> "$seed_path/source.txt"
  git -C "$seed_path" commit --quiet -am "off main"
  git -C "$seed_path" tag v9.9.9
  git -C "$seed_path" push --quiet origin refs/tags/v9.9.9

  git clone --quiet "$origin_path" "$checkout_path"
  git -C "$checkout_path" checkout --quiet main
  MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
    GITHUB_REPOSITORY="$EXPECTED_REPOSITORY" \
    GITHUB_EVENT_NAME="repository_dispatch" \
    GITHUB_REF="refs/heads/main" \
    GITHUB_REF_NAME="main" \
    GITHUB_SHA="$release_sha" \
    RELEASE_TAG="v1.2.3" \
    "$SCRIPT_PATH" --check >/dev/null

  expect_failure() {
    local case_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      fail "self-test ${case_name} 本应失败但通过。"
    fi
  }

  expect_failure wrong-repository \
    env MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
      GITHUB_REPOSITORY="someone/fork" \
      GITHUB_EVENT_NAME="repository_dispatch" \
      GITHUB_REF="refs/heads/main" \
      GITHUB_REF_NAME="main" \
      GITHUB_SHA="$release_sha" \
      RELEASE_TAG="v1.2.3" \
      "$SCRIPT_PATH" --check
  expect_failure malformed-tag \
    env MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
      GITHUB_REPOSITORY="$EXPECTED_REPOSITORY" \
      GITHUB_EVENT_NAME="repository_dispatch" \
      GITHUB_REF="refs/heads/main" \
      GITHUB_REF_NAME="main" \
      GITHUB_SHA="$release_sha" \
      RELEASE_TAG="v1" \
      "$SCRIPT_PATH" --check
  expect_failure stale-workflow-sha \
    env MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
      GITHUB_REPOSITORY="$EXPECTED_REPOSITORY" \
      GITHUB_EVENT_NAME="repository_dispatch" \
      GITHUB_REF="refs/heads/main" \
      GITHUB_REF_NAME="main" \
      GITHUB_SHA="$previous_main_sha" \
      RELEASE_TAG="v1.2.3" \
      "$SCRIPT_PATH" --check
  expect_failure untrusted-workflow-ref \
    env MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
      GITHUB_REPOSITORY="$EXPECTED_REPOSITORY" \
      GITHUB_EVENT_NAME="repository_dispatch" \
      GITHUB_REF="refs/tags/v1.2.3" \
      GITHUB_REF_NAME="v1.2.3" \
      GITHUB_SHA="$release_sha" \
      RELEASE_TAG="v1.2.3" \
      "$SCRIPT_PATH" --check

  expect_failure off-main-tag \
    env MIMI_RELEASE_SOURCE_ROOT="$checkout_path" \
      GITHUB_REPOSITORY="$EXPECTED_REPOSITORY" \
      GITHUB_EVENT_NAME="repository_dispatch" \
      GITHUB_REF="refs/heads/main" \
      GITHUB_REF_NAME="main" \
      GITHUB_SHA="$release_sha" \
      RELEASE_TAG="v9.9.9" \
      "$SCRIPT_PATH" --check

  echo "Release 来源信任门自测通过：default-branch dispatch + main tag 通过，错误仓库、非法 tag、非 main workflow ref、SHA/checkout 漂移与非 main tag 均被拒绝。"
}

case "${1:---check}" in
  --check)
    verify_source
    ;;
  --self-test)
    run_self_test
    ;;
  *)
    fail "用法：bash ./scripts/check-release-source.sh [--check|--self-test]"
    ;;
esac
