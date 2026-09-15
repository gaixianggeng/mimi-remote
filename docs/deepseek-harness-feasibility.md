# DeepSeek Harness 接入可行性调研（#492）

日期：2026-09-15。关联 [#492](https://github.com/gaixianggeng/mimi-remote/issues/492)、[#491](https://github.com/gaixianggeng/mimi-remote/issues/491)。本文交付调研和隔离实验，不声明已完成产品接入。

范围说明：本文已按 #492 在 2026-09-15 确认的范围更新。模型供应商、模型 endpoint、密钥、套餐、推理参数和模型调用均由 Harness 管理，供应商实调与编码效果对比不属于 #492 的验收项，也不是接入前置条件。早期版本中“先验证真实套餐，再决定接入”的结论已撤回；接口事实和隔离实验结果继续有效。

## 目标与结论

**接入判断以 Harness 的公开服务契约与 agentd 侧的适配成本为依据。** Harness 已具备原生会话接入所需的主要服务端能力。协议差异集中在字段、事件和反向交互转换，不能只替换服务地址。

本机已验证：安装启动、Cookie 认证、模型目录、流式输出、真实文件读取、多轮工具结果回传、双客户端订阅、断线后重放追问、首答胜出、历史恢复、已观察请求的重试去重、沙箱拒绝与审批拒绝、会话中断。模型全部由本地固定响应模拟器提供，**真实模型调用为 0**。两位观察者是协议客户端，不是已接入的 Mimi App 或实际浏览器页面。

接入边界为 `Mimi → Mac 上的 agentd → Harness 服务`。Mimi 接入的是 Harness 的服务接口；若展示模型列表或允许选择模型，只消费 Harness 返回的元数据并转发选择，不维护自己的供应商配置。事件转换、运行进程和凭据都留在 Mac 宿主。现有 Codex/Claude 生产代码及配置未改动。

当前缺口集中在 agentd 转发通路、完整运行状态恢复和实际双端共享会话，而不是供应商侧凭据或套餐。

## 方案

### 1. 固定版本与生命周期

| 对象 | 本轮事实 |
| --- | --- |
| Mimi 基线 | `0974433497ecfb92a0239c4cfd9dcc1f171e07e3` |
| Harness 主包与 231 个同版本组件 | `0.1.5-rc.2`；npm overrides 固定组件，lockfile 留本机 |
| Harness 源码 | tag `dsh-v0.1.5-rc.2`，commit `fb2c4b9e698e30edb738bca4cf0618587db7d203` |
| 火山插件 | `@volcengine/ark-plan-api@0.1.0` |
| 火山源码 | `a5b260b46c03dc4ae7ee221eda77bb572fc61665`；发布包的 README 与核心 patch 和该 commit 一致 |
| 运行环境 | Mac arm64、macOS 27.0、Node `22.22.3`、npm `10.9.8`、Cordis `4.0.2` |
| 声明的运行依赖 | Node `^22.19.0 || >=24.0.0`；源码构建使用 pnpm `11.7.0`，本实验使用 npm 发布产物 |
| 启动与停止 | 前台 `dsh web --no-open --port 0`，仅绑定回环；实验结束发送 SIGTERM，5 秒后仍未退出才 SIGKILL |
| 状态 | 独立 `DSH_HOME`；配置、凭据库、会话日志与 profile 在该目录；关闭移动连接不会结束宿主任务 |

最终运行的 `package-lock.json` SHA-256：`16c80ac70110e39382458b9e8b8a0cfccb3472a8235718bb090774bf0ffec54a`。锁文件与完整日志留本机，不包含在公开交付中。

初次安装精确的 `dsh@0.1.5-rc.1`，实际仍解析出 230 个 rc.2 组件，因为上游依赖用了 `^`。最终实验统一到 rc.2 并固定这些组件。两版本的 Gateway、Session Controller、审批、追问相关源码和测试目录没有差异。**只固定 CLI 主包不足以固定运行时。** 升级时需要同时检查插件组合和锁文件。

上游仍明确标注开发者预览、可能破坏兼容性。对外包导出、生成的 Remote 接口和公开文档可以作为版本内契约；Cordis 实例、pending Map、Web UI 内部状态和日志内部格式不能当稳定跨版本 API。[Harness 发布源码](https://github.com/deepseek-ai/deepseek-harness/tree/fb2c4b9e698e30edb738bca4cf0618587db7d203)、[官方安全说明](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/SAFETY.md)。

### 2. 附加参考：供应商 Coding Plan 路径

本节记录固定版本下观察到的供应商插件事实，供 Harness 宿主配置参考。**供应商选择、端点和密钥由 Harness 管理，不是 Mimi 的职责，也不属于 #492 的验收范围。**

火山文档现在明确列有 [DeepSeek Harness 接入页](https://docs.volcengine.com/docs/82379/2637930?lang=zh)。Issue 原入口 `2188958` 当前是 OpenCode 接入页。实际配置以[官方插件 README](https://github.com/volcengine/ark-cli/blob/a5b260b46c03dc4ae7ee221eda77bb572fc61665/dsh-plugins/ark-plan-api/README.md)和[固定 patch](https://github.com/volcengine/ark-cli/blob/a5b260b46c03dc4ae7ee221eda77bb572fc61665/dsh-plugins/ark-plan-api/cordis.patch.yml)核对。

| 项目 | 使用方式 |
| --- | --- |
| 国内套餐 provider | `ark-coding-plan-cn` |
| 套餐 base URL | `https://ark.cn-beijing.volces.com/api/coding` |
| 协议与实际请求路径 | `anthropic-messages`；SDK 补 `/v1/messages`，可能带 `?beta=true` |
| 凭据引用 | `ARK_CODING_PLAN_CN_API_KEY`，仅留宿主 |
| 当前插件中的 DeepSeek 模型 | `deepseek-v4-pro`、`deepseek-v4-flash`；均声明 text-only、context 1,024,000、maxTokens 384,000 |
| 不能混用的路线 | `ark-cn` 的 `/api/v3/compatible` 是后付费，不是 Coding Plan |
| 另一个兼容入口 | `/api/coding/v3` 用于 OpenAI Chat Completions 自定义接入；本次优先沿用官方 Anthropic 插件 |

插件同时加载 Agent Plan、国内/海外 Coding Plan 和后付费目录。**模型出现在目录不等于账户有权限或额度**；因此 Mimi 不应按模型名称推断付费路线，也不应替 Harness 决定 provider。没有查到旧模型正式停售证据，本文不把目录中的 V4 推断为 V3.2 已下线。

官方插件声明支持工具调用和流式传输，但该版本未给 V4 配置 `reasoningEfforts`。因此不能声称 Harness 已能通过官方插件选择推理档位。Harness 的 OpenAI 自定义路线另有 `reasoning_effort`、`thinkingFormat: deepseek`、`supportsDeveloperRole`、`maxTokensField` 等兼容开关；这些不能机械套用到 Anthropic Messages 路线。[固定 provider 文档](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/docs/user/guide/providers.md)。

本机发现的 DeepSeek 环境配置不能确认为 Coding Plan，本轮未使用其密钥，也未发起任何真实模型调用。若后续确需核对套餐用量，可在控制台记录调用前后用量，官方 `arkcli usage plan --product coding-plan` 通过 `GetCodingPlanUsage` 查询额度。arkcli 识别 SSO、AK/SK 和 APIKey profile，可见范围取决于登录身份或 Key 绑定身份，不能假定未知来源的推理 Key 有查询权限。一次极小调用若未改变展示百分比，也不能仅凭此认定未计费。[火山额度查询说明](https://github.com/volcengine/ark-cli/blob/a5b260b46c03dc4ae7ee221eda77bb572fc61665/skills/arkcli-usage/references/arkcli-usage-plan.md)。以上仅为宿主侧参考，Mimi 不承担该核对。

### 3. Mimi 能力映射

以下 Harness 名称都是固定版本的实际 Remote/事件。Mimi 列表示适配目标，不代表本轮已经实现。

| 用户能力 | Mimi 当前协议 | Harness 来源与适配要求 |
| --- | --- | --- |
| 会话列表/搜索 | `thread/list`、`thread/search` | `session/list`、`session/search`；列表包含持久会话，不因读取而激活全部 Agent；agentd 按授权工作区裁剪 |
| 新建 | `thread/start` | `session/create` 的 `cwd/workspaceId/sessionId/agentPreset`；适配层生成稳定 thread 映射 |
| 历史/续聊 | `thread/read`、`thread/turns/list`、`thread/resume` | `session/follow` snapshot + `session/page`；prompt 等写操作可恢复冷会话，不能虚构一个不存在的 resume RPC |
| 发消息 | `turn/start` | `session/prompt`，含 `requestId`、`sessionId`、`mode`、`content`；重试保持 requestId |
| 流式输出 | turn/item notification | `/api/remote.mux` 的 `session/follow`；durable event 与 `assistant-stream` 分开，结束后归并到持久 assistant 记录 |
| 工具执行 | command/file/tool items | `tool/call`、`tool/result`，由 callId 关联；原生 read/write 等应转为已有展示类型 |
| 权限审批 | approval reverse RPC | `$events` 的 `approval/request` waterfall；应答经 `$events/result`，值为 `allowed-once/rejected/cancelled/unavailable` |
| 用户追问 | `item/tool/requestUserInput` | `user-questions/request` waterfall；答案为 `answers[]`，不能把自然语言回复伪装成结构化答案 |
| 中断 | `turn/interrupt(threadId,turnId)` | `session/cancel(sessionId)`；作用于当前共享轮次，需要在 agentd 校验预期 turn 后才发送 |
| 运行中输入 | `turn/steer` | `session/prompt(mode=steer)` 与 queue 语义不同；首版可只开放 queue，不声明未验证 steer |
| 模型选择 | `model/list` 与 model/effort | `session/modelCatalog`、`session/selectModel`；只展示该 provider 真正声明的 reasoning 档位 |
| 恢复运行态 | thread/turn 与 pending requests | `session/follow` 恢复历史，`session/control` 替换 queue/jobs/projection 基线，`$events` 重放仍 pending 的交互 |

来源：[Session Controller 方法](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/session-controller/src/index.ts)、[请求和帧类型](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/session-controller/src/types.ts)、[Remote 流协议](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/gateway/src/stream-protocol.ts)。

#### 实测 HTTP 封装

直接按 API Gateway 文档概述只发送 `{args: ...}` 会得到 `gateway/bad-request`，即使 HTTP 为 200。实际需要 Connection RPC 外层，必须检查 `result.ok`：

```json
{
  "type": "client-request",
  "rpcId": "fixture-request-1",
  "method": "session/modelCatalog",
  "payload": { "args": {} }
}
```

发送到 `POST /api/session/modelCatalog`，携带 Cookie。响应为 `server-response`，业务结果在 `result`。这不是 Codex JSON-RPC 的直接透传。[实际 HTTP carrier](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/client/connection/src/rpc-host.ts)。

### 4. 共享会话与恢复语义

| 情况 | 固定版本结论 | 证据等级 |
| --- | --- | --- |
| 两客户端订阅同一会话 | 均收到会话事件和相同 eventId 的追问 | 本地实测 |
| 全部客户端断开再连接 | 原进程中的 pending waterfall 仍在，新 generation 重投原 eventId | 本地实测追问；审批走同一源码机制 |
| 两端同时应答 | 首个有效 result/rejection 生效；其他端收到 cancel，迟到应答为空操作 | 本地实测追问 |
| 同一个已观察 requestId 重试 | inbox 或持久 user/message 已包含该 ID 时，不再插入 | 本地实测持久消息重试 |
| 首次重复请求真正并发 | 去重检查与插入之间未见原子保留；不能承诺 exactly-once，尤其异步附件路径 | 源码检查，未做竞争实测 |
| 不同 requestId 同时输入 | 按宿主实际完成 admission 的先后入队，不保证按两端发送时间排序 | 源码检查，未做同时输入实测 |
| 任意授权客户端 cancel | 取消共享 Agent 当前轮，撤销等待交互；队列保留 | 实测撤销追问；保留队列为源码结论 |
| 宿主进程重启 | 历史有持久日志；pending waterfall、jobs 等进程内状态不能直接重建 | 源码检查，未运行崩溃恢复实验 |

Gateway 的 `pendingRemoteEvents` 在内存中；`approval/asked` 审计日志不能当作可恢复的等待请求。断线恢复和进程重启恢复必须分开显示。Mimi 还需按 eventId 保存多个 pending 交互，收到 cancel 即撤销对应卡片。[Gateway 广播与应答处理](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/gateway/src/index.ts#L413)、[prompt 去重与 admission](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/session-controller/src/commands.ts#L305)。

### 5. 接入位置与权限边界

Harness Web API 不是一个可直接换 URL 的 Bearer API。启动时生成 token；仅 `GET /?token=...` 可换取绑定 hostname+port 的 Cookie，再 303 跳转。普通 API 不接受 Authorization token；没有 Cookie 实测为 401。Host/Origin 校验仍独立存在。官方 `dsh web` 不允许监听 `0.0.0.0`。[Connection 认证契约](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/client/connection/README.md)。

最小宿主适配层可以管理这个本地 Cookie 和 WebSocket；移动端继续使用 agentd 已有认证。禁止将启动 token、Cookie、provider Key 或 `$events.ready.host.home` 等内部事实直接转发给移动端。只转换 Mimi 所需字段。Harness 的已认证文件路由能读取工作区外普通文件，因此不能把整个 `/api/*` 无条件代理到移动端。[文件读取边界](https://github.com/deepseek-ai/deepseek-harness/blob/fb2c4b9e698e30edb738bca4cf0618587db7d203/packages/api/session-controller/README.md#session-media-references)。

Mimi 已有的 project/browse_roots 授权、真实路径解析、thread ownership、method allowlist 必须继续生效。相关实现是 `internal/httpapi/appserver_gateway_scope.go`、`appserver_gateway_policy.go`。Harness 会话自己的 read-only/workspace-write/approval policy 需要显式映射；未支持的权限模式应拒绝，不能落到 Codex 默认完全访问语义。

## 实现与验证

### 最小正式接入清单

1. **宿主进程和协议转换。** agentd 管理一个固定插件组合的 Harness，转换 initialize、thread、turn、item、模型和反向交互。按上游事件稳定关联 ID，保留分页游标和故障结果。不要直接解析 UI 文本。
2. **显式能力表。** 当前 `appserver_gateway.go` 只识别 Codex/Claude，未知 Runtime 的方法选择可能落到 Codex 全集。新增 Runtime 必须显式声明方法与权限。首版不开放 Mimi 动态工具、goals、fork、插件管理和文件任意读取。
3. **复用 iOS Runtime 投影。** `CodexAppServerSessionRuntime.swift` 已参数化 provider；主要硬编码在 `CodexAppServerSessionClients.swift` 的二元 bundle、路由和模型合并。将这些改为按 Runtime ID 查找，保留已有会话与交互状态机。旧数据缺失 provider 时的兼容必须和未知 provider 分开。
4. **恢复与交互。** 先 follow，再使用 opening snapshot 建立历史和运行态；掉线重开并替换基线，按事件序号去重。Mimi 自己的重试串行化，拒绝过期 turn 的取消；第三方 Web 并发语义仍以 Harness 为准。

以上为后续范围建议，本 Issue 没有实施这些改造。#491 可独立交付模块管理，不必等待 DeepSeek Runtime。

### 本轮实际实验

复现程序：[gh-492-harness-smoke.mjs](quality/gh-492-harness-smoke.mjs)。模拟器使用 Anthropic Messages SSE；真实 Harness 执行 read/write 工具、发布事件、等待应答和持久化记录。程序只继承 PATH，设置独立 DSH_HOME 和本地假 Key。实际 provider 选择为 `research-mock`，不会调用火山。

最终 rc.2 运行检查：

| 检查 | 断言 |
| --- | --- |
| 启动及认证 | 回环动态端口，未认证 401，token 换 Cookie 后 RPC 成功 |
| 官方插件 | 无 Key 加载 `ark-coding-plan-cn` 及 V4 Pro/Flash 目录 |
| 多轮工具 | 模拟模型 → 真实 read → 模型 → ask_user_question → 模型完成 |
| 双订阅 | 同一追问的 eventId 一致 |
| 断线恢复 | 两个旧连接都关闭，新连接重放相同 pending eventId |
| 应答竞争 | 首答后另一端收到 cancel，迟答不增加模型调用 |
| 历史 | 新连接 opening snapshot 包含已完成输出 |
| 重试及结果 | 复用已持久化 requestId 不调用模型；精确检查 tool_result 和结构化 answers |
| 权限 | 工作区外写入先被拒，再发更宽权限审批；拒绝审批后仍没有目标文件 |
| 中断 | 共享会话 cancel 撤销新追问，并以非 completed 原因结束 |

前一个多轮任务恰好 3 次模型请求；整个实验共 7 次带工具的模拟请求。自动标题可能另有本地模拟请求，不计入这 7 次。日志包含本机路径、启动 token、会话标识和原始帧，只保留本机；公开提交仅保留程序与脱敏结论。

以下仍未验证：实际 Web 页面与 Mimi App 共同操作；并发首次重复提交、异步附件竞争、steer、历史缺口修复、完整 control 基线及宿主重启恢复。供应商侧的真实鉴权、推理参数、工具结果/流式兼容性与编码质量同样未验证，但属于宿主配置范围，不是 #492 的验收项。上游已有测试仅作源码证据，本轮没有执行上游全量测试或产品 iOS/Go 回归。

### 隔离复现步骤

在 Mimi 仓库根目录执行。专用 marker 表示这个目录属于可重复运行的实验；脚本会覆盖其中的实验配置、fixture 和日志，不应将它放到已有用户项目或生产 DSH_HOME。

```bash
task_cache="$(bash ./scripts/development-cache-path.sh gh-492-harness)"
mkdir -p "$task_cache/runtime" "$task_cache/state" "$task_cache/workspace" "$task_cache/logs"
printf '%s\n' isolated-gh-492 > "$task_cache/.gh-492-harness-smoke-root"
npm install --prefix "$task_cache/runtime" --save-exact --no-audit --no-fund @deepseek-ai/dsh@0.1.5-rc.2
node - "$task_cache/runtime" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const target = path.join(root, 'package.json');
const manifest = JSON.parse(fs.readFileSync(target));
const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json')));
manifest.overrides = {};
for (const [name, pkg] of Object.entries(lock.packages)) {
  const moduleName = name.split('node_modules/').pop();
  if (moduleName.startsWith('@deepseek-ai/dsh') && pkg.version?.startsWith('0.')) {
    manifest.overrides[moduleName] = '0.1.5-rc.2';
  }
}
fs.writeFileSync(target, JSON.stringify(manifest, null, 2) + '\n');
JS
npm install --prefix "$task_cache/runtime" --no-audit --no-fund
env -i PATH="$PATH" LANG=en_US.UTF-8 DSH_HOME="$task_cache/state" \
  "$task_cache/runtime/node_modules/.bin/dsh" plugin --profile web add @volcengine/ark-plan-api@0.1.0
node docs/quality/gh-492-harness-smoke.mjs "$task_cache"
shasum -a 256 "$task_cache/runtime/package-lock.json"
```

预期为 10 条 `PASS`，进程随后退出，结果保存在 `$task_cache/logs/smoke-summary.json`。未来重新解析依赖可能产生不同锁文件；保留本轮锁文件才能重建本轮完整依赖。脚本会拒绝关键组件版本不一致，而不是静默使用新版本。

### 附：供应商侧验证（可选，不在本 Issue 范围）

若后续单独启动供应商侧验证，可复用本节方法。该验证不由 Mimi 承担，也不阻塞 agentd 适配。新建一份隔离状态，只选择一个已确认归属的 Coding Plan provider/model，不使用生产代码作为输入。用一个公开合成小项目运行“读取缺陷测试 → 修改纯函数 → 运行测试”的受控任务，再补一个多文件修改任务。记录固定 prompt、仓库 hash、模型和插件版本、推理选项、测试通过率、人工介入次数、耗时、请求数和套餐用量。

同一个任务内验证：至少一次完整流式回复与多轮 tool_use/tool_result；审批拒绝和追问应答；断开客户端后恢复。若要比较 OpenCode，应使用同一模型、任务、权限、上下文预算和重复次数。Harness 系统提示与工具结构不同，结果只能说明该配置下的样本表现，不能推广为品牌优劣。

## 风险与成本判断

**主要维护成本是 Harness 的 Remote/事件协议变化。** 宿主侧还需要维持一个固定的插件组合与锁文件，因为只固定主包不足以保证运行时一致。需要一个固定版本组合、上述定向实验和按能力降级。主包升级不能自动放宽权限或继承新增方法。当前还没有稳定兼容期承诺，不适合不经验证自动升级。

对小团队的工作量判断为**中等到偏高**：agentd 事件归一、iOS 二元路由拆除、审批与重连状态对齐是主要工作，模型接入本身由 Harness 侧插件承担。尚未做真实原生适配，不能可靠承诺人日。

OpenCode 同样是额外本地服务，公开提供 OpenAPI 3.1、HTTP/SSE 和 Basic Auth；不是比 Harness 多一个进程。它的优势是另一种较直接的服务接口，代价是重新适配会话和事件语义。本轮没有运行 OpenCode，也没有同条件效果数据，不据此推荐替换。[OpenCode 官方服务接口](https://opencode.ai/docs/server/)。

接入判断：保留 Harness 为可接入候选，以服务契约和适配成本为依据推进最小 agentd 适配通路；不立即承诺正式 Runtime、发布或可恢复宿主崩溃。供应商侧验证不构成该判断的前置条件。
