# DeepSeek Harness 接入协议参考（#498）

本文记录 agentd 与 DeepSeek Harness 之间的线路契约，以及适配层要产出的 Mimi app-server 形状。
它是 `internal/harnessclient` 与 DeepSeek 网关的实现依据。

## 证据来源与等级

| 事实 | 来源 | 等级 |
| --- | --- | --- |
| 认证握手、RPC 外壳、`session/prompt` 参数、waterfall 形状、`$events/result` 编码、follow 帧分类 | #492 隔离实验 `docs/quality/gh-492-harness-smoke.mjs` 在 Harness `0.1.5-rc.2` 上的真实运行 | 实测 |
| durable event 类型清单与字段路径、assistant-stream chunk 字段、snapshot 结构 | #492 实验留存的原始帧（本机 `logs/smoke-frames.json`，仅提取结构骨架，未公开提交） | 实测 |
| 方法的参数 wire 名、codec 模式、结果类型 | 本机 `@deepseek-ai/dsh-api-session-controller/lib/typert.host.js` 的生成描述符；`lib/types/types.d.ts` 的类型定义 | 源码 |
| `session/list`、`session/page` 的真实结果形状；`session/search` 在未启用索引时不可用 | 本仓库 `docs/quality/gh-498-control-plane-probe.mjs` 在本机 Harness 上的运行 | 实测 |
| Mimi 侧消费的 app-server 形状 | iOS `CodexAppServerSessionRuntime.swift` 等读取点 | 源码 |

证据分级沿用 #492：**实测** 高于 **源码**。凡是只有源码支持、尚未实跑的结论都单独标注。

## 一、agentd → Harness（出海方向）

### 1.1 认证与载体

- 启动 token 只用于 `GET /?token=<token>`，返回 **303** 并下发绑定 hostname+port 的 Cookie。
- 普通 API **不接受** `Authorization` 头；没有 Cookie 一律 **401**。
- RPC 走 `POST /api/<method>`，body 是 Connection RPC 外壳：

```json
{
  "type": "client-request",
  "rpcId": "<每次请求唯一>",
  "method": "<method>",
  "payload": { "args": { } }
}
```

- 业务结果在 `result` 里，**必须检查 `result.ok`**：只用 API Gateway 文档的裸 `{args:...}` 会得到 `gateway/bad-request`，即使 HTTP 状态码是 200。
- 事件流走 WebSocket `/api/remote.mux`，客户端先发 `open` 帧：

```json
{ "type": "open", "streamId": "<本连接内唯一>", "endpoint": "<endpoint>", "payload": { "args": { } } }
```

服务端帧带同一个 `streamId`，真实内容在 `value` 里。

### 1.2 参数名必须逐字匹配描述符

网关按描述符校验 `args` 的键：**多一个键、少一个键都报 `gateway/arguments-invalid`**（`dsh-api-gateway/lib/index.js` 的 `assertExactArguments`）。

因此参数名不是可以自由猜的，必须按描述符取值。已确认的例外：

| 方法 | `args` 键 |
| --- | --- |
| `session/list` | **`_request`**（带下划线；实现里该形参未被使用，生成代码保留了下划线） |
| `session/modelCatalog` | 无参数，传空对象 `{}` |
| 其余 `session/*` | `request` |

### 1.3 方法契约

| 方法 | `args` | 结果（顶层字段） |
| --- | --- | --- |
| `session/list` | `{_request: {cursor?}}` | `{items: [SessionSummary]}` |
| `session/search` | `{request: {query}}` | `{items: [{sessionId, snippet}], hasMore}` |
| `session/create` | `{request: {cwd?, workspaceId?, sessionId?, agentPreset?}}` | `{sessionId, agentPreset?}` |
| `session/page` | `{request: {address, throughSeq, beforeSeq?, maxMessages?}}` | `{records: [{type, event}], hasMore}` |
| `session/follow` | `{request: {address, maxMessages?, assistantStream?}}` | 帧流，见 1.4 |
| `session/prompt` | `{request: {requestId, sessionId, mode, content, clientTimeZone?}}` | `{accepted: true}` |
| `session/cancel` | `{request: {sessionId}}` | `{accepted: true}` |
| `session/selectModel` | `{request: {sessionId, provider, model, reasoningEffort?}}` | `{selected: {...}}` |
| `session/modelCatalog` | `{}` | 见 1.5 |

`SessionSummary`：

```json
{
  "sessionId": "string",
  "updatedAt": "number（毫秒）",
  "running": "boolean",
  "blank": "boolean",
  "cwd": "string?",
  "parentSessionId": "string?",
  "origin": "'subagent'?",
  "projections": {
    "asOfSeq": "number",
    "values": {
      "title": "string?",
      "turnOutline": [{ "prompt": "string?", "response": "string?", "seq": "number", "turn": "number" }],
      "modelSelection": { "lastUsed": {}, "next": {} },
      "permissions": { "currentValue": "string", "options": [{ "name": "", "value": "" }] },
      "tokenUsage": {}, "contextBreakdown": {}, "sessionStats": {}
    }
  }
}
```

关键点：

- **`session/list` 的请求体里没有 cwd**，它返回本机可见的全部会话。按授权工作区裁剪是 **agentd 的责任**。
- `session/page` 的 **`throughSeq` 必填**，取值必须是本次 follow 开场 snapshot 给出的 `cursor`。
- `session/search` 依赖部署侧的会话检索索引。索引未开启时 Harness 返回 `gateway/internal`（`session search is disabled: ... openAt "never"`）。**这必须被当作能力不可用降级，而不是致命错误。**
- `session/control` 是流方法，只能经 WS 载体打开；当作普通 RPC 调用会得到 `gateway/signature-invalid`（`must be opened through the stream carrier`）。

### 1.4 `session/follow` 帧分类

每帧形如 `{streamId, value}`，按 `value.type` 判别：

| `value.type` | 含义 | 关键字段 |
| --- | --- | --- |
| `snapshot` | 开场快照 | `header.{id, cwd, createdAt, agentPreset, isSeeded, version}`、`cursor`（number）、`records[]`、`hasMore`、`projections`、`assistantStream.{revision}` |
| `event` | 持久事件 | `event.{type, seq, time, data, surfaceOp?, sourceEventSeqs?}` |
| `assistant-stream` | 直播输出片段 | `frame.{type, ...}`，见下 |
| `waterfall` | 需要应答的交互 | 见 1.6 |
| `cancel` | 某交互被其他端应答后作废 | `eventId` |
| `ready` | `$events` 订阅就绪 | `clientId`、`host.home` |

`assistant-stream.frame` 三态（`SessionAssistantStreamFrame`）：

```json
{ "type": "start", "attemptId": "", "revision": 0, "startedAfterSeq": 0, "turn": 0, "step": 0 }
{ "type": "chunk", "attemptId": "", "revision": 0, "index": 0, "time": 0, "chunk": { } }
{ "type": "end", "attemptId": "", "revision": 0, "index": 0,
  "outcome": { "kind": "committed", "eventType": "assistant/message", "seq": 0 } }
```

`chunk` 是 SSE 形状的真实片段，实测出现过的字段路径：

- `chunk.type`：片段类型，即 Harness `StreamChunk` 联合体的判别值——`block-start`、`text-delta`、
  `reasoning-delta`、`tool-call-delta`、`block-end`、`usage`、`finish`。
  **全部用连字符（`text-delta`），不是下划线的 `text_delta`**；`text_delta` / `content_block_start`
  是 Anthropic SDK 的形状，不是 Harness 的。判别值取自 `@deepseek-ai/dsh-llm` 的
  `lib/types/assistant-stream.js` 与 `dsh-api-session-controller` 导出的 `StreamChunk` 类型。
- `chunk.text`：**文本增量本体**
- `chunk.block.{type,id,name,text,arguments}`、`chunk.blockType`、`chunk.index`
- `chunk.argumentsDelta`（工具参数增量）
- `chunk.reason.kind`（结束原因）、`chunk.usage.{inputTokens,outputTokens,totalTokens}`

`end.outcome.kind` 为 `committed` 或 `abandoned`；`committed` 时 `eventType` 指向落定的持久事件。

### 1.5 模型目录

```json
{
  "default": { "provider": "", "model": "", "reasoningEffort": "?" },
  "routableProviders": ["..."],
  "groups": [{ "id": "", "name": "", "models": [{ "id": "", "name": "", "description": "?", "reasoning": { "efforts": [{ "id": "", "name": "", "description": "?" }], "defaultEffort": "?" } }] }],
  "failures": [{ "id": "", "name": "", "message": "" }]
}
```

分组字段是 `name`；模型不带 contextWindow/maxTokens，只带 Mimi 需要的展示与推理档位。
只展示 provider 真正声明的 reasoning 档位。

### 1.6 反向交互与应答

两条 waterfall。会话归属由帧上的 `agentId` 给出——`#492` 隔离实验捕获的原始帧里
（`logs/smoke-frames.json`），审批与追问都带 `agentId`，值就是 `session-<会话 id>`，
与 `session/create` 返回的 `sessionId`、`session/list` 里的条目一致：

```json
{ "type": "waterfall", "event": "approval/request", "eventId": "", "agentId": "session-…",
  "request": { "toolName": "write", "callId": "", "reason": "" } }
{ "type": "waterfall", "event": "user-questions/request", "eventId": "", "agentId": "session-…",
  "request": { "questions": [{ "id": "", "question": "", "options": [{ "label": "" }] }] } }
```

> 更正：早前按"waterfall 帧不带会话标识"实现，把 `callId` 反查（乃至"唯一活跃会话"
> 兜底）当成归属依据，是不完整的。`agentId` 是实测存在的会话标识，是主判据；`callId`
> 只在 `agentId` 缺失时作复核用。两者都取不到时适配层暂存等待（有界），不猜测。

应答走 `POST /api/$events/result`，参数为 `{clientId, eventId, outcome}`：

- 审批：`outcome = {kind: "result", value: "rejected"}`，取值域为 `allowed-once | rejected | cancelled | unavailable`。
- 追问：`outcome = {kind: "result", value: {answers: [{id, selected: [...]}]}}`。

多端语义（实测）：首个有效应答生效，其他端收到同 `eventId` 的 `cancel`，迟到应答为空操作。断线重连后新客户端会重投**同一个** `eventId`。应答 `kind` 只有 `result`，不存在单独的 rejection 种类。

### 1.7 持久事件类型（实测出现）

`turn/start`、`turn/end`、`step/start`、`step/end`、`user/message`、`assistant/message`、`tool/call`、`tool/result`、`session/title`、`session/title-llm-request`、`system/message`、`agent/inbox/spliced`、`approval/asked`、`approval/decided`、`request/header`、`request/context`。

**`turn` 与 `step` 在 Harness 里是数字，不是字符串 id。** 适配层必须据此合成稳定字符串标识，不能假设上游给了 id。

各事件 `data` 的关键字段：

| 事件 | `data` |
| --- | --- |
| `turn/start` / `turn/end` | `{turn: number}`；`turn/end` 另有 `reason.kind`（`completed` 或非 completed） |
| `step/start` / `step/end` | `{turn, step}` |
| `user/message` | `{id, role, content[], source: {kind, rpcId}}` —— **`source.rpcId` 就是 prompt 的 requestId**，用于消息去重 |
| `assistant/message` | `{message: {id, role, content[], source}, step, turn, stream[], usage: {inputTokens, outputTokens, totalTokens}}` |
| `tool/call` | `{callId, name, arguments（字符串）, step, turn}` |
| `tool/result` | `{message: {id, role, content[]}, meta: {path, lines, offset, totalLines}, step, turn}` |
| `session/title` | `{title, source: {kind}, messageSeqs[]}` |

`content[]` 里出现过的块字段：`{type, text}`，工具块 `{type, id, name, arguments, content: [{type, text}], isError, toolCallId}`。

## 二、Mimi ← agentd（回程方向）

适配层必须产出 Mimi 已消费的 app-server 形状，方法子集限定为：

`thread/list`、`thread/search`、`thread/start`、`thread/read`、`thread/turns/list`、`turn/start`、`turn/interrupt`、`model/list`。

要点（依据 iOS 读取点）：

- `thread/list` / `thread/search` / `thread/turns/list` 的结果是 `{data: [...], nextCursor}`；**`nextCursor` 键必须存在**（可为 `null`），`thread/turns/list` 缺失该键会整页判为无效响应。
- `thread/start` 结果必须给 `result.thread.id`；`turn/start` 结果必须给 `result.turn.id`——否则中断对账、active 清理与消息去重都会退化。
- `turn/interrupt` 必须带有效 `turnId`，且与 follow 快照及实时事件中最近的运行轮次一致；已结束、已变化或无法确认的目标一律拒绝。Harness 只提供会话级 `session/cancel`，不支持原子条件取消，因此校验与取消之间仍可能被其他客户端切换轮次；当前能力不保证严格只取消指定 turn。
- **`turn/start` 的 `result.turn.id` 只能绑定本次请求对应的 turn。** 判据是 `user/message` 的 `source.rpcId` 等于本次 prompt 的 `requestId`（也就是客户端传的 `clientUserMessageId`），turn 号按记录顺序归入该消息所属的 turn 桶。`turn/start` 事件本身不带 requestId，因此"等下一个出现的 turn 编号"在多端（Harness Web 页面、子 Agent）或排队投递的场景下会把别人的轮次回给客户端；等不到就不带 `id` 应答，而不是编一个。
- **`turn/start` 的 `model` 与 `effort` 必须落到会话上。** Harness 侧只有 `session/selectModel` 能改会话的模型选择，而 `provider` 是它的必填项。Mimi 的 iOS 端只在 `thread/start` 上带 `modelProvider`，后续 `turn/start` 只带 `model`。provider 的确定不能按模型名推断，只能按证据强度逐层取：本次请求带的 `modelProvider` → 会话自记的选择（`model/selection`、`request/header`）→ 会话创建时记下的 `modelProvider` → 目录唯一命中；同名模型出现在多个 provider 下且都无证据时拒绝并列出候选，而不是替用户挑一个。模型不在目录里、或 `effort` 不在该模型声明的 `reasoning.efforts` 里时一律回绝，不回退到 Harness 的默认模型。
- `item/started` / `item/completed` 的通知体是 `{item: {type, id, ...}, threadId, turnId}`。`type` 是唯一判别字段，未识别的类型整条丢弃。
- **`turnId` 对每一种 item 都要给出，不能只有 agentMessage 带。** 客户端把 `(turnId, itemId)` 合成消息标识，并据此把乐观气泡升级成 turn-scoped 身份。`user/message` 与注入上下文的记录里没有 `turn` 字段（实测只有 `assistant/message` 与 `step/*` 带），归属只能按"记录落在哪个 turn 桶里"顺序解析；历史路径用同一套切分，两边口径必须一致。缺 `turnId` 时同一条消息在历史与直播里会得到不同标识，表现为刷新后气泡重复、注入上下文被拆成"历史一组、直播一组"。取不到归属时如实省略该字段，不合成 `t0`。
- **每个 item 与每个 turn 都要带时间**：item 用 `createdAt`，turn 用 `startedAt` / `completedAt`。Harness 的记录信封里每条都有 `time`（实测为**毫秒**，例 `1789726449254`），而 item 的 `data` 里没有时间、`turns/list` 也不给 turn 起止时间，因此这是历史唯一可用的时间来源。少了它客户端只能整段兜底成"没有时间"，实测退化为 epoch 并显示成 `01/01 08:00` 并打上估算标记。原样透传毫秒，不做秒/毫秒换算（客户端按数量级兼容两种），记录没带时间时不写字段而不是补 0。
- `item/agentMessage/delta` 通知体是 `{threadId, turnId, itemId, delta}`，取自 `assistant-stream` 的 `chunk.text`。
- `userMessage` 项必须带 `clientId`（回显 prompt 的 requestId），且通知需带 `clientUserMessageId`，否则 iOS 整条丢弃该消息。
- `user/message` 记录的 `source.kind` 不是 `user` 时是 Harness 注入的上下文（工作区指令 `agent-instructions`、技能目录 `skill-catalog`、运行时快照/通知 `plugin` 等）。这类记录在 Harness 里同样是 `role="user"`，只有 `source.kind` 能把它与真实用户消息区分开，因此**直播与历史必须投影成同一套 `systemContext` 形状**：`{type: "systemContext", id: "c:<记录 id>", text, sourceKind, sourceForm?}`，不带 `clientId` / `clientUserMessageId`；iOS 把它渲染为 system 侧可折叠上下文，而不是右侧用户气泡。正文为空时整条丢弃，避免留下没有内容的上下文行。`source.kind` 缺失（更早的记录）仍按用户消息处理。
- 反向请求 `item/commandExecution/requestApproval` / `item/fileChange/requestApproval` / `item/fileRead/requestApproval` 的应答是 `{"decision": "<枚举>"}`；`item/tool/requestUserInput` 的应答是 `{"answers": {"<questionId>": {"answers": ["..."]}}}`。
- 收到移动端应答只代表开始回传。Harness 确认成功或发送取消后才终结交互；HTTP 回传失败会结束当前网关连接，由重新订阅获取仍 pending 的交互。结果未知时不自动重发，已被 Harness 接受的决定不会因本地未收到确认而主动重试。
- `serverRequest/resolved` 用于清除挂起卡片，通知体为 `{threadId, requestId}`。

## 三、尚未验证

以下在本机 Harness 上没有实跑，实现时必须按未验证对待：

1. 真实模型（火山 Coding Plan）的鉴权、推理参数与工具结果兼容性——属宿主配置范围，不是本接入的验收项。
2. 并发首次重复提交、异步附件竞争、steer 语义、历史缺口修复、`session/control` 基线、宿主进程重启恢复。
3. `session/control` 流的帧形状（本机只确认它必须走流载体）。
4. `session/search` 的成功结果形状（本机部署未开启索引，只验证了参数正确）。
5. Mimi App 与 Harness Web 页面同时操作同一会话的行为。
6. `session/selectModel` 的真实执行结果。参数与结果形状来自生成描述符（源码级），本机没有实跑过：网关在每次带模型选择的 `turn/start` 上都会调用它，失败按 fail-closed 回错误帧而不是继续投递。若真实部署的行为与描述符不符，表现会是"带模型选择的发送被拒"，而不是静默用了别的模型。
7. `model/selection` 事件的形状与会话选择投影口径（`pending ?? lastUsed`）。本机只确认 `request/header` 出现在持久事件里，`model/selection` 是按源码（model-selection-projection.ts）实现的、未经运行时回放验证。它只作为"无 provider 时读出会话当前选择"的辅助依据，取不到时会退回目录唯一命中或拒绝，不会据此选错供应商。
