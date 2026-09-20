# Harness 原生客户端契约（`contracts/harness-native`）

本目录冻结 Mimi 原生消费 DeepSeek Harness 的 wire 契约与脱敏夹具，是 #498 改造（PR #499）的实施依据。

- 实施契约与判定：`docs/architecture/harness-native-client.md`
- 版本、来源、blob SHA 与夹具 SHA-256：`manifest.json`
- 夹具：`fixtures/`

## 状态

`status: frozen`（Gate A 待负责人批准）

wire 事实已由**真实运行的 Harness 实跑核对**，不再只是源码推导：

- 实跑版本：`@deepseek-ai/dsh` **0.1.5-rc.2**（npm dist-tag `latest`，tag `dsh-v0.1.5-rc.2`，commit `fb2c4b9e`）。
- 运行方式：**隔离环境**——独立 `DSH_HOME`、独立端口、独立进程；未安装、未重启、未升级用户任何 Harness。
- 模型侧：上游自带的 `@deepseek-ai/dsh-llm-mock-server`（可编排 OpenAI 兼容 SSE 假模型），
  经 `llm-pi-ai` 手写路由 `h00-loopback` 接入，**无任何真实供应商凭据、无真实供应商调用**。
- 源码阅读取自 `ddefc45f` = tag `dsh-v0.1.6-alpha.2`，仅用于解释成因；契约以实跑版本为准。

⚠️ **复现前提**：npm 扁平化安装会产出多份 `@deepseek-ai/dsh-scope` 物理副本，而 `dsh-scope` 用
`Symbol` 作 scope 键，多实例会让 `scopeOf()` 恒返回 `undefined`，导致 `session/create` 与 `prompt`
全部失败。复现采集前必须先把所有副本折叠为指向同一目录的符号链接。详见 `manifest.json`
的 `liveCaptureEnvironment.criticalPrerequisite`。

## 夹具来源分级

| 级别 | 含义 | 当前 |
|---|---|---|
| `live-capture` | 从真实运行的 Harness 采集并保留可核对形状 | **11 个夹具** |
| `upstream-source` | 从上游源码或冻结 npm 包的类型定义推导，附 blob / 文件摘要 | **3 个夹具** |
| `repo-recorded` | 引用本仓库旧文档记录的 #492 实测事实 | 仅作交叉核对 |

每个夹具文件顶部都有 `provenance` 与 `source` 字段标明级别与出处；逐文件 SHA-256 记在
`manifest.json` 的 `fixtureDigests`。**任一夹具被改写都必须同步更新摘要。**

## 未采集（源码级，已在 manifest 标为 `notProven`）

`session/modelCatalog` 原始响应、审批请求/应答（`$events` waterfall）、跨连接是否收到 `api-session/added`、Host 重启后的
`ready`/`close` 语义、用户手机上 App 的构建版本。这四项按源码级处理，实施时不得当成实测事实。

## 脱敏纪律

夹具中的 cwd、sessionId、eventId、clientId、attemptId、rpcId、callId 全部是 `*-fixture-*` 形式的虚构值。
不含真实主机名、本机路径、真实会话、正文内容或任何凭据。
协议常量（类型名、事件名、枚举值、键名、工具名、模型与供应方名）原样保留，否则夹具就失去判别力。

## 采集真实帧

`scripts/harness-native-probe.mjs` 是**只读**探针：不启动/安装/重启/升级任何 Harness，
不打印或落盘 token 与 Cookie，输出只含结构骨架与错误码。

```bash
HARNESS_ORIGIN=http://127.0.0.1:<port> HARNESS_TOKEN=<启动 token> \
  node scripts/harness-native-probe.mjs <absolute-research-root>
```

研究根目录必须含标记文件 `.h00-harness-probe-root`，内容为 `isolated-h00`。

## 使用

Go 与 Swift 测试应直接读这些夹具，用它们区分正确与错误的实现行为。
最容易写错、也是夹具主要覆盖目标的四条事实：

1. `session/list` 的 `payload.args` 键是 **`_request`**（带下划线），不是 `request`。
2. 错误对象字段是 **`details`**，不是 `data`。
3. WS 服务端帧带 `type` 判别值：`item` / `error` / `end`，内容在 `item` 的 `value` 里。
4. assistant-stream 的 `chunk.type` 用**连字符**（`text-delta`），不是下划线（`text_delta`）。
