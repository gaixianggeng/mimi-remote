#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTION_LIMIT=2000
TEST_LIMIT=2500
failed=0

# 例外必须精确到文件并写明原因，禁止使用目录或通配符绕过门禁。
exception_reason() {
  case "$1" in
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationSessionStoreTests.swift)
      printf '%s' '历史会话状态回归矩阵，后续按恢复、审批和消息域拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationComposerHistoryTests.swift)
      printf '%s' 'Composer 历史交互回归矩阵，后续按输入与历史导航场景拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationDataFlowTests.swift)
      printf '%s' '会话数据流回归矩阵，后续按流式事件、审批和附件场景拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift)
      printf '%s' '运行时切换与消息流回归矩阵，后续按运行时选择和会话执行场景拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationWorkspaceHistoryTests.swift)
      printf '%s' 'Workspace 历史回归矩阵，后续按目录解析与会话恢复场景拆分'
      ;;
    ios/MimiRemote/Sources/Core/API/CodexAppServerSessionRuntime.swift)
      printf '%s' 'Codex 协议兼容运行时，后续按连接、请求和事件处理职责拆分'
      ;;
    ios/MimiRemote/Sources/Core/Models/AgentModels.swift)
      printf '%s' '跨版本协议兼容模型集合，后续按会话、工具和账户模型拆分'
      ;;
    internal/httpapi/appserver_gateway_test.go)
      printf '%s' 'App Server 网关回归矩阵，后续按鉴权、会话和历史消息场景拆分'
      ;;
    internal/httpapi/appserver_gateway_policy_test.go)
      printf '%s' 'App Server 网关 writer 与反向响应策略回归矩阵，后续按请求和响应策略拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/CodexAppServerProtocolTests.swift)
      printf '%s' 'Codex App Server 协议兼容回归矩阵，后续按传输与反向请求职责拆分'
      ;;
    ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeTests.swift)
      printf '%s' '直接 Runtime 会话与拒绝恢复回归矩阵，后续按审批和会话生命周期拆分'
      ;;
    cmd/agentd/main.go)
      printf '%s' 'agentd 启动与共享 Runtime 状态编排入口，后续按 serve 和状态检查职责拆分'
      ;;
    internal/httpapi/router_test.go)
      printf '%s' 'HTTP 路由回归矩阵，后续按配对、项目和运行时端点拆分'
      ;;
    ios/MimiRemote/Sources/State/SessionStoreConnection.swift)
      printf '%s' '会话连接、事件归并与本地状态兼容逻辑，后续按连接生命周期和状态职责拆分'
      ;;
    ios/MimiRemote/Sources/State/SessionStoreHistory.swift)
      printf '%s' '会话创建、历史加载与列表恢复逻辑，后续按历史分页、列表和恢复职责拆分'
      ;;
    *) return 1 ;;
  esac
}

is_excluded() {
  case "$1" in
    .git/*|vendor/*|*/vendor/*|*/Pods/*|*/Carthage/*|*/SourcePackages/*|*/DerivedData/*|*/.build/*|*/build/*|*/__Snapshots__/*)
      return 0
      ;;
    # .NET 的编译输出和 XAML 生成代码不是手写源码，不能计入体积门禁。
    */obj/*|*/bin/*)
      return 0
      ;;
    *.pb.go|*.gen.go|*_generated.go|*.generated.swift|*/Generated*.swift|*.g.cs|*.g.i.cs)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

needs_single_file_wc() {
  case "$1" in
    *$'\n'*|*$'\r'*|*[[:cntrl:]]*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_file_line_count() {
  local source_file="$1"
  local line_count="$2"
  local relative_path limit reason

  if [[ ! "$line_count" =~ ^[0-9]+$ ]]; then
    printf '源码体积检查失败：无法解析行数（%s -> %q）\n' "$source_file" "$line_count" >&2
    exit 1
  fi

  relative_path="${source_file#"$ROOT_DIR"/}"
  limit=$PRODUCTION_LIMIT
  case "$relative_path" in
    *_test.go|*/Tests/*|*Tests.swift|*TestSupport.swift|*/tests/*|*Tests.cs)
      limit=$TEST_LIMIT
      ;;
  esac

  if (( 10#$line_count <= limit )); then
    return 0
  fi

  if reason="$(exception_reason "$relative_path")"; then
    printf '源码体积例外：%s (%s 行，上限 %s)：%s\n' "$relative_path" "$line_count" "$limit" "$reason"
    return 0
  fi

  printf '源码体积超限：%s (%s 行，上限 %s)\n' "$relative_path" "$line_count" "$limit" >&2
  failed=1
}

check_single_file() {
  local source_file="$1"
  local raw_count line_count wc_status

  wc_status=0
  raw_count="$(wc -l < "$source_file")" || wc_status=$?
  if (( wc_status != 0 )); then
    printf '源码体积检查失败：无法读取文件行数（退出码 %s）：%s\n' "$wc_status" "$source_file" >&2
    exit 1
  fi

  line_count="${raw_count#"${raw_count%%[![:space:]]*}"}"
  line_count="${line_count%"${line_count##*[![:space:]]}"}"
  check_file_line_count "$source_file" "$line_count"
}

check_batch_files() {
  if (( $# == 0 )); then
    return 0
  fi

  local batch=("$@")
  local batch_len="${#batch[@]}"
  local wc_status=0 wc_output=""
  local line_num=0 expected_total=0 expected_lines=$batch_len
  local wc_line source_file trimmed line_count parsed_path total_count total_label

  wc_output="$(wc -l -- "${batch[@]}" && printf 'x')" || wc_status=$?
  if (( wc_status != 0 )); then
    printf '源码体积检查失败：批量 wc 读取失败（退出码 %s）。\n' "$wc_status" >&2
    exit 1
  fi
  if [[ "$wc_output" != *x ]]; then
    printf '源码体积检查失败：批量 wc 输出异常截断。\n' >&2
    exit 1
  fi
  wc_output="${wc_output%x}"
  if [[ -z "$wc_output" || "$wc_output" != *$'\n' ]]; then
    printf '源码体积检查失败：批量 wc 输出为空或缺少行尾换行。\n' >&2
    exit 1
  fi

  while IFS= read -r wc_line; do
    if (( line_num < batch_len )); then
      source_file="${batch[$line_num]}"
      trimmed="${wc_line#"${wc_line%%[! ]*}"}"
      line_count="${trimmed%% *}"
      if [[ ! "$line_count" =~ ^[0-9]+$ ]] || [[ "$trimmed" != "$line_count "* ]]; then
        printf '源码体积检查失败：批量 wc 输出格式异常：%s\n' "$wc_line" >&2
        exit 1
      fi
      parsed_path="${trimmed#"$line_count "}"
      if [[ "$parsed_path" != "$source_file" ]]; then
        printf '源码体积检查失败：批量 wc 输出路径不匹配（期望 %s，实际 %s）\n' "$source_file" "$parsed_path" >&2
        exit 1
      fi
      expected_total=$((expected_total + 10#$line_count))
      check_file_line_count "$source_file" "$line_count"
    elif (( batch_len > 1 && line_num == batch_len )); then
      trimmed="${wc_line#"${wc_line%%[! ]*}"}"
      total_count="${trimmed%% *}"
      total_label="${trimmed#"$total_count "}"
      if [[ ! "$total_count" =~ ^[0-9]+$ ]] \
        || [[ "$trimmed" != "$total_count "* ]] \
        || [[ -z "$total_label" || "$total_label" == */* ]] \
        || (( 10#$total_count != expected_total )); then
        printf '源码体积检查失败：批量 wc 汇总行异常：%s\n' "$wc_line" >&2
        exit 1
      fi
    else
      printf '源码体积检查失败：批量 wc 输出行数超出预期：%s\n' "$wc_line" >&2
      exit 1
    fi
    line_num=$((line_num + 1))
  done < <(printf '%s' "$wc_output")

  if (( batch_len > 1 )); then
    expected_lines=$((batch_len + 1))
  fi
  if (( line_num != expected_lines )); then
    printf '源码体积检查失败：批量 wc 输出记录数不匹配（期望 %s，实际 %s）\n' "$expected_lines" "$line_num" >&2
    exit 1
  fi
}

batch_files=()
fallback_files=()
while IFS= read -r -d '' source_file; do
  relative_path="${source_file#"$ROOT_DIR"/}"
  if is_excluded "$relative_path"; then
    continue
  fi
  if needs_single_file_wc "$source_file"; then
    fallback_files+=("$source_file")
  else
    batch_files+=("$source_file")
  fi
done < <(find "$ROOT_DIR" -type f \( -name '*.swift' -o -name '*.go' -o -name '*.cs' -o -name '*.xaml' \) -print0)

total_batch_files="${#batch_files[@]}"
batch_size=200
offset=0
while (( offset < total_batch_files )); do
  check_batch_files "${batch_files[@]:offset:batch_size}"
  offset=$((offset + batch_size))
done

total_fallback_files="${#fallback_files[@]}"
for (( idx = 0; idx < total_fallback_files; idx++ )); do
  check_single_file "${fallback_files[$idx]}"
done

if (( failed != 0 )); then
  printf '请按职责拆分文件；确需例外时，在 scripts/check-source-size.sh 中写明精确路径和原因。\n' >&2
  exit 1
fi

printf '源码体积检查通过：生产文件 <= %s 行，测试文件 <= %s 行。\n' "$PRODUCTION_LIMIT" "$TEST_LIMIT"
