# 工作区会话列表支持「全部运行时」Phase 0：现网采样与性能基线报告

> **范围界定**：本报告与同 PR 交付物严格限定为脱敏现网/协议采样、可复跑性能基准脚本与基线数据，**不修改任何产品代码行为**。未来契约夹具（如 `pageDisposition: "same_page_retry"`、4 状态 `listMeta` 等）按评审关闭清单在方案 P1 修订定稿后随后续阶段提交。

## 1. 基线提交与组件版本

| 维度 | 基线值 |
|---|---|
| 基线提交 | `2c6342fb`（`origin/main`） |
| 宿主机环境（脱敏） | Apple M5 Pro（18 核，48 GiB 内存），macOS 27.3（arm64），本机空闲态无并行构建 |
| Go 工具链 | `go1.25.14 darwin/arm64` |
| Bun 运行时 | `1.2.22` |
| Node 运行时 | `v24.22.3` |
| Rust / Cargo | `cargo 1.100.0` |
| Codex CLI | `codex-cli 0.171.0`（仓库协议快照 `0.162.0`） |
| Claude SDK 适配器 | `mimi-claude-adapter/0.3.0`（`@anthropic-ai/claude-agent-sdk@0.3.296`） |
| Claude Legacy Rust 桥接 | `alleycat-claude-bridge/0.2.15` |
| Antigravity ACP 适配器 | `mimi-agy-adapter/0.1.0` |
| DeepSeek Harness 快照 | `@deepseek-ai/dsh@0.1.5-rc.2`（`harness_native_v1`） |

## 2. 脱敏采样覆盖与观察结论

所有脱敏采样与畸形拒绝样本均存放在 `scripts/testdata/all-runtimes-phase0/`，路径统一脱敏为 `/Users/demo/...`，不含任何真实用户名、本机路径、Token、私钥、Tailscale 地址或真实用户会话内容。

| 分组 | 夹具文件 | 来源属性 | 核心观察（`2c6342fb`） |
|---|---|---|---|
| `accepted` | `accepted/gateway-global-unmarked-same-page-retry.json` | 现网契约录制 | Go 网关 Controlled Global 在 browse-root Git 归属判定超过 300ms 时，裁剪未判定工作树行并返回无 `listMeta`、无 `pageDisposition` 的不透明 `mimi_*` 重试游标；次轮延续同一游标重试补出更晚条目（`1775815600 > 1775815200`）；且 `copyGatewayRawFields` 当前裁剪 `cliVersion` |
| `accepted` | `accepted/claude-sdk-empty-cwd.json` | 现网实跑抓包 | `mimi-claude-adapter/0.3.0` 合法输出 `cwd: ""` 与正常行同页，时间戳为 Unix 秒（`< 1e10`），`recencyAt: null`；同页实测包含一对相同秒级 `updatedAt: 1775815202` 会话，按 `id DESC`（`22222222-...` 先于 `11111111-...`）排序 |
| `accepted` | `accepted/claude-legacy-rust-ms.json` | 现网实跑抓包 | `alleycat-claude-bridge/0.2.15` 输出真实 Unix 毫秒时间戳（`>= 1e10`），同毫秒降序按 `thread_id ASC` 跨页切分，游标为无填充 base64url `{"ts":<ms>,"id":<id>}`，响应省略 `recencyAt` |
| `accepted` | `accepted/codex-recency-at-null.json` | 混合（实跑 + Schema 派生） | `codex-cli 0.171.0` 实跑抓包（`exchanges[1]`）确认 `createdAt`/`updatedAt` 为 Unix 秒且 `sortKey: "recency_at"` 下未回填 `state_5.sqlite` 行返回 `recencyAt: 0`；`exchanges[0]` 的 `recencyAt: null` 为基于实测 wire 形态与协议 Schema（`v2/ThreadListResponse.json` 声明 `recencyAt: int64 \| null`）构造的 **Schema 派生（schema-derived）用例**，而非本次实跑直接抓到的实时 `null` 响应 |
| `accepted` | `accepted/agy-acp-current-list.json` | 现网实跑抓包 | `mimi-agy-adapter/0.1.0` 当前响应不含 `listMeta`，时间戳为 Unix 秒、`recencyAt: null`，通过 `source: "cli"` 与 `{"custom":"other"}` 区分来源，缺失目录标记 `cwdMissing: true`、`canAcceptDirectInput: false` |
| `accepted` | `accepted/deepseek-harness-session-list.json` | 源实录经网关裁剪重编码 | 基于现网实录 `contracts/harness-native/fixtures/rpc/session-list.json`（同 cwd 共 8 条上游记录：丢弃 5 条 `blank: true`，完整保留全部 3 条 `blank: false` 行）按 `agentd` `harnessNativeListValue` / `harnessclient.SessionSummary` 裁剪与重编码，仅输出建模投影键（`title`、`turnOutline`、`modelSelection`，不含 `goal`），无服务端分页游标，按 `updatedAt` 毫秒稳定降序 |
| `malformed` | `malformed/*.json`（5 项） | 畸形拒绝样本 | 覆盖缺 `nextCursor` 键、非数组 `data`、空白线程 ID、非字符串 `cwd`、同页混用秒与毫秒时间戳，供校验脚本 100% 显式拒绝 |

校验命令：

```bash
bash ./scripts/test-all-runtimes-phase0-samples.sh
```

校验结果：`accepted=6/6`、`malformed_rejected=5/5`、`coverage=6/6`、`sanitization=clean`（在 `PYTHONOPTIMIZE=1` 下同样严格生效）。

## 3. 可复跑性能基准与复现命令

### 3.1 统一复现命令

```bash
bash ./scripts/bench-all-runtimes-phase0.sh --seed 20260410 --batches 3 --cold 5 --warm 20
```

- 入口脚本：`scripts/bench-all-runtimes-phase0.sh`
- 隔离性：两个基准脚本在夹具初始化与全部计时调用前均清空宿主 `GIT_*` 仓库变量并禁用全局/系统 Git 配置，退出时恢复，不污染外部仓库。
- Antigravity 基准：`scripts/bench-agy-acp-list.ts`（通过临时 `PATH` 静态 `git` 包装器按环境变量传递路径计数 OS 级 `git` spawn，计数读写失败即报错中止；进程扫描在「Phase 0 未计量，留待后续 issue」，不在计时路径中插入 `ps` 包装器或其临时文件/辅助进程，Phase 1 对比不依赖进程扫描；运行生产 `createAcpSessionBackend` + `SharedReadonlyAcp` + `AcpClient` + `AgyCatalog` + `GitRepoIndex` + `createThreadHandlers` 完整链路，底层使用受控内存 ACP 传输 `FakeAgyWorld` 隔离上游 `agy` 守护进程 SQLite/RPC I/O）
- Claude SDK 基准：`scripts/bench-claude-sdk-list.ts`（在隔离临时 `CLAUDE_CONFIG_DIR` 运行真实 `@anthropic-ai/claude-agent-sdk` `listSessions`、`TranscriptIndex`、`ActivityClock`、`WorkingDirectories`、`Overlay`、`Catalog` 与 `createThreadHandlers`，并在计时循环外全量翻页校验完整目标会话集含全部 worktree）

### 3.2 Antigravity（`bridges/agy-acp`）基线数据

**度量边界**：本节实测的是 `bridges/agy-acp` 适配器侧完整生产链路（`createAcpSessionBackend` 含 `hasOtherConversations`、`diskRevision`、`resolveSessionOrigin`、`inspectExternalActivity`、双 `SharedReadonlyAcp` JSON-RPC `session/list` 收发与合并 + `AgyCatalog` + `GitRepoIndex` + `createThreadHandlers`），通过受控内存 ACP 传输排除外部 `agy` 守护进程自身 I/O 抖动。**进程扫描（`ps`）**：Phase 0 未计量，留待后续 issue；基准脚本不在计时路径中插入 `ps` 包装器及其临时文件/辅助进程，Phase 1 对比不依赖进程扫描。下文 Phase 1 的性能目标仅针对该已度量适配器链路。

**固定种子数据集（`seed=20260410`）**：500 条全局会话摘要（30 条目标仓会话分布于主仓、2 个 worktree、symlink 与 `file://` 百分号编码路径；360 条其他 12 个 Git 仓及 6 个 worktree 会话；50 条非 Git 目录会话含编码 URI；30 条缺失目录会话；30 条无 `.db` 孤儿会话）。计时循环外全量翻页已验证精确返回全部 30 条目标会话（无遗漏、无重复、无越界）。非孤儿唯一原始 `cwd` 为 `33` 个，经 `normalizeNativeCwd` 规范化后参与 `git.inspect` 的唯一目录为 `32` 个（其中磁盘存在 `28` 个 + 缺失目录 `4` 个在 `matchesAnyRoot` 中仍触发 `git.inspect`）。

**执行方式**：连续 3 批，每批先跑 5 次并发冷查（每次新建 `SharedReadonlyAcp`/`GitRepoIndex`/`AgyCatalog`，4 路并发触发目标仓 `thread/list`），再预热常驻 ACP 连接与 30s Git 缓存后顺序跑 20 次目标仓 `thread/list`。

| 批次 | 并发冷查（x4, n=5）`git` spawn / 轮 | 并发冷查 ACP `session/list` RPC / 轮 | 并发冷查 p50 (ms) | 并发冷查 p95 (ms) | 顺序热态（n=20）`git` spawn 绝对次数 | 顺序热态 ACP RPC 增量 | 顺序热态 p50 (ms) | 顺序热态 p95 (ms) | 顺序热态 max (ms) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Batch 1 | `128`（5 轮共 `640`） | `5`（4 CLI + 1 Other） | 977.447 | 1159.785 | `0` | `2`（1 CLI + 1 Other） | 40.061 | 194.893 | 198.413 |
| Batch 2 | `128`（5 轮共 `640`） | `5`（4 CLI + 1 Other） | 1092.242 | 1112.648 | `0` | `2`（1 CLI + 1 Other） | 39.594 | 195.312 | 196.174 |
| Batch 3 | `128`（5 轮共 `640`） | `5`（4 CLI + 1 Other） | 971.532 | 1114.897 | `0` | `2`（1 CLI + 1 Other） | 38.760 | 189.995 | 206.802 |
| **3 批汇总** | **均值 `128` / 轮（总 `1920`）** | **均值 `5` / 轮** | **均值 1013.740** | **均值 1129.110（波动 4.24%）** | **绝对 `0`（60 次共 `0`）** | **总 `6`（每批 `2`）** | **均值 39.472** | **均值 193.400（波动 2.80%）** | **max 206.802** |

**基线洞察（对应 Phase 1 适配器侧门禁）**：
1. **并发冷查放大效应明确**：`GitRepoIndex` 缺少在途合并（`inflight` Map），4 路并发冷查对 32 个唯一规范化目录产生精确 `4 × 32 = 128` 次真实 `git` spawn；同时 `cliSharedAcp` 的 `session/list` 无并发合并，4 路冷查发出 `4` 次 CLI RPC + `1` 次经 `otherQueryInFlight` 合并的 Other RPC（共 `5` 次）。Phase 1 引入 `inflight` 合并与先筛选唯一 `cwd` 后，目标为单轮 `git` spawn `<=` 唯一候选 `cwd` 数且降幅 `>= 50%`。
2. **顺序热态缓存与生产残留瓶颈分离清晰**：在 30s Git TTL 内，顺序热态的 `git` spawn 绝对次数保持 `0`；但接入生产 `createAcpSessionBackend` 后，顺序热态中位耗时为 `39.472ms`、p95 达 `193.400ms`（批间波动 `2.80% <= 15%`），且每 20 次顺序查询因总耗时越过 `1.5s` `listCacheMs` 窗口触发 `1` 次 CLI + `1` 次 Other 的 ACP `session/list` 刷新（每批增量 `2` 次）。实测适配器侧主要瓶颈为：① `AgyCatalog.list()` 在按 `dirs` 过滤前对全部 470 条非孤儿会话逐条串行执行 `resolveSessionOrigin`、`diskRevision`（`resolveTranscriptPath` + `.db`/`.db-wal` `stat`）与 `directoryExists`；② `createThreadHandlers.list()` 对返回的 20 条记录逐条调用 `inspectExternalActivity`（每 300ms `PS_CACHE_TTL_MS` 过期触发 `ps` 扫描，形成 ~190ms 长尾尖峰；进程扫描自身成功/降级状态在 Phase 0 未计量，留待后续 issue，Phase 1 对比不依赖进程扫描计量）。Phase 1 在同一生产后端基准口径下，以批量来源索引、先按唯一 `cwd` 裁剪再执行 `diskRevision` 核验适配器侧热态耗时 `>= 30%` 改善。

### 3.3 Claude SDK（`bridges/claude-sdk`）200+ 会话分页基线数据

**固定种子数据集（`seed=20260410`）**：目标 Git 仓（含主仓 `160` 条 + `target-wt-1` `40` 条 + `target-wt-2` `40` 条）共 `240` 条真实合成 JSONL transcript 会话，另含 `40` 条其他项目会话（共 `280` 个 `.jsonl` 文件），每页 `limit = 20`，按 `updated_at DESC` 翻页。计时循环外已全量翻页校验完整返回 `240/240` 条目标会话且三个目录条数精确匹配。

**执行方式**：连续 3 批，每批跑 5 次冷态（新建 `TranscriptIndex`/`ActivityClock`/`WorkingDirectories`/`Overlay`/`Catalog` 后依次读第 1 页与第 2 页）与 20 次热态第 2 页连续读取（3 批共 `n = 60` 次热态样本）。

| 批次 | 冷首屏 p95 (ms) | 冷次页 p95 (ms) | 热态次页 p50 (ms) | 热态次页 p95 (ms) | 热态次页 max (ms) | `prepare` 均值 (ms) | `sessions.list` 均值 (ms) | `toRecord` 均值 (ms) | `filter+sort+cursor` 均值 (ms) | `live+toThread` 均值 (ms) | 目录处理（`sessions.list+toRecord+sort`）均值与占比 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Batch 1 | 28.936 | 22.857 | 22.066 | 22.664 | 23.218 | 0.012 | 21.915 | 0.165 | 0.049 | 0.023 | 22.130ms（**99.78%**） |
| Batch 2 | 29.235 | 24.984 | 21.860 | 22.660 | 22.877 | 0.013 | 21.732 | 0.160 | 0.042 | 0.019 | 21.934ms（**99.79%**） |
| Batch 3 | 27.914 | 22.105 | 21.625 | 22.222 | 23.034 | 0.010 | 21.516 | 0.158 | 0.043 | 0.019 | 21.717ms（**99.81%**） |
| **3 批汇总** | **均值 28.695** | **均值 23.315** | **均值 21.850** | **合并 p95 22.664**（批均值 22.515，波动 1.99%） | **max 23.218** | **0.012** | **21.721** | **0.161** | **0.045** | **0.020** | **21.927ms（合并占比 99.79%）** |

### 3.4 Claude 有序快照缓存阈值结论

按方案 Phase 0 锁定阈值：**合并全部批次热态第 2 页 p95（`n = 60`）`> 30ms` 且合并目录处理耗时占比（`sessions.list + toRecord + sort`）`> 50%`**。

- **合并目录处理耗时占比**：`99.79%`（远超 `50%`，其中 `sessions.list` 自身占总耗时约 `99.0%`）；
- **合并热态第 2 页 p95**：`22.664ms`（批均值 `22.515ms`、批最大值 `22.664ms`，批间波动仅 `1.99%`），**未超过 `30ms` 阈值**；
- **结论**：`triggered = false`。Phase 2 独立交付 O(log N) 二分游标定位即可；条件有序快照缓存与 `ActivityClock` 完整窗口校验保持在独立跟进 Issue 中，不阻塞主链路 Phase 5 交付（若后续超大规模工作区或低速盘场景实测合并热态次页 p95 越过 `30ms`，再按同一基准脚本触发并走 `full` 验证）。
