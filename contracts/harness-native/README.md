# Harness 原生客户端契约（`contracts/harness-native`）

本目录冻结 Mimi 原生消费 DeepSeek Harness 的 wire 契约与脱敏夹具，是 #498 改造（PR #499）的实施依据。

- 实施契约与判定：`docs/architecture/harness-native-client.md`
- 版本、来源与 blob SHA：`manifest.json`
- 夹具：`fixtures/`

## 状态

`status: frozen-pending-live-capture`

wire 事实全部来自上游源码（可 blob 校验），**未经本机安装版本实跑复核**：
本机没有可运行的 Harness，隔离安装被沙箱拒绝。解除方式见实施契约第六节。

## 夹具来源分级

| 级别 | 含义 |
|---|---|
| `live-capture` | 从真实运行的 Harness 采集。**当前为空**，待探针执行后补齐。 |
| `upstream-source` | 从上游源码的类型定义与生成器规则推导，附 blob SHA。当前全部夹具属于这一级。 |
| `repo-recorded` | 引用本仓库 `docs/deepseek-harness-protocol.md` 记录的 #492 实测事实。 |

每个夹具文件顶部都有 `provenance` 与 `source` 字段标明级别与出处。

## 脱敏纪律

夹具中的 cwd、sessionId、eventId、clientId、attemptId、rpcId、callId 全部是 `*-fixture-*` 形式的虚构值。
不含真实主机名、本机路径、真实会话、正文内容或任何凭据。

## 采集真实帧

```bash
HARNESS_ORIGIN=http://127.0.0.1:<port> HARNESS_TOKEN=<启动 token> \
  node scripts/harness-native-probe.mjs <absolute-research-root>
```

研究根目录必须含标记文件 `.h00-harness-probe-root`，内容为 `isolated-h00`。
探针**只读**，不启动/安装/重启/升级任何 Harness，不打印或落盘 token 与 Cookie，
输出只含结构骨架与错误码。

## 使用

Go 与 Swift 测试应直接读这些夹具，用它们区分正确与错误的实现行为。
最容易写错、也是夹具主要覆盖目标的四条事实：

1. `session/list` 的 `payload.args` 键是 **`_request`**（带下划线），不是 `request`。
2. 错误对象字段是 **`details`**，不是 `data`。
3. WS 服务端帧带 `type` 判别值：`item` / `error` / `end`，内容在 `item` 的 `value` 里。
4. assistant-stream 的 `chunk.type` 用**连字符**（`text-delta`），不是下划线（`text_delta`）。
