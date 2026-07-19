#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTION_LIMIT=2000
TEST_LIMIT=2500
failed=0

# 例外必须精确到文件并写明原因；当前重构后不需要任何例外。
exception_reason() {
  case "$1" in
    # 示例：internal/example/legacy.go) printf '%s' '等待上游协议生成器拆分' ;;
    *) return 1 ;;
  esac
}

is_excluded() {
  case "$1" in
    .git/*|vendor/*|*/vendor/*|*/Pods/*|*/Carthage/*|*/SourcePackages/*|*/DerivedData/*|*/.build/*|*/build/*|*/__Snapshots__/*)
      return 0
      ;;
    *.pb.go|*.gen.go|*_generated.go|*.generated.swift|*/Generated*.swift)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r -d '' source_file; do
  relative_path="${source_file#"$ROOT_DIR"/}"
  if is_excluded "$relative_path"; then
    continue
  fi

  limit=$PRODUCTION_LIMIT
  case "$relative_path" in
    *_test.go|*/Tests/*|*Tests.swift|*TestSupport.swift)
      limit=$TEST_LIMIT
      ;;
  esac

  line_count="$(wc -l < "$source_file" | tr -d '[:space:]')"
  if (( line_count <= limit )); then
    continue
  fi

  if reason="$(exception_reason "$relative_path")"; then
    printf '源码体积例外：%s (%s 行，上限 %s)：%s\n' "$relative_path" "$line_count" "$limit" "$reason"
    continue
  fi

  printf '源码体积超限：%s (%s 行，上限 %s)\n' "$relative_path" "$line_count" "$limit" >&2
  failed=1
done < <(find "$ROOT_DIR" -type f \( -name '*.swift' -o -name '*.go' \) -print0)

if (( failed != 0 )); then
  printf '请按职责拆分文件；确需例外时，在 scripts/check-source-size.sh 中写明精确路径和原因。\n' >&2
  exit 1
fi

printf '源码体积检查通过：生产文件 <= %s 行，测试文件 <= %s 行。\n' "$PRODUCTION_LIMIT" "$TEST_LIMIT"
