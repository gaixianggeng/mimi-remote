#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/test-ios-full-suite.sh [--result-dir <目录>]

在固定的 iPad Pro 13-inch (M5) Simulator 上运行全量 MimiRemoteTests（含全部视觉快照类），
只对 config/ios-tests/quarantine.tsv 中登记的单个用例传 -skip-testing。跑完后按类核对
实际执行数：任何一个应执行的类执行 0 个、执行数与源码清单不一致，或有失败用例，都返回非零。

结果目录保存 full.xcresult、tests.json 与按类统计的 summary.md；默认放在临时目录。
在 GitHub Actions 中会把统计表追加到 $GITHUB_STEP_SUMMARY。
EOF
}

result_dir=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --result-dir)
      [[ "$#" -ge 2 ]] || { echo "--result-dir 缺少目录。" >&2; exit 2; }
      result_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "不支持的参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$result_dir" ]]; then
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-ios-full-suite.XXXXXX")"
fi
mkdir -p "$result_dir"
result_bundle="$result_dir/full.xcresult"
[[ ! -e "$result_bundle" ]] || {
  echo "结果目录里已有 ${result_bundle}，请换一个空目录。" >&2
  exit 2
}

# 先做静态校验：selector、归属或隔离清单有误时，全量结果的按类核对也不可信。
bash ./scripts/check-ios-test-selectors.sh

skip_args=()
while IFS= read -r skip_arg; do
  if [[ -n "$skip_arg" ]]; then
    skip_args+=("$skip_arg")
  fi
done < <(python3 ./scripts/ios-test-inventory.py skip-args)
echo "==> iOS full XCTest（隔离 ${#skip_args[@]} 个用例）"

test_status=0
bash ./scripts/ios-dev.sh test \
  -quiet \
  -resultBundlePath "$result_bundle" \
  -collect-test-diagnostics never \
  -testLanguage zh-Hans \
  -testRegion CN \
  ${skip_args[@]+"${skip_args[@]}"} || test_status=$?

if [[ ! -d "$result_bundle" ]]; then
  echo "没有生成 ${result_bundle}（xcodebuild 退出码 ${test_status}），无法核对执行数。" >&2
  exit "$(( test_status == 0 ? 1 : test_status ))"
fi

xcrun xcresulttool get test-results tests --path "$result_bundle" > "$result_dir/tests.json"
verify_status=0
python3 ./scripts/ios-test-inventory.py verify-results \
  "$result_dir/tests.json" \
  --markdown "$result_dir/summary.md" || verify_status=$?

if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -f "$result_dir/summary.md" ]]; then
  {
    echo "## iOS 全量 XCTest 按类执行数"
    echo
    cat "$result_dir/summary.md"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$test_status" -ne 0 ]]; then
  # quiet 日志只列用例名；保留具体断言，诊断失败也不能覆盖原退出码。
  xcrun xcresulttool get test-results summary --path "$result_bundle" || true
fi
echo "结果目录：$result_dir"
if [[ "$test_status" -ne 0 ]]; then
  exit "$test_status"
fi
exit "$verify_status"
