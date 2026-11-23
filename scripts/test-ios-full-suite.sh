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
snapshot_git_status_file=""
cleanup_temp_files() {
  if [[ -n "$snapshot_git_status_file" ]]; then
    rm -f -- "$snapshot_git_status_file"
  fi
}
trap cleanup_temp_files EXIT

if [[ "$record_failed_snapshots" == true ]]; then
  # xcodebuild 把 TEST_RUNNER_ 前缀的变量去掉前缀后传给测试进程；SnapshotTesting 只重写不匹配的基线。
  export TEST_RUNNER_SNAPSHOT_TESTING_RECORD=failed
  pre_status_output=""
  pre_status_code=0
  pre_status_output="$(git status --porcelain --untracked-files=all -- "$snapshot_dir")" || pre_status_code=$?
  if [[ "$pre_status_code" -ne 0 ]]; then
    echo "重录前查询 ${snapshot_dir} 的 git 状态失败（退出码 ${pre_status_code}）。" >&2
    exit "$pre_status_code"
  fi
  if [[ -n "$pre_status_output" ]]; then
    echo "${snapshot_dir} 有未提交改动，重录前请先清理，避免混入重录结果。" >&2
    exit 2
  fi
fi

is_safe_snapshot_path() {
  local path="$1"
  local LC_ALL=C
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  case "$path" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  [[ "$path" != *\\* ]] || return 1
  [[ "$path" == "${snapshot_dir}/"* ]] || return 1
  case "/${path}/" in
    */../*|*/./*|*//*) return 1 ;;
  esac
  return 0
}

sanitize_label() {
  local raw="$1"
  local sanitized=""
  if sanitized="$(python3 -c 'import sys; s = sys.argv[1]; print("".join(f"\\x{ord(c) - 0xdc00:02x}" if 0xdc80 <= ord(c) <= 0xdcff else (f"\\x{ord(c):02x}" if (ord(c) < 32 or ord(c) == 127 or 0x80 <= ord(c) <= 0x9f) else (f"\\u{ord(c):04x}" if c in ("\u2028", "\u2029") else c)) for c in s))' "$raw" 2>/dev/null)"; then
    printf '%s' "$sanitized"
    return 0
  fi
  sanitized="${raw//$'\n'/\\n}"
  sanitized="${sanitized//$'\r'/\\r}"
  printf '%s' "$sanitized"
}

escape_github_annotation() {
  local text
  text="$(sanitize_label "$1")"
  text="${text//%/%25}"
  printf '%s' "$text"
}

rerecorded_list=""
rerecorded_count=0
rerecorded_copied_count=0
snapshot_collection_error=false
snapshot_list_incomplete=false
collection_errors=()

append_rerecorded_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && "$record_failed_snapshots" == true && ( -f "$rerecorded_list" || "${#collection_errors[@]}" -gt 0 ) ]]; then
    {
      echo
      if [[ "$snapshot_list_incomplete" == true ]]; then
        echo "## 重录快照（采集失败，清单不完整，已采集 ${rerecorded_count} 张）"
      else
        echo "## 重录快照（${rerecorded_count} 张，需逐张核对后再提交）"
      fi
      echo
      if [[ "${#collection_errors[@]}" -gt 0 ]]; then
        echo "重录快照采集错误："
        for err_item in "${collection_errors[@]}"; do
          printf -- '- %s\n' "$err_item"
        done
        echo
      fi
      if [[ -f "$rerecorded_list" && "$rerecorded_count" -gt 0 ]]; then
        while IFS= read -r item || [[ -n "$item" ]]; do
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
  snapshot_git_status_file="$(mktemp "${TMPDIR:-/tmp}/mimi-ios-snapshot-status.XXXXXX")"
  post_status_code=0
  git status --porcelain -z --untracked-files=all -- "$snapshot_dir" > "$snapshot_git_status_file" || post_status_code=$?
  if [[ "$post_status_code" -ne 0 ]]; then
    err_msg="测试后查询 ${snapshot_dir} 的 git 状态失败（退出码 ${post_status_code}），无法确认重录快照清单"
    echo "${err_msg}。" >&2
    collection_errors+=("$err_msg")
    snapshot_collection_error=true
    snapshot_list_incomplete=true
    snapshot_status=1
  fi
  if [[ -s "$snapshot_git_status_file" ]]; then
    while IFS= read -r -d '' entry || [[ -n "$entry" ]]; do
      [[ -n "$entry" ]] || continue
      xy="${entry:0:2}"
      snapshot_path="${entry:3}"
      # -z 模式下 rename/copy 记录后面紧跟 NUL 分隔的原路径，需一并消费。
      if [[ "$xy" == *R* || "$xy" == *C* ]]; then
        IFS= read -r -d '' _old_snapshot_path || true
      fi
      if ! is_safe_snapshot_path "$snapshot_path"; then
        safe_label="$(sanitize_label "$snapshot_path")"
        echo "检测到不安全的快照路径变更，拒绝复制：${safe_label}" >&2
        printf 'UNSAFE_PATH:%s\n' "$safe_label" >> "$rerecorded_list"
        rerecorded_count=$((rerecorded_count + 1))
        snapshot_collection_error=true
        snapshot_status=1
        continue
      fi
      if [[ ! -f "$snapshot_path" || -L "$snapshot_path" ]]; then
        safe_label="$(sanitize_label "$snapshot_path")"
        echo "快照路径不是常规文件（可能已删除或是符号链接），无法作为重录图复制：${safe_label}" >&2
        printf 'INVALID_SNAPSHOT_FILE:%s\n' "$safe_label" >> "$rerecorded_list"
        rerecorded_count=$((rerecorded_count + 1))
        snapshot_collection_error=true
        snapshot_status=1
        continue
      fi
      printf '%s\n' "$snapshot_path" >> "$rerecorded_list"
      rerecorded_count=$((rerecorded_count + 1))
      copy_target_dir="$result_dir/rerecorded-snapshots/$(dirname -- "$snapshot_path")"
      if mkdir -p -- "$copy_target_dir" && cp -- "$snapshot_path" "$result_dir/rerecorded-snapshots/$snapshot_path"; then
        rerecorded_copied_count=$((rerecorded_copied_count + 1))
      else
        safe_label="$(sanitize_label "$snapshot_path")"
        err_msg="复制重录快照失败：${safe_label}"
        echo "${err_msg}。" >&2
        collection_errors+=("$err_msg")
        snapshot_collection_error=true
        snapshot_status=1
      fi
    done < "$snapshot_git_status_file"
  fi
  rm -f -- "$snapshot_git_status_file"
  snapshot_git_status_file=""
  echo "重录快照：${rerecorded_count} 张（已复制 ${rerecorded_copied_count} 张，清单：${rerecorded_list}）"
  if [[ "$rerecorded_count" -gt 0 ]]; then
    # 首次比对失败时已写入新图，重试会对着新图通过；快照不匹配一律判失败，不算抖动。
    snapshot_status=1
  fi
fi

if [[ ! -d "$result_bundle" ]]; then
  append_rerecorded_summary
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ "${#collection_errors[@]}" -gt 0 ]]; then
      for err_item in "${collection_errors[@]}"; do
        echo "::error title=重录快照采集失败::$(escape_github_annotation "$err_item")"
      done
    fi
    if [[ "$rerecorded_count" -gt 0 ]]; then
      echo "::error title=快照漂移（已重录，未知）::未生成测试结果包，无法把 ${rerecorded_count} 张重录快照映射到具体用例"
    elif [[ "$snapshot_list_incomplete" == true ]]; then
      echo "::error title=快照漂移（已重录，未知）::未生成测试结果包且重录快照采集失败，无法确认重录清单与归属"
    fi
  fi
  echo "没有生成 ${result_bundle}（xcodebuild 退出码 ${test_status}），无法核对执行数。" >&2
  echo "结果目录：$result_dir"
  exit "$(( test_status == 0 ? 1 : test_status ))"
fi

extract_status=0
xcrun xcresulttool get test-results tests --path "$result_bundle" > "$result_dir/tests.json" || extract_status=$?
if [[ "$extract_status" -ne 0 ]]; then
  echo "从 ${result_bundle} 提取测试结果失败（xcresulttool 退出码 ${extract_status}），无法核对执行数。" >&2
fi

verify_args=()
if [[ "$record_failed_snapshots" == true ]]; then
  verify_args+=(--rerecorded-list "$rerecorded_list")
  if [[ "$snapshot_list_incomplete" == true ]]; then
    verify_args+=(--rerecorded-incomplete)
  fi
  if [[ "${#collection_errors[@]}" -gt 0 ]]; then
    for err_item in "${collection_errors[@]}"; do
      verify_args+=(--collection-error "$err_item")
    done
  fi
fi
if [[ "$extract_status" -ne 0 ]]; then
  verify_args+=(--results-error "从 ${result_bundle} 提取测试结果失败（xcresulttool 退出码 ${extract_status}）")
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

if [[ "$test_status" -ne 0 || "$extract_status" -ne 0 ]]; then
  # quiet 日志只列用例名；保留具体断言，诊断失败也不能覆盖原退出码。
  xcrun xcresulttool get test-results summary --path "$result_bundle" || true
fi
echo "结果目录：$result_dir"
if [[ "$test_status" -ne 0 ]]; then
  exit "$test_status"
fi
if [[ "$extract_status" -ne 0 ]]; then
  if [[ "$snapshot_status" -ne 0 ]]; then
    echo "存在未完成归属的重录快照或采集错误，请同时检查 summary.md 与 rerecorded-snapshots/。" >&2
  fi
  exit "$extract_status"
fi
if [[ "$snapshot_status" -ne 0 ]]; then
  if [[ "$snapshot_collection_error" == true ]]; then
    echo "采集重录快照时发生错误（含状态查询失败、复制失败或异常路径/非文件变更），已阻断通过。" >&2
  else
    echo "有快照与基线不匹配并已重录；逐张核对 rerecorded-snapshots/ 后再提交。" >&2
  fi
  exit "$snapshot_status"
fi
exit "$verify_status"
