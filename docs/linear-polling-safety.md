# 问题自动巡检的有界降级与上游边界

当前问题账本已迁移到 GitHub Issues（`gaixianggeng/mimi-remote`）。下文事故证据中的 Linear 指历史系统；guard 命令、目录和文件名保留，以复用原租约。当前执行以 `config/automations/mimi-linear-issue.prompt.md` 和 AGENTS.md 为准，不再从 Linear 派发。

## 目标

Linear 自动巡检不能再因为 Codex Desktop 的一次任务列表查询不返回而持续占用数小时。项目侧必须在无法控制平台工具取消语义的前提下：

- 移除主巡检与阻塞检测器对 `list_threads`、`wait_threads`、`read_thread` 的依赖；
- 让并发或后续心跳在旧轮结果不确定时 fail-closed，不重复创建或恢复任务；
- 记录当前 run、阻塞工具、开始时间、等待时长和降级结论；
- 明确区分项目侧可保证的安全性与 Codex Desktop 必须补齐的强制取消能力。

### 真实故障证据

MIM-55 对应的持久化 rollout 显示：

```text
$CODEX_HOME/sessions/2026/07/29/rollout-2026-07-29T21-49-38-<session-id>.jsonl
```

- 2026-07-31 02:25:11（Asia/Shanghai）协调心跳开始；
- `codex_app.list_threads` call `call_DWfvq7MrBK1VCstXMbkr9dTw` 于 `2026-07-30T18:26:52.246Z` 发起；
- 4 个 Linear 查询在约 4～7 秒内返回；
- 该 call 直到 `2026-07-31T00:57:26.902Z` 才返回，精确等待 23,434.656 秒（6 小时 30 分 34.656 秒）；
- 返回结果为有效 `schemaVersion=4`，`unavailableHosts=[]`，同时包含本地和 `remote-control:env_e_6a2034de7ac4832ea1f164f6f3efeb3b`；工具元数据把后者映射为 `gais-MacBook-Pro.local`；
- 用户 08:54 追问后，原 Turn 于 08:58 被中断。

同一 rollout 有 6 次超过 60 秒且最终返回有效 schema 的 `list_threads`，耗时分别为 299.598、2,346.789、2,292.208、1,629.399、219.416 和 23,434.656 秒。每次结果都包含远端 host，或把远端标记为 `thread_list_unavailable`；与之对照，本地 Desktop `thread/list` 日志只需 5～163 毫秒。

取消与隔离也存在独立缺口：

- 用户在 `2026-07-31T00:54:30Z` 开启新 Turn；
- 新 call `call_9E6c6k16x6NPSeuL3EPSMari` 于 `00:54:54Z` 发出，在该 rollout 中一直没有 output；
- `00:57:26Z` 却先收到上一轮等待 6.5 小时的旧 call output，当前 Turn 随后继续执行；
- `00:58:08Z` 当前 Turn 才被标记为 interrupted。

这说明旧工具 promise 没有随旧 Turn 结束被取消，迟到结果可以跨 Turn 回流。Desktop 26.727.40816（build 6067）重启后的本机日志也对同一远端 host 记录了 `remote control app-server stream became unknown`、持续 `waiting-for-device`，以及每轮约 30 秒的 `Codex app-server initialize handshake timed out`；重连从 01:05:43 至少持续到 02:48，而启动阶段本地 `thread/list` 仍为毫秒级。

实现层失败日志明确包含 `source=thread_list ... timeoutMs=0`：

- 2026-07-29 的历史样本为 `durationMs=299491 ... timeoutMs=0`；
- 2026-07-31 重启后的样本为 `durationMs=35568 ... failureReason=remote_unavailable ... timeoutMs=0`。

后一个样本只在 `remote control app-server stream became unknown` 后才失败并 partial-return。因此问题不是 timeout 配置过长，而是远端请求没有 deadline：连接处于半开状态时可以无限等待。

```text
$HOME/Library/Logs/com.openai.codex/2026/07/31/codex-desktop-<instance-id>.log
```

当前 `list_threads` 工具 schema 只有 `limit`，语义是聚合 local、已连接 remote 和登录历史；没有 `hostId` 过滤、per-host timeout 或 cancellation 参数。因此，本次故障的已证实触发源是远端 remote-control app-server 连接/握手不健康；阻塞被放大到 6.5 小时的架构根因是全局 fan-out 缺少 per-source deadline / partial fail-open，且 Turn 中断没有传播到未决工具调用。远端设备为何掉线可能涉及睡眠、网络或远端进程，但现有本机日志不足以继续细分，不能猜测。

`codex_app.list_threads` 是 Codex Desktop 提供给 Agent 的内置任务协调工具，不经过本仓库的 `agentd` 或 `internal/appserver.Client`。仓库内 app-server 客户端已经通过 `context.Done()` 有界返回，并有 `TestClientRequestTimeout` 覆盖上游永久不响应；修改该客户端不能修复这次 Desktop 全局聚合与取消传播问题。

## 方案

### 1. 删除同源失效依赖

主巡检只使用 GitHub Issues、Branch、Worktree、Commit、PR/CI 等持久化证据，不再查询 Codex Desktop 的任务列表或任务历史。阻塞检测器也只读取本地租约，不再用失效工具检查失效工具。

代价是无法自动判断 Codex task 的实时 `active/idle`。证据不足时宁可停止补位，也不恢复或创建第二个任务。

### 2. 原子巡检租约

`linear-poll-guard` 是一个单次运行的本地 CLI，不是后台服务。它在 Codex 数据目录保存：

```text
$CODEX_HOME/automations/mimi-linear-issue/guard/
├── active.json
└── last-run.json
```

- `begin` 使用 `O_CREATE | O_EXCL` 原子创建 `active.json`，两个同时到达的心跳只有一个成功；
- `phase` 在每个外部工具调用前原子更新 `phase`、`blocking_tool` 和 `tool_started_at`；
- `finish` 先写入 `last-run.json`，再释放当前租约；
- `status` 只读诊断，超过 8 分钟标记 `stale`；
- `unlock` 必须提供完全匹配的 `run_id` 和人工对账原因。

租约不按 TTL 自动抢占。旧轮可能已完成 `create_thread`，但响应丢失；自动抢锁会把未知结果错误解释为失败并重复创建。损坏租约同样按 `blocked` 处理。

### 3. 持久化 dispatch-intent

在 `create_thread` 或恢复动作之前，主巡检先向目标 GitHub Issue 写入带稳定 marker 的 `PENDING` intent。确认成功后更新同一条评论为 `CREATED` / `SENT`；只有确认没有副作用时才改为 `CANCELLED`。

调用结果未知时保留 `PENDING`。后续轮看到未对账 intent 后不得重试，必须先结合 GitHub、Branch、Worktree、Commit/PR 或人工检查确认真实结果。

本地租约解决并发，GitHub intent 解决“副作用可能成功但响应未知”的跨轮幂等问题；两者不能互相替代。

## 实现

### 安装 guard

```bash
bash ./scripts/install-linear-poll-guard.sh
"${CODEX_HOME:-$HOME/.codex}/automations/mimi-linear-issue/bin/linear-poll-guard" version
```

在支持 POSIX 权限位的系统上，状态目录权限为 `0700`，状态文件为 `0600`。只记录 run ID、阶段、工具名和时间，不记录 Prompt、用户输入、工具输出、Token 或账号信息。

### 运维命令

```bash
guard="${CODEX_HOME:-$HOME/.codex}/automations/mimi-linear-issue/bin/linear-poll-guard"

"$guard" status --hard-limit 8m

# 只有完成 GitHub dispatch-intent、Branch、Worktree、Commit/PR 人工对账后才能执行。
"$guard" unlock \
  --run-id "mimi-linear-issue:2026-07-31T02:25:11.409Z" \
  --reason "已核对 pending intent 与 Git/PR，没有不确定副作用"
```

`unlock` 只处理能正常解析且 owner 完全匹配的租约。若 `status=corrupt`，先备份损坏的 `active.json`，完成人工对账并留下处置记录，再由维护者显式修复或移走损坏文件；标准 `unlock` 不会跳过 owner 校验。

实际自动化提示词以仓库内模板为准：

- `config/automations/mimi-linear-issue.prompt.md`
- `config/automations/mimi-linear-watchdog.prompt.md`

### 定向验证

```bash
go test ./internal/linearpollguard ./cmd/linear-poll-guard
bash ./scripts/check-linear-polling-safety.sh
git diff --check
```

固定时序回归覆盖：

1. 任务列表查询永久不返回；
2. 用户在 2 分钟时追问但不改变租约 owner；
3. 后续心跳无法取得第二个租约；
4. 8 分钟时记录阻塞工具、等待时长和人工对账结论；
5. 正常 `finish` 后下一轮可以开始；
6. 进程写入租约后崩溃，重启仍保持 fail-closed；
7. 32 个并发心跳只有一个取得租约；
8. 损坏租约不会被自动覆盖。

## 风险与优化

| 能力 | 项目侧结论 |
| --- | --- |
| 不再被 `list_threads` 拖住 | 可以保证：主巡检和阻塞检测器都不再调用它 |
| 后续心跳不与旧轮重复派发 | 可以保证：原子租约拒绝并发，dispatch-intent 拒绝未知结果重试 |
| 阻塞工具、开始时间与等待时长可审计 | 可以保证：`active.json` 与 `status` 输出稳定字段 |
| 任意挂起工具在 8 分钟内被取消 | 不能保证：需要 Codex Desktop 工具 runtime 提供 timeout/cancel |
| 旧 Turn 在 8 分钟内产生终态 | 不能保证：项目代码无法抢占尚未返回的 Desktop 内置工具调用 |
| 自动知道 Codex task 的实时状态 | 不再保证：安全降级主动放弃 task list/history 查询 |
| `create_thread` 的未知结果自动恢复 | 不保证自动恢复：保留 `PENDING`，人工对账后决定 `CREATED` 或 `CANCELLED` |

当租约 stale 或损坏时，自动化会停止补位，可能形成需要人工处理的永久阻塞。这是有意选择：在没有平台级取消和副作用幂等键时，可用性降级比重复创建任务更安全。后续只有 Codex Desktop 暴露可靠的工具调用 deadline、取消确认和幂等任务创建接口后，才应考虑自动恢复。

Codex Desktop 的最小上游改进缺口是：

1. `list_threads` 对每个 local/remote/history source 使用独立 deadline；
2. 单个远端失败时返回 partial result，并在 `unavailableHosts` 标明原因；
3. Turn 中断向所有未决工具 promise 传播 cancellation，丢弃迟到结果；
4. 工具 schema 提供 `hostId` 过滤或显式的 per-host timeout，避免一次远端异常拖住全局查询。

外部架构审查使用 ChatGPT Pro 模式完成，结论支持“删除 Desktop task 查询依赖 + 原子租约 + dispatch-intent + 只读阻塞检测器”的最小闭环，并强调禁止 TTL 抢锁、补充 crash/race 测试。审查对话：

https://chatgpt.com/c/6a6c0a0a-6260-83ea-890d-39958c3f317e
