# DeepSeek Harness 接入协议参考（#498）

本文记录 agentd 与 DeepSeek Harness 之间的线路契约：`internal/harnessclient` 与
`/api/harness/rpc`、`/api/harness/ws` 原生中继的实现依据。

它**不再**描述 Mimi app-server 形状。`deepseek` 曾有一条把 Harness 事件翻译成 app-server
协议、再经 `/api/appserver` 转发的适配层；该层已整体删除，`deepseek` 现在只由原生通道承接。
回程形状的记录见 `docs/architecture/harness-native-client.md`。

## 证据来源与等级

| 事实 | 来源 | 等级 |
| --- | --- | --- |
| 认证握手、RPC 外壳、`session/prompt` 参数、waterfall 形状、`$events/result` 编码、follow 帧分类 | #492 隔离实验 `docs/quality/gh-492-harness-smoke.mjs` 在 Harness `0.1.5-rc.2` 上的真实运行 | 实测 |
| durable event 类型清单与字段路径、assistant-stream chunk 字段、snapshot 结构 | #492 实验留存的原始帧（本机 `logs/smoke-frames.json`，仅提取结构骨架，未公开提交） | 实测 |
| 方法的参数 wire 名、codec 模式、结果类型 | 本机 `@deepseek-ai/dsh-api-session-controller/lib/typert.host.js` 的生成描述符；`lib/types/types.d.ts` 的类型定义 | 源码 |
| `session/list`、`session/page` 的真实结果形状；`session/search` 在未启用索引时不可用 | 本仓库 `docs/quality/gh-498-control-plane-probe.mjs` 在本机 Harness 上的运行 | 实测 |

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
> 只在 `agentId` 缺失时作复核用。两者都取不到时中继暂存等待（有界），不猜测。

应答走 `POST /api/$events/result`，参数为 `{clientId, eventId, outcome}`：

- 审批：`outcome = {kind: "result", value: "rejected"}`，取值域为 `allowed-once | rejected | cancelled | unavailable`。
- 追问：`outcome = {kind: "result", value: {answers: [{id, selected: [...]}]}}`。

多端语义（实测）：首个有效应答生效，其他端收到同 `eventId` 的 `cancel`，迟到应答为空操作。断线重连后新客户端会重投**同一个** `eventId`。

> 更正：本节早前按审批路径的**观测**写成"应答 `kind` 只有 `result`，不存在单独的 rejection
> 种类"。那是观测结果，不是 wire 的能力边界：`parseRemoteEventResult` 明确接受
> `next` / `result` / `rejected` 三种 kind，中继不得因为只见过 `result` 就拒收另外两种。
> 详见 `docs/architecture/harness-native-client.md` 的 2.8。

### 1.7 持久事件类型（实测出现）

`turn/start`、`turn/end`、`step/start`、`step/end`、`user/message`、`assistant/message`、`tool/call`、`tool/result`、`session/title`、`session/title-llm-request`、`system/message`、`agent/inbox/spliced`、`approval/asked`、`approval/decided`、`request/header`、`request/context`。

**`turn` 与 `step` 在 Harness 里是数字，不是字符串 id。** 任何稳定的字符串标识都必须自己合成，不能假设上游给了 id。

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

### 1.8 构造原适配层时确认的 Harness 侧事实

下面几条是删除 app-server 适配层之前逐条核过的 **Harness 行为**（不是该层自己的约定），
对原生中继同样成立，因此留在本文件：

- **时间只有记录信封上有。** Harness 每条持久记录都带 `time`，实测为**毫秒**
  （例 `1789726449254`）；事件 `data` 里没有时间，`session/page` 也不给 turn 起止时间。
  原样透传毫秒，不做秒/毫秒换算。
- **`turn/start` 结果里的 `turn.id` 只能靠 `source.rpcId` 对账。** 判据是 `user/message`
  的 `source.rpcId` 等于本次 prompt 的 `requestId`；`turn/start` 事件本身不带 requestId，
  所以"等下一个出现的 turn 编号"在多端（Harness Web 页面、子 Agent）或排队投递时会把
  别人的轮次算进来。等不到归属就不给 `id`，不合成。
- **`source.kind` 是区分注入上下文与真实用户消息的唯一字段。** 工作区指令
  （`agent-instructions`）、技能目录（`skill-catalog`）、运行时快照/通知（`plugin`）在
  Harness 里同样是 `role="user"`；`source.kind` 缺失（更早的记录）只能按用户消息处理。
- **模型选择只有 `session/selectModel` 一个入口，且 `provider` 必填。** provider 不能按
  模型名推断：同名模型会出现在多个 provider 下。取不到唯一证据时应当拒绝并列出候选，
  而不是替用户挑一个。
- **`session/cancel` 是会话级，没有原子条件取消。** 校验目标与执行取消之间，轮次仍可能
  被另一个客户端切换。

## 三、尚未验证

以下在本机 Harness 上没有实跑，实现时必须按未验证对待：

1. 真实模型（火山 Coding Plan）的鉴权、推理参数与工具结果兼容性——属宿主配置范围，不是本接入的验收项。
2. 并发首次重复提交、异步附件竞争、steer 语义、历史缺口修复、`session/control` 基线、宿主进程重启恢复。
3. `session/control` 流的帧形状（本机只确认它必须走流载体）。
4. `session/search` 的成功结果形状（本机部署未开启索引，只验证了参数正确）。
5. Mimi App 与 Harness Web 页面同时操作同一会话的行为。
6. `session/selectModel` 的真实执行结果。参数与结果形状来自生成描述符（源码级），本机没有实跑过。按描述符它是 `provider` 必填、失败即拒绝；若真实部署行为与描述符不符，表现会是"带模型选择的发送被拒"，而不是静默用了别的模型。
7. `model/selection` 事件的形状与会话选择投影口径（`pending ?? lastUsed`）。本机只确认 `request/header` 出现在持久事件里，`model/selection` 是按源码（model-selection-projection.ts）实现的、未经运行时回放验证。它是"会话当前选了哪个模型"的辅助依据，取不到时只能退回目录唯一命中或拒绝。
