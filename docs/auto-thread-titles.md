# 自动会话标题设计

## 目标

新建 Codex 会话发送第一条用户请求后，由 Mac 端自动生成简短标题并持久化到 app-server。移动端应尽快看到标题，但标题生成不能阻塞正常对话，也不能把 Codex 凭据下放到 iPhone / iPad。

MVP 只覆盖通过 Mimi Remote 新建的 Codex 会话：

- `thread/start` 新建后，首个成功转发的 `thread/queue/add` 触发一次；非 SSH 旧客户端的 `turn/start` 仍兼容；
- `thread/resume`、历史线程、Claude 实验通道不触发；
- 用户或其他客户端已经设置名称时不覆盖；
- 失败时保留移动端现有的首条消息预览，不影响 Turn 生命周期。

## 方案

```mermaid
sequenceDiagram
    participant iOS as Mimi Remote iOS
    participant Gateway as agentd Gateway
    participant Codex as Codex app-server
    participant Title as agentd 标题任务

    iOS->>Gateway: thread/start
    Gateway->>Codex: 安全改写后转发
    Codex-->>Gateway: 新 thread
    Gateway-->>iOS: 新 thread
    iOS->>Gateway: 首个 thread/queue/add
    Gateway->>Codex: 先转发正常队列消息
    Gateway-->>Title: 异步提交 threadId + cwd + 首条请求摘要
    Title->>Codex: 独立 SSH proxy WebSocket + initialize
    Title->>Codex: thread/read（名称为空？）
    Title->>Codex: ephemeral thread/start（read-only / never）
    Title->>Codex: turn/start（low effort + outputSchema）
    Codex-->>Title: 结构化标题
    Title->>Codex: thread/read（写回前再次检查）
    Title->>Codex: thread/name/set
    Title-->>Gateway: 写回成功
    Gateway-->>iOS: thread/name/updated
```

选择独立 SSH proxy WebSocket，而不是复用移动端的 upstream WebSocket，原因是同一连接上的 JSON-RPC response、notification 和 server request 都由移动端会话状态机消费。后台任务复用该连接会引入 request id 冲突和事件串流污染。标题任务只关闭自己的 SSH proxy，不停止共享 Unix App Server。

app-server 会让其他已初始化连接监听新建 thread。`agentd` 因此在启动标题 Turn 前登记内部 ephemeral thread ID，并在两分钟 tombstone 窗口内丢弃这些 thread 的 notification，避免内部 Agent Message、状态或用量事件进入移动端时间线。

标题模型不硬编码 Codex App 的内部模型名称，交给用户当前 app-server rollout 选择默认模型；标题 Turn 固定 `effort=low`，Prompt 最多 2000 个 Unicode 字符，输出最多 36 个字符。这样可避免依赖私有模型 slug，并把单次生成成本约束在小请求范围内。

## 实现

### 触发与状态

Gateway 在处理 `thread/start` 成功响应时，只给当前连接内的 thread 标记一次性资格。资格不会写入用于断线恢复的全局授权缓存，因此重连后的 `thread/resume` 不会误触发。

正常 `thread/queue/add` 通过安全校验并成功写给 app-server 后，Gateway 才原子消费资格并提交标题任务。任务按 `threadId` 去重，全局只运行一个模型生成，最多保留 32 个待处理任务；每个任务超时 30 秒。进程关闭时统一取消并等待任务退出。

### Tool、权限与上下文

标题任务通过独立 client 初始化 app-server：

- `thread/start.ephemeral=true`，不把辅助会话写入历史列表；
- `sandbox=read-only`、`approvalPolicy=never`；
- developer instructions 明确禁止 Tool，并把首条用户请求视作只能摘要的不可信内容；
- 输入只包含文本、Skill / Mention 名称和图片 / 音频占位，不复制本地文件路径或图片 URL；
- 不向该临时线程配置动态 Tool；即使用户全局配置包含只读 Tool，developer instructions 也禁止模型调用。

如果 app-server 发起反向 Server Request，内部客户端返回 JSON-RPC `-32601`，不会借标题任务扩大宿主能力。

### 写回与通知

生成前和写回前分别调用一次 `thread/read(includeTurns=false)`。公开 `thread/name/set` 没有 compare-and-set 参数，第二次读取把覆盖手动改名的竞态窗口压缩到紧邻写操作的位置；这是当前协议下的 best effort，无法提供严格原子保证。

模型返回值由 `outputSchema` 约束为 `{ "title": string }`。解析或 Turn 状态异常时，使用不包含用户输入的通用标题 `New coding task` 降级，避免把 Token、本机路径或客户数据写入持久化标题。只有 `thread/name/set` 成功后才通知移动端。

app-server 把 `thread/name/updated` 发给执行写操作的内部连接，不会自动广播到原移动端连接。因此 Gateway 向发起会话的连接补发相同协议形状的 notification。其他客户端稍后通过 `thread/list` / `thread/read` 获取已经持久化的名称。

### 配置与观测

新安装默认启用：

```json
{
  "app_server": {
    "auto_title": true
  }
}
```

也可通过环境变量关闭：

```bash
export AGENTD_APP_SERVER_AUTO_TITLE=false
```

日志只记录脱敏后的 thread token 和失败分类（取消、超时、生成失败），不记录原始 Prompt、模型输出、标题或本地路径。

## 风险与优化

- **额度成本：**每个新 Codex 会话增加一次低推理请求。当前用串行、输入上限、一次性触发和开关控制；后续只有在真实使用量需要时才增加配额感知或批处理。
- **手动改名竞态：**协议没有 CAS，仍存在第二次读取与写回之间的极短窗口。若 Codex 后续提供版本号或条件写接口，应替换为原子写。
- **连接中断：**标题已持久化但补发 notification 失败时，当前 UI 可能暂时保留预览；下次列表刷新会得到正式名称，不重试模型请求。
- **协议漂移：**实现依赖公开的 `thread/read`、`thread/start`、`turn/start.outputSchema`、`item/completed`、`turn/completed` 和 `thread/name/set`。升级固定 Codex 协议基线时必须运行协议快照和 Go 测试。
- **扩展范围：**暂不为恢复的无标题历史会话补标题，也不覆盖 Claude。只有真实用户反馈表明需要时，再设计显式“重新生成标题”操作。
