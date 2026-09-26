# Harness 原生客户端：冻结契约（H00 / Gate A）

本文件是 #498 改造的实施契约，冻结 wire 协议、恢复语义、安全边界、夹具与验收判据。
它是 H01—H13 的唯一协议依据：实施者不得临场发明协议事实，只能引用本文件与 `contracts/harness-native/`。

> 当前实施已使用正式原生客户端；旧 DeepSeek app-server 翻译层和实验开关已删除。
> 本文的基线、设备状态与门禁清单保留 H00 冻结时的记录。最新实现与验证进展见
> [PR #499](https://github.com/gaixianggeng/mimi-remote/pull/499)；实体设备与真实供应商验收仍待完成。

- 主 Issue：#498。主 PR：#499。分支：`codex/gh-498-harness-runtime`。
- 代码基线：`7f43f594df3920598e6a7fa4e84f49ab3c62d87c`（base `3a46e00cfa08b2c0af27ea485bf76ac296a49a64`）。
- 契约版本：`contracts/harness-native/manifest.json` version 1，`status: frozen`。
- **冻结依据**：`@deepseek-ai/dsh` **0.1.5-rc.2** 在隔离环境中的**实跑采集**
  （独立 `DSH_HOME` + 回环假模型，未触碰用户 Harness，无真实供应商调用）。
  上游 `0.1.6-alpha.2` 源码仅用于解释成因。

## 一、H00 冻结时的核对结论（本机实测）

| 项 | 核对值 | 状态 |
|---|---|---|
| 本地 HEAD | `3a46e00c`（`main`）= PR #499 的 **base** | 已核对 |
| 本地工作树 Harness 代码 | **不存在**。`internal/harnessclient/`、`docs/deepseek-harness-protocol.md`、`deepseek_*.go` 均无；`CodexAppServerSessionClients.swift` 无 deepseek 绑定 | 已核对 |
| 远端 PR #499 | OPEN，head `7f43f594`，分支 `codex/gh-498-harness-runtime`，MERGEABLE，领先 base 34 个提交 | 已核对 |
| PR #499 CI | 全部通过（含 iOS conversation-regressions 15m55s） | 已核对 |
| Issue #498 | OPEN，标签 Feature / Mac-agentd / iOS，`status: Verify` | 已核对 |
| 本机 agentd | `/Applications/Mimi Remote Mac.app/Contents/Resources/agentd`，Mac App 0.1.0 (1)，监听 `127.0.0.1:8787` | 已核对 |
| 本机 agentd 能力 | 二进制内 **0 个** harness 符号、无 deepseek；配置 `runtime.type=codex_app_server`，无 harness 段 | 已核对 |
| 用户 Harness（本机） | **未安装、未运行**。无二进制、无配置目录、无监听端口 | 已核对 |
| 用户 Harness（手机 App 侧） | 构建版本**未核对**，三个用户现象无法在本机复现 | 未闭合 |
| 隔离实跑 Harness | `@deepseek-ai/dsh` **0.1.5-rc.2**（npm `latest`，tag `dsh-v0.1.5-rc.2`，commit `fb2c4b9e`），web profile | 已实跑 |
| 上游源码阅读版本 | `ddefc45f` = tag `dsh-v0.1.6-alpha.2` | 已核对 |

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

### 已闭合：真实安装版本已实跑核对

H00 在**隔离环境**内安装并运行了一个独立 Harness 并完成采集，用户环境未被触碰：

- 版本：`@deepseek-ai/dsh` **0.1.5-rc.2**（npm dist-tag `latest`，tag `dsh-v0.1.5-rc.2`，commit `fb2c4b9e`），web profile。
- 隔离纪律：独立 `DSH_HOME`、独立端口、独立进程；**未安装、未重启、未升级**用户任何 Harness；**未做任何真实供应商调用**。
- 模型侧：上游自带 `@deepseek-ai/dsh-llm-mock-server`（可编排 OpenAI 兼容 SSE 假模型），
  经 `llm-pi-ai` 手写路由 `h00-loopback` 接入，无任何真实凭据。
- 采集范围：信封正负例、`session/list`（空表与含真实会话）、`modelCatalog`、
  `create`/`selectModel`/`prompt`/`cancel`、`session/page`（一次完整回合 19 条持久记录）、
  `session/control`（baseline/projection/queue）、`$events`（ready/emit 与真实事件名）、
  `session/follow`（snapshot/event/assistant-stream）、assistant-stream 全部 chunk 类型、
  三种 `turn/end`、取消路径与重连待重投基线。

**复现前提（硬约束）**：npm 扁平化安装产出多份 `@deepseek-ai/dsh-scope` 物理副本。
`dsh-scope` 以 `Symbol` 作 scope 键，多实例导致 Symbol 身份不一致、`scopeOf()` 恒为 `undefined`，
表现为 `session/create` 报 `agent-presets: refusing to compose an unscoped context`、
`prompt` 报 `session/agent-busy`。必须先把所有副本折叠为指向同一目录的符号链接。
这是**安装方式导致的本地环境问题，不是上游缺陷**，但任何后续隔离采集都会踩到。

### 未闭合：用户手机上的 App 构建版本

本机 Harness 与用户环境均已核对，但**用户手机上的 App 构建版本无法在本机核对**，
三个用户现象无法在本机复现。这一项与下面的「审批/选择题帧未采集」「跨连接 `api-session/added` 未验证」
共同构成 Gate A 的剩余未闭合项，见第六节。

## 二、冻结的 wire 协议

来源：**0.1.5-rc.2 实跑采集**为主；上游 `ddefc45f`（`0.1.6-alpha.2`）的
`packages/api/gateway/src/stream-protocol.ts`、`packages/client/connection/src/rpc-host.ts`、
`packages/api/session-controller/src/index.ts` 用于解释成因与确认生成规则。
全部 blob SHA 与逐夹具 SHA-256 记在 `manifest.json`。

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

**实跑确认**：0.1.5-rc.2 下 `session/list` 传 `request` 返回 `gateway/arguments-invalid`，
文案为 `args fields do not match the descriptor: missing "_request"`；改传 `_request` 即成功。

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

`address` 是判别联合：`{kind:'session',sessionId}` 或 `{kind:'subagent',parentSessionId,childSessionId,mode}`。
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

`chunk.type` 取自 Harness `StreamChunk`，**全部用连字符**。实测出现 6 种：
`block-start`、`text-delta`、`tool-call-delta`、`block-end`、`usage`、`finish`；
`reasoning-delta` 属源码级（本轮回环模型未产出推理）。

> **⚠ 两套词表，不要混淆。** wire 上的 chunk 是 `StreamChunk`（`text-delta` 单数 delta）；
> 持久事件里嵌的是**压缩记录** `AssistantStreamRecord`，它把连续 delta 打包成
> `text-chunks` / `reasoning-chunks` / `tool-call-chunks`（带 `dt[]` / `texts[]` 数组）。
> **wire 上永远看不到 `*_chunks`。** 把两者当成一套会导致解析器直接错位。

块的配对规则：`block-start.blockType` 与 `block-end.block.type` 成对，取值域是
`ContentBlockMap` 的键：`text` / `reasoning` / `image` / `file` / `tool-call` / `tool-result`。
文本块必须先按 `text-delta` 累积，**不能**等 `block-end` 才渲染；工具参数同理是
`argumentsDelta` 字符串增量，需自行拼接后再 `JSON.parse`。

`end.outcome`（**实测**）：`{kind:'committed', eventType, seq}`。

- `outcome.seq` 就是该次提交在持久日志里的 seq。
- `outcome.eventType` 就是那条事件的 type：正常结算（`turn/end` 为 `completed` 或 `error`）→
  **`assistant/message`**；**用户中止**（`turn/end` 为 `aborted`）→ **`assistant/attempt`**。
- **取消不产生 `kind:'abandoned'`**，它照样 `committed`，只能靠 `eventType` 区分。
  消费者**不得**把 `kind:'committed'` 直接当成「有完整正文」。
- `kind:'abandoned'` 在本次采集中未出现，属源码级，不得当作已实测。

`revision` 必须连续（`expected = previous + 1`，`start` 为 1），跳号即载体失败，必须重开 follow。
`index` 稠密递增（从 0 开始），`end` 也带 `index`，接在最后一个 chunk 之后。

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

## 三、版本敏感项（已按实跑版本复核）

上游 `0.1.5-rc.2` → `0.1.6-alpha.2` 存在**破坏性**差异。下表已用 **0.1.5-rc.2 实跑**复核：

| 区域 | 0.1.5-rc.2 | 0.1.6-alpha.2 | 影响 | 实跑复核 |
|---|---|---|---|---|
| `session/control` baseline | `{queues, jobs, projections}` | `{jobs, projections}` | **帧结构不同，不能跨版本复用解析器** | ✅ baseline 顶层键实测恰为 `queues,jobs,projections` |
| `session/control` 帧并集 | 含 `{type:'queue',sessionId,items}` | 该帧与 `SessionQueuedItem` 已删除 | 队列能力不得假设存在 | ✅ 实测到两条 queue 帧（入队与排空） |
| `session/search` 不可用 | `gateway/internal`，文案 `session search is disabled: … openAt "never"` | `gateway/internal`，文案 `session search is unavailable: … does not mount @deepseek-ai/dsh-session-query` | 降级只认 code，不认文案 | ✅ 0.1.5-rc.2 文案逐字一致 |
| 错误词表 | 无 `session/writer-held` | 新增 `session/writer-held` | 错误映射需容忍未知 code | 源码级 |
| `session/updateQueue` | 同步，仅作用于 live Agent | 返回 Promise，会先 resume 冷会话 | 语义变化，非 wire 形状变化 | 源码级 |
| `session/create` 的 `agentPreset` | 装配了 agent 名册时返回 `{sessionId, agentPreset}` | — | 可选字段，客户端不得假设其存在 | ✅ 实测返回 `agentPreset:"standard"` |

**结论（实跑后更新）**：控制流帧结构**已按 0.1.5-rc.2 实测**，`baseline` 含 `queues` 一项可以按该版本实现。
但两版本差异是真实的，所以：

- 解析控制流 baseline 时**必须容忍缺 `queues`**（`0.1.6-alpha.2` 已删除），
  不得把 `queues` 当必填字段，否则将来升级即崩。
- 队列帧按「出现才处理」实现，不作为任何功能的必要条件。
- **目录发现不依赖控制流**（见第五节 5.4），因此控制流的版本漂移不会影响正确性，只影响及时性。

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

**实测结论（0.1.5-rc.2）：**

- `session/control` 广播 `projection` 变化与 queue/jobs 变化；它**不**订阅 `api-session/added`，
  因此**新建会话不保证产生控制帧**。→ 控制流**不能**作为新建会话的可靠发现通道。
- `$events` **确实**广播 `api-session/added`、`api-session/status`、`api-session/activity`
  （实测三条真实事件名）。这修正了本契约早期「`$events` 不下发 `api-session/added`」的记录。

**仍未证明**：本次只证明**发起创建的那条连接**会收到 `api-session/added`；
它是否会推给**另一条** `$events` 连接尚未验证。因此在证明之前，
**不得**把 `$events` 当作跨连接的新会话发现通道。

确定性兜底（产品参数，可经测量调整）：
**仅列表可见且 App 前台时，每 5 秒最多发起一次合并后的 `session/list` 请求。**
后台或页面离开立即停止；`$events` 或 control 有变化时及时触发，不必等定时器。

> 这样做的代价是「别处新建的会话最多晚 5 秒出现」，收益是不依赖一条未证明的跨连接推送。
> 若后续任务证明 `$events` 能跨连接可靠推送 `api-session/added`，可把 5 秒兜底降级为安全网。

`session/list` 上游**没有服务端分页**（`list()` 不消费 `cursor`，读全部会话按 `updatedAt` 倒序返回）。
因此在该快照上做 UI 展示分页，**不得**假装有服务端分页，也不得跨 runtime 拼 cursor。

### 5.5 历史与增量

- 先开 follow 拿 opening snapshot，再按其 `cursor` 读历史；snapshot 建立期间缓冲该代次 live 帧，按原生顺序交接。
- `throughSeq` 属于这一代 snapshot，不能混用上一代游标。
  **实测**：`throughSeq` 传 `0` 只读到 seq 0 一条记录；传一个远超当前 cursor 的值（如 `999999`）
  返回**空 records**；回传 `snapshot.cursor` 才读到完整记录（实测 19/20 条）。
  因此 `throughSeq` 必须取自**本次** follow 的 opening snapshot，不能猜、不能写死。
- durable 记录以 `(host, runtime, session, native seq)` 去重，保留原生消息/工具身份。
- 分页终止条件：空页、重复页、无进展、越界游标。不得用先前未展示的消息条数伪造上游进度。
- live attempt 以 `attemptId`/`revision`/`index` 管理；durable settlement 依据 `outcome.kind`/`eventType`/`seq` 绑定。
  **不能**仅用 `(turn, step)` 认定同一条消息（重试可发生在同一步）；**不能**把 `attemptId` 当作 durable message ID。

## 六、Gate A 判定

### 负责人决定（2026-09-19）

**Gate A：通过，采用方案 A。**

- **接受当前冻结契约**（依据 `0.1.5-rc.2` 实跑采集），H01 起以本文件与 `contracts/harness-native/` 为唯一协议依据。
- **审批 / 选择题帧不补采**。H03 按源码形状实现 `$events` waterfall 与 `$events/result`，
  并在 **Gate B 用负向测试覆盖**这一未实测区域。
- 理由：该缺口风险收敛于「中继的审批归属」一处，不影响 wire 主干；Gate B 本就是专门验审批归属与失败路径的门禁。
- **副作用（必须遵守）**：审批帧形状属**源码级**，实施者不得把它当已实测事实；
  任何依赖它的代码都要有明确的「形状不符即拒绝」路径，不得静默降级。

### 已冻结

wire 协议（信封、方法参数名、结果形状、流帧、assistant-stream 词表与结算语义、错误词表）、
安全边界、恢复语义、目录发现策略、脱敏夹具（14 个，附 SHA-256）、
后续 Swift/Go 负向用例清单、精确测试入口。

冻结依据是 **0.1.5-rc.2 实跑采集**，不再是源码推导。逐条实跑证据见 `manifest.json`。

### 未闭合（不阻塞 H01，但必须带条件实施）

1. **用户手机上的 App 构建版本未核对**，三个用户现象无法在本机复现。
   → H01 起不得以「用户报告」为验收依据；以本契约与夹具为准。
2. **审批 / 选择题帧（`$events` waterfall）未采集**。本轮回环模型无法触发需要人机应答的工具调用
   （真实 `bash` 工具会因 headless profile 无法回答 `ask` 审批策略而失败，这是采集到的**真实错误帧**，
   但 waterfall 请求本身没出现）。形状仍是源码级 → H03 实现时按源码形状写，
   **必须在 H03 门禁用负向测试覆盖**，不得假设已实测。
3. **跨连接 `api-session/added` 未验证**（见 5.4）。→ 目录发现以 5 秒兜底为准，已写进契约。
4. **`kind:'abandoned'` 未观测**。→ 只按源码处理，不作为已实测分支。

### 解除方式

- 第 1 项：由负责人在用户设备上确认 App 构建版本；在此之前实施按契约进行。
- 第 2 项：需要一次能触发审批的采集（要显式授权，因为它是写路径）。可选，不阻塞。
- 第 3、4 项：已用兜底策略消化，不需要额外采集。

**第 2 项是唯一需要额外授权的采集项。** 其余未闭合项均已用契约级兜底消化，
因此 **H01 可以在 Gate A 通过后立即启动**。

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
MimiRemoteTests/DeepSeekSearchRoutingTests
MimiRemoteTests/DeepSeekRuntimePresentationTests
```

> 曾另有 `DeepSeekSessionRuntimeTests`、`DeepSeekSessionLifecycleTests`、
> `DeepSeekCrossRuntimeContractTests` 三个类。它们断言的是 deepseek 的 **app-server 协议
> 形状**（channel 方法清单、`_mimi_observe` 观察 pin、follow invalidated 通知、
> `thread/read` 代替 `thread/resume`）。该翻译层已整体删除，这三个类随之删除；deepseek
> 的承载能力改由原生通道的 Harness 测试覆盖。

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

全部夹具在 `contracts/harness-native/fixtures/`。其中 11 个是 **`live-capture`**，3 个是
**`upstream-source`**；`session/modelCatalog` 因未保留原始响应，已诚实降级为源码级。
逐文件 SHA-256 见 `manifest.json` 的 `fixtureDigests`。

均为虚构 cwd / sessionId / eventId / clientId / attemptId，不含真实主机、路径、会话或凭据。
**协议常量原样保留**（类型名、事件名、枚举值、键名、工具名、模型与供应方名），否则夹具就失去判别力。

| 文件 | 覆盖 |
|---|---|
| `rpc/session-list.json` | `_request` 参数名、空表与含真实会话两种结果、负向（错误键名/多余键/方法路径不一致） |
| `rpc/session-search.json` | 成功、索引不可用降级（0.1.5-rc.2 真实文案）、取消、空 query |
| `rpc/session-model-catalog.json` | 零参数方法、含 failures 的成功、传参被拒；源码级，非实采证明 |
| `rpc/session-commands.json` | create / selectModel / prompt / cancel 的请求、成功、错误与规则 |
| `rpc/session-page.json` | throughSeq 必填与取值来源、空页终止、分页终止条件 |
| `rpc/events-result.json` | 三种 outcome kind、审批与追问应答、精确键校验；**审批帧未采集的缺口** |
| `rpc/envelope-errors.json` | 状态码矩阵、网关错误词表、会话错误词表、缺陷 1 |
| `stream/mux-carrier.json` | open/cancel 与 item/error/end 三类帧、缺陷 2 |
| `stream/follow-frames.json` | snapshot、缺基线报错、durable 事件、assistant-stream |
| `stream/assistant-stream.json` | **wire 词表 vs 持久压缩记录两套词表**、三个真实回合（文本/工具/取消）、结算语义、revision/index 规则 |
| `stream/durable-events.json` | 事件信封、事件类型清单、注入上下文、投影规则 |
| `stream/events-interaction.json` | ready/emit/waterfall/cancel、agentId 归属、交互状态机 |
| `stream/control-frames.json` | 控制帧、两个版本的 baseline 差异、目录失效结论 |
| `recovery/recovery-semantics.json` | 连接代次、重连顺序、半开检测、退避、宿主重启、资源上限 |

夹具可离线解析，不依赖网络。每个必需方法都有请求、成功、错误样本。

> 实施提醒：`stream/assistant-stream.json` 里同时给出了 **wire chunk 词表**与
> **持久压缩记录词表**。这是本契约最容易写错的地方之一，见 2.7。

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
| Gate A | H00 后 | 线协议、上游版本、接口签名、安全边界、夹具与验收判据已冻结（**0.1.5-rc.2 实跑**）→ 本文件，带 4 项已兜底未闭合项，**待负责人批准** |
| Gate B | H03 后 | 读写/流授权、交互归属、凭据隔离与失败路径已被负向测试证实 |
| Gate C | H12 后 | App + Harness Web 双端、故障恢复、兼容与 Codex/Claude 回归通过，再决定切默认与删除旧实现 |
