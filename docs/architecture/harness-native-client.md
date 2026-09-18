# Harness 原生客户端：冻结契约（H00 / Gate A）

本文件是 #498 改造的实施契约，冻结 wire 协议、恢复语义、安全边界、夹具与验收判据。
它是 H01—H13 的唯一协议依据：实施者不得临场发明协议事实，只能引用本文件与 `contracts/harness-native/`。

- 主 Issue：#498。主 PR：#499。分支：`codex/gh-498-harness-runtime`。
- 代码基线：`7f43f594df3920598e6a7fa4e84f49ab3c62d87c`（base `3a46e00cfa08b2c0af27ea485bf76ac296a49a64`）。
- 契约版本：`contracts/harness-native/manifest.json` version 1。

## 一、核对结论（本机实测）

| 项 | 核对值 | 状态 |
|---|---|---|
| 本地 HEAD | `3a46e00c`（`main`）= PR #499 的 **base** | 已核对 |
| 本地工作树 Harness 代码 | **不存在**。`internal/harnessclient/`、`docs/deepseek-harness-protocol.md`、`deepseek_*.go` 均无；`CodexAppServerSessionClients.swift` 无 deepseek 绑定 | 已核对 |
| 远端 PR #499 | OPEN，head `7f43f594`，分支 `codex/gh-498-harness-runtime`，MERGEABLE，领先 base 34 个提交 | 已核对 |
| PR #499 CI | 全部通过（含 iOS conversation-regressions 15m55s） | 已核对 |
| Issue #498 | OPEN，标签 Feature / Mac-agentd / iOS，`status: Verify` | 已核对 |
| 本机 agentd | `/Applications/Mimi Remote Mac.app/Contents/Resources/agentd`，Mac App 0.1.0 (1)，监听 `127.0.0.1:8787` | 已核对 |
| 本机 agentd 能力 | 二进制内 **0 个** harness 符号、无 deepseek；配置 `runtime.type=codex_app_server`，无 harness 段 | 已核对 |
| 本机 Harness | **未安装、未运行**。无二进制、无配置目录、无监听端口 | 已核对 |
| 上游 Harness | master `ddefc45f` = tag `dsh-v0.1.6-alpha.2`；计划书记录版本为 `0.1.5-rc.2`（tag `fb2c4b9e`） | 已核对 |

### 关键差异：本机工作树不含本次改造的目标代码

H01—H13 的目标文件只存在于 PR 分支。核对 `ios/MimiRemote/Sources/Core/API/CodexAppServerSessionClients.swift`：

| 位置 | 行数 | deepseek 出现次数 | `AppServerRuntimeBundle` |
|---|---:|---:|---|
| `main` @ `3a46e00c` | 1237 | 0 | 只有 `codex` / `claude` |
| PR @ `7f43f594` | 1331 | 有 | 增加 `deepseek: CodexAppServerSessionRuntime?` |

因此本次实施已建立 **#499 专用 Worktree**，检出 `codex/gh-498-harness-runtime` @ `7f43f594`：

```
<worktrees-root>/code/codex-ipad-agent-gh-498-harness-native
```

主工作树（仓库根）保持在 `main`，未被修改。

### 未完成项：真实安装版本未核对

本机没有可运行的 Harness，隔离安装被沙箱拒绝（`CODEBUDDY_BROKER_DENY` / `SIGKILL`）。
因此本契约的 wire 事实**全部来自上游源码**（可 blob 校验），**未经本机安装版本实跑复核**。
这是 Gate A 唯一未闭合项，见第六节。

## 二、冻结的 wire 协议

来源：上游 `ddefc45f` 的 `packages/api/gateway/src/stream-protocol.ts`、`packages/client/connection/src/rpc-host.ts`、
`packages/api/session-controller/src/index.ts`。全部 blob SHA 记在 `manifest.json`。

### 2.1 认证与载体

- 启动 token 只用于 `GET /?token=<token>`，返回 **303** 并下发绑定 hostname+port 的 Cookie。
- 普通 API **不接受** `Authorization` 头；无 Cookie 一律 **401**。
- RPC 走 `POST /api/<method>`，`Content-Type` 必须是 `application/json`。
- 事件流走 `WS /api/remote.mux`。

### 2.2 信封

请求：

```json
{"type":"client-request","rpcId":"<string>","method":"<method>","payload":{"args":{}}}
```

响应：

```json
{"type":"server-response","rpcId":"<string>","result":{"ok":true,"value":{}}}
{"type":"server-response","rpcId":"<string>","result":{"ok":false,"error":{"code":"","message":"","details":{}}}}
```

**业务结果必须检查 `result.ok`。** 业务错误是 HTTP 200 + `ok:false`；只有处理函数抛异常才是 500。

状态码矩阵（`rpc-host.ts`）：

| 条件 | 状态码 |
|---|---|
| 非 POST / 路径段为空或 `.` `..` / 不匹配 `^[A-Za-z0-9_$.-]+$` | 404 |
| Content-Type 不是 `application/json` | 415 |
| body 不是合法 JSON | 400 |
| 外壳不合法，或 `body.method` ≠ URL endpoint | 200 + `gateway/bad-request` |
| 处理函数抛异常 | 500 |

### 2.3 方法参数名（逐字冻结）

上游 `@Remote('list') list(_request: SessionListRequest, signal)` 的第一个形参名带下划线，而
typert 生成器 `analyzer.ts:1140` 用 `wire = parameter.name.text` 作为 wire 键。
`signal: AbortSignal` 是取消参数（必须是最后一个），**不进入 wire**。

| 方法 | `payload.args` 的键 |
|---|---|
| `session/list` | **`_request`** |
| `session/search` `create` `selectModel` `page` `prompt` `cancel` | `request` |
| `session/modelCatalog` `canOpenWorkspacePath` `$events` `session/control` | 无参数，传 `{}` |
| `$events/result` | `clientId` + `eventId` + `outcome`（恰好三个键） |

网关按描述符**逐字**校验：多一个键、少一个键都报 `gateway/arguments-invalid`。

### 2.4 方法与结果形状

| 方法 | 请求 | 结果 |
|---|---|---|
| `session/list` | `{cursor?}` | `{items: SessionSummary[]}` |
| `session/search` | `{query}` | `{items:[{sessionId,snippet}], hasMore}` |
| `session/create` | `{workspaceId?,cwd?,sessionId?,agentPreset?}` | `{sessionId, agentPreset?}` |
| `session/selectModel` | `{sessionId,provider,model,reasoningEffort?}` | `{selected}` |
| `session/modelCatalog` | — | `{default,routableProviders,groups,failures}` |
| `session/page` | `{address,throughSeq,beforeSeq?,maxMessages?}` | `{records,hasMore}` |
| `session/prompt` | `{requestId,sessionId,mode,content,clientTimeZone?}` | `{accepted:true}` |
| `session/cancel` | `{sessionId}` | `{accepted:true}` |
| `session/follow` | `{address,maxMessages?,assistantStream?}` | 帧流 |
| `session/control` | — | 帧流 |

`SessionAddress` 是判别联合：`{kind:'session',sessionId}` 或 `{kind:'subagent',parentSessionId,childSessionId,mode}`。
首版只开放 `session` 形态。

`SessionSummary`：`{sessionId,updatedAt,running,blank,parentSessionId?,origin?,cwd?,projections?}`。
`updatedAt` 与 `time` 都是**毫秒**。

### 2.5 流载体帧

客户端：`{type:'open',streamId,endpoint,payload}`（四个键恰好）、`{type:'cancel',streamId}`。

服务端：**每帧都带 `type` 判别值**。

| type | 形状 |
|---|---|
| `item` | `{type:'item',streamId,value}` |
| `error` | `{type:'error',streamId,error:{code,message,details}}` |
| `end` | `{type:'end',streamId}` |

### 2.6 follow 帧

首帧必须是 `snapshot`：`{header,cursor,records,hasMore,projections,assistantStream?}`。
之后是 `{type:'event',event}` 持久事件，或 `{type:'assistant-stream',frame}` 直播片段。

`snapshot.cursor` 是本次订阅的 inclusive 日志切点，也是 `session/page` 必填的 `throughSeq`。

opt-in `assistantStream:true` 时 snapshot 必须带 `assistantStream` 基线，否则报
`gateway/internal: session assistant stream omitted its opted-in opening baseline`。

### 2.7 assistant-stream

基线：`{revision, activeAttempt?:{attemptId,startedAfterSeq,turn,step,nextIndex,stream}}`。

帧三态：`start`（带 `startedAfterSeq`/`turn`/`step`）、`chunk`（带 `index`/`time`/`chunk`）、`end`（带 `outcome`）。

`chunk.type` 取自 Harness `StreamChunk`，**全部用连字符**：`block-start`、`text-delta`、`reasoning-delta`、
`tool-call-delta`、`block-end`、`usage`、`finish`。
`text_delta` / `content_block_start` 是 Anthropic SDK 形状，不是 Harness 的。

`end.outcome`：`{kind:'committed',eventType:'assistant/message'|'assistant/attempt',seq}` 或 `{kind:'abandoned'}`。

`revision` 必须连续（`expected = previous + 1`），跳号即载体失败，必须重开 follow。

### 2.8 反向交互

`$events` 是宿主级通道。`waterfall` 帧：

```json
{"type":"waterfall","event":"approval/request","eventId":"","agentId":"session-…",
 "request":{"toolName":"","callId":"","reason":""}}
{"type":"waterfall","event":"user-questions/request","eventId":"","agentId":"session-…",
 "request":{"questions":[{"id":"","question":"","options":[{"label":""}]}]}}
```

**`agentId` 是必填字段**，类型为非空字符串。Harness 的身份设计是 agent 注册表 id 等于会话 id，
因此 `agentId` 就是会话标识。会话归属是核事实，**不得**再用 `callId` 反查或「唯一活跃会话」兜底作主判据。

`ready` 帧：`{type:'ready',clientId,host:{home}}`。`host.home` 属于无必要元数据，**不得**下发移动端或写日志。

应答 `POST /api/$events/result`，`args` 恰好三个键：

```json
{"clientId":"","eventId":"","outcome":{"kind":"result","value":"allowed-once"}}
```

`outcome` 有三个 kind：`next`、`result`（`value` 可选）、`rejected`（`error:{name,message,code?,details?}`）。
审批 `value` 取值域：`allowed-once` | `rejected` | `cancelled` | `unavailable`。
追问 `value`：`{answers:[{id,selected:[…]}]}`。

> 仓库旧文档 `docs/deepseek-harness-protocol.md` 写「应答 kind 只有 result，不存在单独的 rejection 种类」。
> 那是 #492 审批路径的**观测**结果，不是 wire 的能力边界：`parseRemoteEventResult` 明确接受三种 kind。
> 中继不得因为只见过 `result` 就拒收 `next`/`rejected`。

### 2.9 错误词表

网关：`gateway/ambiguous-endpoint`、`arguments-invalid`、`binding-invalid`、`context-failed`、
`context-not-found`、`context-unavailable`、`definition-unavailable`、`input-invalid`、
`invocation-unavailable`、`lookup-failed`、`lookup-not-found`、`lookup-unavailable`、
`method-unavailable`、`provider-mismatch`、`result-invalid`、`service-unavailable`、`signature-invalid`、
以及 `gateway/bad-request`、`gateway/cancelled`、`gateway/internal`。
网关错误 `details` 形状：`{endpoint, field?}`。

会话：`session/model-unavailable`、`conflict`、`writer-held`、`agent-busy`、`invalid-time-zone`、
`workspace-attach-failed`、`agent-preset/conflict`、`session/attachment-invalid`、
`queue-item-not-found`、`steer-unavailable`、`title-invalid`、`fork-unavailable`、
`subagent/not-found`、`subagent/catalog-diagnostic`。

**错误对象固定三字段 `code` / `message` / `details`；`details` 是必需对象，不是可选的 `data`。**

## 三、版本敏感项（必须按真实安装版本复核）

上游 `0.1.5-rc.2` → `0.1.6-alpha.2` 存在**破坏性**差异：

| 区域 | 0.1.5-rc.2 | 0.1.6-alpha.2 | 影响 |
|---|---|---|---|
| `session/control` baseline | `{queues, jobs, projections}` | `{jobs, projections}` | **帧结构不同，不能跨版本复用解析器** |
| `session/control` 帧并集 | 含 `{type:'queue',sessionId,items}` | 该帧与 `SessionQueuedItem` 已删除 | 队列能力不得假设存在 |
| `session/search` 不可用 | `gateway/internal`，文案 `session search is disabled: … openAt "never"` | `gateway/internal`，文案 `session search is unavailable: … does not mount @deepseek-ai/dsh-session-query` | 降级只认 code，不认文案 |
| 错误词表 | 无 `session/writer-held` | 新增 `session/writer-held` | 错误映射需容忍未知 code |
| `session/updateQueue` | 同步，仅作用于 live Agent | 返回 Promise，会先 resume 冷会话 | 语义变化，非 wire 形状变化 |

**结论：控制流帧结构不能在版本未确认时冻结为唯一实现。** H11 前必须按用户真实安装版本复核，
否则控制流只能作为「可用则用」的增强，目录发现必须依赖第五节的兜底。

## 四、安全边界（不可协商）

- 会话授权必须基于**真实上游 session ID 与可信 cwd/作用域证据**；不能因为客户端带了 cwd 就认为该会话属于此目录。
- `session/list` 请求体里没有 cwd，返回本机可见的**全部**会话；按授权工作区裁剪是 **agentd 的责任**。
- 中继只向配置中的**固定 Harness origin** 转发。不接受客户端提供的目标 URL、Host、Cookie 或 Harness token。不做任意 `/api/*` 代理。
- `session/list|search|control` 中的会话、投影、jobs 条目均按授权范围过滤；父子会话与子 Agent **不自动继承**可见性。
- 订阅 follow 时先校验请求目标，再在首个 snapshot 对照归属；授权未证实前**不得**下发 snapshot 或缓冲帧。
- `$events` 只下发可验证属于已授权会话的交互，**不要求用户先打开对应会话页面**。无法归属时不得认领「唯一活跃会话」。
- `$events/result` 必须匹配当前认证主体、活连接的原生 `clientId`、已送达且仍 pending 的 `eventId`。
  `clientId` 只是关联值，**不是凭据**。断线或撤权使旧绑定失效。
- 不得将 `/api/file`、终端、插件或管理路由整体开放；不得透出上游 `Set-Cookie`、启动 token、`host.home` 等元数据。
- 队列满、订阅额度满必须返回**可恢复的明确错误**；不得默默丢正文或驱逐正在观察的会话。
- 错误保留可诊断 code/category，脱敏私密文案。物理断链才自动重连；权限、结构不兼容、数据连续性无法修复不能无休止重试。

权限 UI 必须分清三件事：主机/工作区访问授权由 agentd 控制；会话工具运行权限由 Harness 控制；
某次工具执行的 approval 是一次具体人机交互。**不得**混成「完全访问」一个按钮。
若安装版本没有可验证的权限设置接口，界面显示「由 Harness 管理」，不显示可点击的只读/工作区写设置。

## 五、恢复语义与目录发现

### 5.1 连接代次

每个 host/runtime 只有一个连接生命周期负责人（`HarnessSessionRuntime`）。
每个回调携带 host/runtime/connection generation；会话相关回调还校验 session ID。
旧代次 HTTP、WS、Task 回调不能覆盖新主机或新连接。宿主重启后重新建立代次，不能沿用旧 revision、clientId 或 pending 表。

### 5.2 重连顺序

1. 确认通道/认证/事件 `ready`（新的 `clientId`）。
2. 目录重新读取（`session/list`）。
3. 活会话重新 `follow`：先拿 opening snapshot，再按 cursor 对账历史。
4. pending 以 Harness 重投（同 `eventId`）或撤销（同 `eventId` 的 `cancel`）恢复。
5. 控制流每代完整 baseline **仅替换它负责的进程态**，不能用旧 baseline 覆盖新列表或 durable 状态。

### 5.3 半开连接

连接不能「看起来正常却永远无帧」。心跳用**传输层确认**（WS ping/pong 与读期限），
不要求模型持续产出。检测到半开即转为明确的 reconnecting/failed，不能以「模型暂时没输出」当作网络失活。
仓库 `internal/harnessclient/events.go` 已有 `pingLoop` + `SetReadDeadline` + `PongHandler` 的读期限续期实现，保留。

退避参数（**方案拟定值，待实测校准，不是 Harness 保证**）：base 1s、factor 2、max 30s、full jitter、后台暂停、进入前台立即重试一次。
权限失败 / 结构不兼容 / 连续性无法修复**不重试**。

### 5.4 目录发现

上游 `session/control` 广播 `projection` 变化、`jobs` 变化，以及 `session/created` 且该会话有 jobs 时。
它**没有**订阅 `api-session/added` / `api-session/removed`，因此**新建会话不保证产生控制帧**。

> 这是本契约对计划书 D2 的确认：控制流**不能**作为新建会话的可靠发现通道。

确定性兜底（产品参数，可经测量调整）：
**仅列表可见且 App 前台时，每 5 秒最多发起一次合并后的 `session/list` 请求。**
后台或页面离开立即停止；control 有变化时及时触发，不必等定时器。

`session/list` 上游**没有服务端分页**（`list()` 不消费 `cursor`，读全部会话按 `updatedAt` 倒序返回）。
因此在该快照上做 UI 展示分页，**不得**假装有服务端分页，也不得跨 runtime 拼 cursor。

### 5.5 历史与增量

- 先开 follow 拿 opening snapshot，再按其 `cursor` 读历史；snapshot 建立期间缓冲该代次 live 帧，按原生顺序交接。
- `throughSeq` 属于这一代 snapshot，不能混用上一代游标。
- durable 记录以 `(host, runtime, session, native seq)` 去重，保留原生消息/工具身份。
- 分页终止条件：空页、重复页、无进展、越界游标。不得用先前未展示的消息条数伪造上游进度。
- live attempt 以 `attemptId`/`revision`/`index` 管理；durable settlement 依据 `outcome.kind`/`eventType`/`seq` 绑定。
  **不能**仅用 `(turn, step)` 认定同一条消息（重试可发生在同一步）；**不能**把 `attemptId` 当作 durable message ID。

## 六、Gate A 判定

### 已冻结

wire 协议（信封、方法参数名、结果形状、流帧、错误词表）、安全边界、恢复语义、
目录发现策略、脱敏夹具、后续 Swift/Go 负向用例清单、精确测试入口。

### 未闭合

1. **真实安装版本未核对。** 本机无 Harness，隔离安装被沙箱拒绝。所有 wire 事实为上游源码级。
2. **第三节的版本敏感项未按真实版本裁决。** 尤其 `session/control` 帧结构。
3. **用户手机上的 App 构建版本未核对**，三个用户现象无法在本机复现。

### 解除方式

按优先级：

1. 由负责人在具备 Harness 运行条件的环境执行只读探针：

   ```bash
   HARNESS_ORIGIN=http://127.0.0.1:<port> HARNESS_TOKEN=<启动 token> \
     node scripts/harness-native-probe.mjs <absolute-research-root>
   ```

   研究根目录需含标记文件 `.h00-harness-probe-root`，内容 `isolated-h00`。
   探针只读，不启动/安装/升级任何 Harness，不落盘 token 与 Cookie。

2. 或提供正在运行的 Harness origin 与启动 token，由实施者执行同一探针。

3. 或由负责人明确接受「源码级冻结」，并据此在第三节标注每个版本敏感项的兼容策略，
   Gate A 带条件通过。此时控制流按「可用则用」实现，目录发现以 5 秒兜底为准。

**在 1 或 2 完成、或 3 被明确选择之前，不启动 H01 的生产实现。**

## 七、精确测试入口（已冻结）

H00 之前方案里「精确 selector 语法待 H00 读脚本后冻结」的占位，至此冻结。

### iOS

唯一入口是仓库脚本，不直接调 `xcodebuild`：

```bash
bash ./scripts/test-conversation-regressions.sh          # Go + iOS
bash ./scripts/test-conversation-regressions.sh --ios-only
```

该脚本内部固定：

```bash
bash ./scripts/ios-dev.sh test -quiet -collect-test-diagnostics never \
  -testLanguage zh-Hans -testRegion CN \
  -only-testing:MimiRemoteTests/<Class> ...
```

DeepSeek/Harness 相关 selector：

```
MimiRemoteTests/DeepSeekComposerPolicyTests
MimiRemoteTests/DeepSeekSessionRuntimeTests
MimiRemoteTests/DeepSeekSessionLifecycleTests
MimiRemoteTests/DeepSeekCrossRuntimeContractTests
MimiRemoteTests/DeepSeekSearchRoutingTests
MimiRemoteTests/DeepSeekRuntimePresentationTests
```

新增 Harness 原生测试沿用 `MimiRemoteTests/<Class>` 形式。测试与快照固定 `iPad Pro 13-inch (M5)`；
设备忙时等待或报告阻塞，**不绕过租约、不切换设备**。

### Go

```bash
go test ./internal/harnessclient -run 'Test.*(RPC|Stream|Auth)' -count=1
go test ./internal/httpapi -run '^TestHarnessNative' -count=1
go test -race ./internal/httpapi -run '^TestHarnessNative' -count=1
```

`[no tests to run]` **不算通过**；执行者必须确认测试确实匹配且运行。

### 收尾

本改造涉及鉴权、交互结果未知、并发与重连，命中 full 条件：

```bash
bash ./scripts/verify-change.sh --plan --full
bash ./scripts/verify-change.sh --full
```

先同模式 plan，再执行一次 full。不因「保险」重复全量。

## 八、实施基线中发现的三处仓库缺陷

这三处不是本次改造的新增内容，而是 H01—H13 会直接踩到的既有问题，已冻结为后续任务范围：

| # | 位置 | 问题 | 后果 | 归属 |
|---|---|---|---|---|
| 1 | `internal/harnessclient/protocol.go` `RemoteError` | `details` 被映射到 json tag `data` | 上游结构化错误信息（endpoint/field/sessionId）全部丢失 | H02 |
| 2 | 同上 `muxFrame` + `events.go` `readLoop` | 只解 `{streamId,value}`，忽略服务端 `type` 判别值 | `type:'error'`/`type:'end'` 帧无 `value`，被当成空帧推入通道；流级错误只会表现为超时 | H03 |
| 3 | `internal/harnessclient/events.go` `Respond` 注释 | 断言「outcome 只有 result 一种」 | 与 `parseRemoteEventResult` 不符；中继不得据此拒收 `next`/`rejected` | H03 |

## 九、夹具索引

全部夹具在 `contracts/harness-native/fixtures/`，均为虚构 cwd / sessionId / eventId / clientId / attemptId，
不含真实主机、路径、会话或凭据。

| 文件 | 覆盖 |
|---|---|
| `rpc/session-list.json` | `_request` 参数名、完整列表、负向（错误键名/多余键/方法路径不一致） |
| `rpc/session-search.json` | 成功、索引不可用降级、取消、空 query |
| `rpc/session-model-catalog.json` | 零参数方法、含 failures 的成功、传参被拒 |
| `rpc/session-commands.json` | create / selectModel / prompt / cancel 的请求、成功、错误与规则 |
| `rpc/session-page.json` | throughSeq 必填、空页终止、分页终止条件 |
| `rpc/events-result.json` | 三种 outcome kind、审批与追问应答、精确键校验 |
| `rpc/envelope-errors.json` | 状态码矩阵、网关错误词表、会话错误词表、缺陷 1 |
| `stream/mux-carrier.json` | open/cancel 与 item/error/end 三类帧、缺陷 2 |
| `stream/follow-frames.json` | snapshot、缺基线报错、durable 事件、assistant-stream |
| `stream/assistant-stream.json` | 基线、七种 chunk 类型、committed/abandoned、revision 规则 |
| `stream/durable-events.json` | 事件信封、事件类型清单、注入上下文、投影规则 |
| `stream/events-interaction.json` | ready/waterfall/emit/cancel、agentId 归属、交互状态机 |
| `stream/control-frames.json` | 控制帧、两个版本的 baseline 差异、目录失效结论 |
| `recovery/recovery-semantics.json` | 连接代次、重连顺序、半开检测、退避、宿主重启、资源上限 |

夹具可离线解析，不依赖网络。每个必需方法都有请求、成功、错误样本。

## 十、后续任务前置约束

- H01—H13 串行。每轮只给实施者全局边界、当前任务、所需夹具与前一交接。
- 每轮使用任务卡限定文件、接口与验收范围；共享 routing、`project.pbxproj` 与 UI Store 由单一实施者串行修改。
- 不创建 14 张 Issue，不引入 Linear。#498 承载用户结果，#499 承载代码。
- 不修改 Codex/Claude 生产行为，不全局重命名，不调整仓库测试阈值，不添加万能框架。
- 不安装、重启或升级用户 Harness。不自动批准、不盲重发结果未知的写操作。
- 不通过放宽测试、清空 App 或持续全量刷新掩盖问题。
- 同一失败经两次定向修复仍无进展，或需要修改冻结契约 / 扩大白名单 / 跨出允许目录时，
  输出阻塞包升级负责人：确切 SHA、失败测试与有限日志、已试修改、冲突的契约、最小需决定事项。

## 十一、负责人门禁

| 门禁 | 位置 | 判定 |
|---|---|---|
| Gate A | H00 后 | 线协议、上游版本、接口签名、安全边界、夹具与验收判据已冻结 → **本文件，带未闭合项** |
| Gate B | H03 后 | 读写/流授权、交互归属、凭据隔离与失败路径已被负向测试证实 |
| Gate C | H12 后 | App + Harness Web 双端、故障恢复、兼容与 Codex/Claude 回归通过，再决定切默认与删除旧实现 |
