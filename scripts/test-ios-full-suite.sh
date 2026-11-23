#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/test-ios-full-suite.sh [--result-dir <目录>] [--record-failed-snapshots]

在固定的 iPad Pro 13-inch (M5) Simulator 上运行全量 MimiRemoteTests（含全部视觉快照类），
只对 config/ios-tests/quarantine.tsv 中登记的单个用例传 -skip-testing。失败的用例重试一次：
重试后通过的记为抖动，列在摘要里但不算失败；两次都失败才算失败。跑完后按类核对实际
执行数：任何一个应执行的类执行 0 个、执行数与源码清单不一致，或有失败用例，都返回非零。

结果目录保存 full.xcresult、tests.json 与按类统计的 summary.md；默认放在临时目录。
在 GitHub Actions 中会把统计表追加到 $GITHUB_STEP_SUMMARY。

--record-failed-snapshots 让不匹配的快照就地重录，并把重录的 PNG 按仓库相对路径复制到
结果目录的 rerecorded-snapshots/。重录后的重试会对着新图通过，所以只要有快照被重录，
就单独判失败，不算抖动。快照基线只认每晚任务
的环境（GitHub 托管 macos-26 + iOS 26.2 的 M5 Simulator），本机不同版本的 Xcode 不要用它
重录。
EOF
}

result_dir=""
record_failed_snapshots=false
snapshot_status=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --result-dir)
      [[ "$#" -ge 2 ]] || { echo "--result-dir 缺少目录。" >&2; exit 2; }
      result_dir="$2"
      shift 2
      ;;
    --record-failed-snapshots)
      record_failed_snapshots=true
      shift
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

snapshot_dir="ios/MimiRemote/Tests/MimiRemoteTests/__Snapshots__"
if [[ "$record_failed_snapshots" == true ]]; then
  # xcodebuild 把 TEST_RUNNER_ 前缀的变量去掉前缀后传给测试进程；SnapshotTesting 只重写不匹配的基线。
  export TEST_RUNNER_SNAPSHOT_TESTING_RECORD=failed
  [[ -z "$(git status --porcelain --untracked-files=all -- "$snapshot_dir")" ]] || {
    echo "${snapshot_dir} 有未提交改动，重录前请先清理，避免混入重录结果。" >&2
    exit 2
  }
fi

is_safe_snapshot_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  [[ "$path" != *\\* ]] || return 1
  [[ "$path" == "${snapshot_dir}/"* ]] || return 1
  case "/${path}/" in
    */../*|*/./*|*//*) return 1 ;;
  esac
  return 0
}

rerecorded_list=""
rerecorded_count=0
snapshot_collection_error=false

append_rerecorded_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && "$record_failed_snapshots" == true && -f "$rerecorded_list" ]]; then
    {
      echo
      echo "## 重录快照（${rerecorded_count} 张，需逐张核对后再提交）"
      echo
      if [[ "$rerecorded_count" -gt 0 ]]; then
        while IFS= read -r item; do
          [[ -n "$item" ]] || continue
          printf -- '- %s\n' "$item"
        done < "$rerecorded_list"
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

test_status=0
bash ./scripts/ios-dev.sh test \
  -quiet \
  -resultBundlePath "$result_bundle" \
  -collect-test-diagnostics never \
  -testLanguage zh-Hans \
  -testRegion CN \
  -retry-tests-on-failure \
  -test-iterations 2 \
  ${skip_args[@]+"${skip_args[@]}"} || test_status=$?

# 在结果分类前先采集本次 run 重录的快照，既确保重录 artifact 不因后续步骤丢失，
# 也让 verify-results 把重录快照漂移从抖动统计中剥离。
if [[ "$record_failed_snapshots" == true ]]; then
  rerecorded_list="$result_dir/rerecorded-snapshots.txt"
  : > "$rerecorded_list"
  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || continue
    xy="${entry:0:2}"
    snapshot_path="${entry:3}"
    # -z 模式下 rename/copy 记录后面紧跟 NUL 分隔的原路径，需一并消费。
    if [[ "$xy" == *R* || "$xy" == *C* ]]; then
      IFS= read -r -d '' _old_snapshot_path || true
    fi
    if ! is_safe_snapshot_path "$snapshot_path"; then
      safe_label="${snapshot_path//$'\n'/\\n}"
      safe_label="${safe_label//$'\r'/\\r}"
      echo "检测到不安全的快照路径变更，拒绝复制：${safe_label}" >&2
      printf 'UNSAFE_PATH:%s\n' "$safe_label" >> "$rerecorded_list"
      rerecorded_count=$((rerecorded_count + 1))
      snapshot_collection_error=true
      snapshot_status=1
      continue
    fi
    if [[ ! -f "$snapshot_path" || -L "$snapshot_path" ]]; then
      echo "快照路径不是常规文件（可能已删除或是符号链接），无法作为重录图复制：${snapshot_path}" >&2
      printf 'INVALID_SNAPSHOT_FILE:%s\n' "$snapshot_path" >> "$rerecorded_list"
      rerecorded_count=$((rerecorded_count + 1))
      snapshot_collection_error=true
      snapshot_status=1
      continue
    fi
    printf '%s\n' "$snapshot_path" >> "$rerecorded_list"
    mkdir -p -- "$result_dir/rerecorded-snapshots/$(dirname -- "$snapshot_path")"
    cp -- "$snapshot_path" "$result_dir/rerecorded-snapshots/$snapshot_path"
    rerecorded_count=$((rerecorded_count + 1))
  done < <(git status --porcelain -z --untracked-files=all -- "$snapshot_dir")
  echo "重录快照：${rerecorded_count} 张（清单：${rerecorded_list}）"
  if [[ "$rerecorded_count" -gt 0 ]]; then
    # 首次比对失败时已写入新图，重试会对着新图通过；快照不匹配一律判失败，不算抖动。
    snapshot_status=1
  fi
fi

if [[ ! -d "$result_bundle" ]]; then
  append_rerecorded_summary
  if [[ "${GITHUB_ACTIONS:-}" == "true" && "$rerecorded_count" -gt 0 ]]; then
    echo "::error title=快照漂移（已重录，未知）::未生成测试结果包，无法把 ${rerecorded_count} 张重录快照映射到具体用例"
  fi
  echo "没有生成 ${result_bundle}（xcodebuild 退出码 ${test_status}），无法核对执行数。" >&2
  echo "结果目录：$result_dir"
  exit "$(( test_status == 0 ? 1 : test_status ))"
fi

xcrun xcresulttool get test-results tests --path "$result_bundle" > "$result_dir/tests.json"
verify_args=()
if [[ "$record_failed_snapshots" == true ]]; then
  verify_args+=(--rerecorded-list "$rerecorded_list")
fi
verify_status=0
python3 ./scripts/ios-test-inventory.py verify-results \
  "$result_dir/tests.json" \
  --markdown "$result_dir/summary.md" \
  ${verify_args[@]+"${verify_args[@]}"} || verify_status=$?

if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -f "$result_dir/summary.md" ]]; then
  {
    echo "## iOS 全量 XCTest 按类执行数"
    echo
    cat "$result_dir/summary.md"
  } >> "$GITHUB_STEP_SUMMARY"
fi
append_rerecorded_summary

if [[ "$test_status" -ne 0 ]]; then
  # quiet 日志只列用例名；保留具体断言，诊断失败也不能覆盖原退出码。
  xcrun xcresulttool get test-results summary --path "$result_bundle" || true
fi
echo "结果目录：$result_dir"
if [[ "$test_status" -ne 0 ]]; then
  exit "$test_status"
fi
if [[ "$snapshot_status" -ne 0 ]]; then
  if [[ "$snapshot_collection_error" == true ]]; then
    echo "采集重录快照时检测到异常路径或非文件变更，已阻断通过。" >&2
  else
    echo "有快照与基线不匹配并已重录；逐张核对 rerecorded-snapshots/ 后再提交。" >&2
  fi
  exit "$snapshot_status"
fi
exit "$verify_status"
