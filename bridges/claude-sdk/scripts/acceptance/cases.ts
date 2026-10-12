// 验收用例：对照 #655 的验收清单，经网关（iPhone 的路径）逐项检查。每个用例只发很短的 Haiku 请求。
import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { getSessionInfo, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";
import { GatewayClient, httpJson, textInput, type AgentdConfig, type Frame } from "./gateway.ts";
import { claudeConfigDir, claudePrint, forkPoints, Terminal, type Sandbox } from "./sandbox.ts";

export type Status = "pass" | "fail" | "skip";

export interface CaseOutcome {
  status: Status;
  detail: string;
}

export interface Context {
  config: AgentdConfig;
  sandbox: Sandbox;
  claudeBin: string;
  client: GatewayClient;
  terminal: Terminal;
  /** 本次创建的会话，最后做历史对照。 */
  created: Array<{ id: string; label: string }>;
  /** 会话 → cwd：iPhone 发消息时总会带上会话的 cwd，网关据此授权。 */
  cwdOf: Map<string, string>;
  parityRepo: string | undefined;
  parityLimit: number;
}

const pass = (detail: string): CaseOutcome => ({ status: "pass", detail });
const skip = (detail: string): CaseOutcome => ({ status: "skip", detail });
const fail = (detail: string): CaseOutcome => ({ status: "fail", detail });
const LONG_COUNT = "Count from 1 to 400, one number per line, with no other text.";

async function startThread(ctx: Context, cwd: string, label: string): Promise<string> {
  const started = await ctx.client.call("thread/start", { cwd, model: "haiku", approvalPolicy: "on-request", sandbox: "workspace-write" });
  if (started.error) throw new Error(`thread/start 失败：${started.error.message}`);
  const id = started.result.thread.id as string;
  ctx.created.push({ id, label });
  ctx.cwdOf.set(id, cwd);
  return id;
}

async function startTurn(ctx: Context, threadId: string, text: string): Promise<string> {
  const response = await ctx.client.call("turn/start", { threadId, cwd: ctx.cwdOf.get(threadId), input: textInput(text) });
  if (response.error) throw new Error(`turn/start 失败：${response.error.message}（${response.error.data?.reason ?? "无原因"}）`);
  return response.result.turn.id as string;
}

const completedFrame = (turnId: string) => (frame: Frame) => frame.method === "turn/completed" && frame.params?.turn?.id === turnId;

function agentText(ctx: Context, turnId: string): string {
  return ctx.client.frames
    .filter((frame) => frame.method === "item/completed" && frame.params?.turnId === turnId && frame.params?.item?.type === "agentMessage")
    .map((frame) => String(frame.params.item.text ?? ""))
    .join("\n");
}

async function runTurn(ctx: Context, threadId: string, text: string, timeoutMs = 180_000) {
  const started = Date.now();
  const turnId = await startTurn(ctx, threadId, text);
  const completed = await ctx.client.waitFor(completedFrame(turnId), timeoutMs, `turn/completed（${text.slice(0, 30)}）`);
  return { turnId, status: completed.params.turn.status as string, text: agentText(ctx, turnId), ms: Date.now() - started };
}

export async function channelCase(ctx: Context): Promise<CaseOutcome> {
  const config = await httpJson(ctx.config, "/api/app-server/config");
  const claude = (config.channels ?? []).find((channel: any) => channel.id === "claude");
  if (!claude) return fail("网关没有 Claude 通道");
  const bridge = claude.bridge ?? {};
  const summary = `${bridge.name} ${bridge.version}，healthy=${bridge.healthy}`;
  if (!bridge.healthy) return fail(`bridge 不健康：${summary}`);
  if (bridge.name !== "mimi-claude-adapter") return fail(`仍在使用旧 bridge：${summary}`);
  const required = ["thread/takeover", "model/list", "account/rateLimits/read", "thread/items/list"];
  const missing = required.filter((method) => !(claude.methods ?? []).includes(method));
  if (missing.length) return fail(`通道缺少方法：${missing.join("、")}`);
  return pass(`${summary}，开放 ${claude.methods.length} 个方法`);
}

export async function modelsCase(ctx: Context): Promise<CaseOutcome> {
  const models = await ctx.client.call("model/list", {});
  if (models.error) return fail(`model/list 失败：${models.error.message}`);
  const data = models.result.data as Array<{ id: string; hidden: boolean; isDefault: boolean }>;
  const visible = data.filter((model) => !model.hidden).map((model) => model.id);
  const defaults = data.filter((model) => model.isDefault).map((model) => model.id);
  if (!visible.length || defaults.length !== 1) return fail(`可见 ${visible.join("、") || "无"}，默认 ${defaults.join("、") || "无"}`);
  return pass(`可见模型 ${visible.join("、")}，默认 ${defaults[0]}`);
}

/**
 * 额度只来自 Claude Code 在会话里上报的事件（#660，不读登录凭据）：放在第一轮对话之后检查，
 * 应能读到 5 小时或 7 天窗口。
 */
export async function quotaCase(ctx: Context): Promise<CaseOutcome> {
  const limits = await ctx.client.call("account/rateLimits/read", {});
  if (limits.error) return fail(`account/rateLimits/read 失败：${limits.error.message}`);
  const snapshot = limits.result.rateLimits ?? {};
  const percent = (window: any) => (window ? `${window.usedPercent}%` : "—");
  const quota = `5 小时 ${percent(snapshot.primary)}、7 天 ${percent(snapshot.secondary)}（${snapshot.availability ?? "未知"}）`;
  if (!snapshot.primary && !snapshot.secondary) return fail(`跑过一轮对话后仍没有额度：${quota}`);
  return pass(`额度 ${quota}`);
}

export async function basicTurnCase(ctx: Context): Promise<CaseOutcome & { threadId?: string }> {
  const threadId = await startThread(ctx, ctx.sandbox.root, "仓库根目录");
  const turn = await runTurn(ctx, threadId, "Reply with exactly: ACCEPT-OK");
  const streamed = ctx.client.frames.some((frame) => frame.method === "item/agentMessage/delta" && frame.params?.turnId === turn.turnId);
  if (turn.status !== "completed" || !turn.text.includes("ACCEPT-OK")) {
    return { ...fail(`状态 ${turn.status}，回复 ${JSON.stringify(turn.text.slice(0, 80))}`), threadId };
  }
  if (!streamed) return { ...fail(`${turn.ms} ms 完成，但没有收到 item/agentMessage/delta 流式增量`), threadId };
  return { ...pass(`${turn.ms} ms 完成，有流式输出`), threadId };
}

export async function autoTitleCase(ctx: Context, threadId: string | undefined): Promise<CaseOutcome> {
  if (!threadId) return skip("前一个用例没有建出会话");
  // 标题来自 Claude Code 自己生成的 AI 标题，或 agentd 用 Codex 生成后写回；两种都应很快推送到客户端。
  const updated = await ctx.client
    .waitFor((frame) => frame.method === "thread/name/updated" && frame.params?.threadId === threadId, 60_000, "thread/name/updated")
    .catch(() => undefined);
  if (!updated) {
    const info = await getSessionInfo(threadId);
    if (info?.customTitle) return fail(`60 秒内没有收到标题推送；transcript 里已有标题「${info.customTitle}」，iPhone 要等刷新才看到`);
    // 两个来源都没出标题：agentd 关了 Codex 时不算 Mimi 的问题。
    if (!ctx.config.codexEnabled) return skip("60 秒内 Claude Code 没有生成标题，agentd 也未启用 Codex 自动标题");
    return fail("60 秒内没有收到标题推送，transcript 里也没有标题");
  }
  const name = String(updated.params.threadName ?? updated.params.name ?? "");
  const read = await ctx.client.call("thread/read", { threadId });
  const info = await getSessionInfo(threadId);
  if (read.result?.thread?.name !== name) return fail(`thread/read 的名字（${read.result?.thread?.name}）与推送（${name}）不一致`);
  if (info?.customTitle !== name) return fail(`CLI 看到的标题（${info?.customTitle}）与 Mimi 不一致`);
  return pass(`标题「${name}」，Mimi 与 CLI 一致`);
}

async function listAll(ctx: Context, cwd: string): Promise<any[]> {
  const threads: any[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 40; page += 1) {
    const response = await ctx.client.call("thread/list", { cwd, limit: 50, sortKey: "updated_at", ...(cursor ? { cursor } : {}) });
    if (response.error) throw new Error(`thread/list 失败：${response.error.message}`);
    threads.push(...response.result.data);
    cursor = response.result.nextCursor ?? undefined;
    if (!cursor) break;
  }
  return threads;
}

export async function worktreeCase(ctx: Context, rootThread: string | undefined): Promise<CaseOutcome> {
  const sibling = await startThread(ctx, ctx.sandbox.sibling, "兄弟 worktree");
  const nested = await startThread(ctx, ctx.sandbox.nested, ".claude/worktrees");
  for (const threadId of [sibling, nested]) {
    const turn = await runTurn(ctx, threadId, "Reply with exactly: WT-OK");
    if (turn.status !== "completed") return fail(`worktree 会话的回合状态 ${turn.status}`);
  }
  // 用户直接在终端（CLI）里建的 worktree 会话也要出现。
  const cli = claudePrint(ctx.claudeBin, ctx.sandbox.nested, "Reply with exactly: CLI-OK");
  ctx.created.push({ id: cli, label: "CLI 在 worktree 里建的会话" });
  const threads = await listAll(ctx, ctx.sandbox.root);
  const byId = new Map(threads.map((thread) => [thread.id, thread]));
  const expected: Array<[string | undefined, string, string]> = [
    [rootThread, ctx.sandbox.root, "main"],
    [sibling, ctx.sandbox.sibling, "acceptance-sibling"],
    [nested, ctx.sandbox.nested, "acceptance-nested"],
    [cli, ctx.sandbox.nested, "acceptance-nested"],
  ];
  const problems: string[] = [];
  for (const [id, cwd, branch] of expected) {
    if (!id) continue;
    const thread = byId.get(id);
    if (!thread) problems.push(`${path.basename(cwd)} 的会话没有列出`);
    else if (thread.cwd !== cwd) problems.push(`${id.slice(0, 8)} 的 cwd 是 ${thread.cwd}`);
    else if (thread.gitInfo?.branch !== branch) problems.push(`${id.slice(0, 8)} 的分支是 ${thread.gitInfo?.branch}`);
  }
  if (problems.length) return fail(problems.join("；"));
  return pass(`仓库下列出 ${threads.length} 个会话，含 2 个 worktree 会话和 1 个 CLI 建的会话，cwd 与分支正确`);
}

export async function steerInterruptCase(ctx: Context): Promise<CaseOutcome> {
  const threadId = await startThread(ctx, ctx.sandbox.root, "引导与中断");
  const turnId = await startTurn(ctx, threadId, LONG_COUNT);
  await ctx.client.waitFor((frame) => frame.method === "item/agentMessage/delta" && frame.params?.turnId === turnId, 90_000, "第一段流式输出");
  const steered = await ctx.client.call("turn/steer", {
    threadId,
    expectedTurnId: turnId,
    input: textInput("Stop counting now and reply with exactly: STEERED"),
    clientUserMessageId: "acceptance-steer",
  });
  if (steered.error) return fail(`turn/steer 失败：${steered.error.message}`);
  const completed = await ctx.client.waitFor(completedFrame(turnId), 180_000, "引导后的 turn/completed");
  const completions = ctx.client.frames.filter(completedFrame(turnId)).length;
  const text = agentText(ctx, turnId);
  if (completed.params.turn.status !== "completed" || !text.includes("STEERED") || completions !== 1) {
    return fail(`引导：状态 ${completed.params.turn.status}，收尾 ${completions} 次，回复含 STEERED=${text.includes("STEERED")}`);
  }
  const interruptedTurn = await startTurn(ctx, threadId, LONG_COUNT);
  await ctx.client.waitFor((frame) => frame.method === "item/agentMessage/delta" && frame.params?.turnId === interruptedTurn, 90_000, "第二段流式输出");
  const interrupted = await ctx.client.call("turn/interrupt", { threadId, turnId: interruptedTurn });
  if (interrupted.error) return fail(`turn/interrupt 失败：${interrupted.error.message}`);
  const done = await ctx.client.waitFor(completedFrame(interruptedTurn), 60_000, "中断后的 turn/completed");
  if (done.params.turn.status !== "interrupted") return fail(`中断后状态是 ${done.params.turn.status}`);
  return pass("引导并入同一回合并按引导回复；中断后回合状态为 interrupted");
}

async function approvalRound(ctx: Context, threadId: string, file: string, decision: "accept" | "decline") {
  const turnId = await startTurn(ctx, threadId, `Use the Bash tool to run exactly this command and nothing else: touch ${file}`);
  const request = await Promise.race([
    ctx.client.waitFor((frame) => frame.method === "item/commandExecution/requestApproval" && frame.params?.turnId === turnId, 120_000, "命令审批请求"),
    ctx.client.waitFor(completedFrame(turnId), 120_000, "turn/completed").then(() => undefined),
  ]);
  if (!request) return { asked: false, status: "completed", exists: existsSync(path.join(ctx.sandbox.root, file)) };
  ctx.client.respond(request.id, { decision });
  const completed = await ctx.client.waitFor(completedFrame(turnId), 120_000, "审批后的 turn/completed");
  return { asked: true, status: completed.params.turn.status as string, exists: existsSync(path.join(ctx.sandbox.root, file)) };
}

export async function approvalCase(ctx: Context): Promise<CaseOutcome> {
  const threadId = await startThread(ctx, ctx.sandbox.root, "命令审批");
  const accepted = await approvalRound(ctx, threadId, "acceptance-approved.txt", "accept");
  if (!accepted.asked) return skip("Claude 没有请求权限（可能被设置里的允许规则放行，或没有调用工具），无法判断");
  const declined = await approvalRound(ctx, threadId, "acceptance-declined.txt", "decline");
  if (!declined.asked) return skip("第二次没有请求权限，无法判断拒绝");
  if (!accepted.exists || accepted.status !== "completed") return fail(`允许后命令没有执行（状态 ${accepted.status}）`);
  if (declined.exists) return fail("拒绝后命令仍然执行了");
  return pass("允许后命令执行；拒绝后命令未执行，回合正常收尾");
}

export async function askUserCase(ctx: Context): Promise<CaseOutcome> {
  const threadId = await startThread(ctx, ctx.sandbox.root, "Claude 提问");
  const turnId = await startTurn(
    ctx,
    threadId,
    "Use the AskUserQuestion tool to ask me exactly one question, 'Tea or Coffee?', with the two options Tea and Coffee. After I answer, reply with exactly: PICKED followed by my answer.",
  );
  const request = await Promise.race([
    ctx.client.waitFor((frame) => frame.method === "item/tool/requestUserInput" && frame.params?.threadId === threadId, 120_000, "提问请求"),
    ctx.client.waitFor(completedFrame(turnId), 120_000, "turn/completed").then(() => undefined),
  ]);
  if (!request) return skip("Claude 没有调用提问工具，无法判断");
  ctx.client.respond(request.id, { answers: { "question-0": { answers: ["Tea"] } } });
  const completed = await ctx.client.waitFor(completedFrame(turnId), 120_000, "回答后的 turn/completed");
  const text = agentText(ctx, turnId);
  if (completed.params.turn.status !== "completed" || !text.includes("PICKED Tea")) {
    return fail(`状态 ${completed.params.turn.status}，回复 ${JSON.stringify(text.slice(0, 80))}`);
  }
  return pass("提问送达，答案回传给 Claude 并据此回复");
}

/** 失败时的现场：终端屏幕最后几行、占用登记里这个会话的持有方。 */
function terminalEvidence(ctx: Context, threadId: string): string {
  const pane = ctx.terminal.pane().split("\n").map((line) => line.trim()).filter(Boolean).slice(-4).join(" | ");
  const sessions = path.join(claudeConfigDir(), "sessions");
  const holders: string[] = [];
  for (const name of existsSync(sessions) ? readdirSync(sessions) : []) {
    try {
      const record = JSON.parse(readFileSync(path.join(sessions, name), "utf8"));
      if (record.sessionId === threadId) holders.push(`pid ${record.pid} ${record.entrypoint ?? "?"} ${record.status ?? "?"}`);
    } catch {
      // 跳过。
    }
  }
  return `终端（${ctx.terminal.alive() ? "运行中" : "已退出"}）：${pane.slice(0, 400)}；登记：${holders.join("、") || "没有该会话的持有方"}`;
}

const ownership = (threadId: string, writable: boolean, after: number) => (frame: Frame) =>
  frame.at >= after && frame.method === "thread/status/changed" && frame.params?.threadId === threadId && frame.params?.canAcceptDirectInput === writable;

export async function yieldTakeoverCase(ctx: Context): Promise<CaseOutcome> {
  const threadId = await startThread(ctx, ctx.sandbox.root, "让出与接管");
  const ready = await runTurn(ctx, threadId, "Reply with exactly: READY");
  if (ready.status !== "completed") return fail(`准备回合状态 ${ready.status}`);
  const steps: string[] = [];

  // 1. Mimi 驱动中，终端 claude --resume 接手：Mimi 让出并推送只读。
  const turnId = await startTurn(ctx, threadId, LONG_COUNT);
  await ctx.client.waitFor((frame) => frame.method === "item/agentMessage/delta" && frame.params?.turnId === turnId, 90_000, "流式输出");
  const launched = Date.now();
  ctx.terminal.start(ctx.sandbox.root, ["--model", "haiku", "--resume", threadId]);
  if (!(await ctx.terminal.waitUntilReady())) return fail(`终端里的 claude 没有就绪；${terminalEvidence(ctx, threadId)}`);
  const readOnly = await ctx.client.waitFor(ownership(threadId, false, launched), 30_000, "只读推送").catch((error) => {
    throw new Error(`${error instanceof Error ? error.message : String(error)}；${terminalEvidence(ctx, threadId)}`);
  });
  const interrupted = await ctx.client.waitFor(completedFrame(turnId), 30_000, "让出后的 turn/completed");
  steps.push(`终端接手后 ${readOnly.at - launched} ms 变只读，回合 ${interrupted.params.turn.status}`);
  if (interrupted.params.turn.status !== "interrupted") return fail(steps.join("；"));
  const refused = await ctx.client.call("turn/start", { threadId, cwd: ctx.cwdOf.get(threadId), input: textInput("hello") });
  if (refused.error?.data?.reason !== "owned_elsewhere") return fail(`被占用时 turn/start 应返回 owned_elsewhere，实际 ${JSON.stringify(refused.error ?? refused.result).slice(0, 120)}`);

  // 2. 终端退出：恢复可写。
  const exited = Date.now();
  await ctx.terminal.exit();
  await ctx.client.waitFor(ownership(threadId, true, exited), 30_000, "恢复可写推送");
  steps.push("终端退出后恢复可写");

  // 3. 终端空闲持有：接管后在 Mimi 续聊。
  const relaunched = Date.now();
  ctx.terminal.start(ctx.sandbox.root, ["--model", "haiku", "--resume", threadId]);
  if (!(await ctx.terminal.waitUntilReady())) return fail(`终端里的 claude 没有就绪；${terminalEvidence(ctx, threadId)}`);
  await ctx.client.waitFor(
    (frame) => ownership(threadId, false, relaunched)(frame) && frame.params?.claudeOwner?.status === "idle",
    45_000,
    "空闲持有推送",
  );
  // 与 iPhone 的接管请求相同：会话 ID、cwd，不带历史。
  const takeover = await ctx.client.call("thread/takeover", { threadId, cwd: ctx.cwdOf.get(threadId), excludeTurns: true });
  if (takeover.error) return fail(`接管失败：${takeover.error.data?.reason ?? takeover.error.message}`);
  if (!takeover.result.takeover?.released) return fail("接管没有结束终端里的持有方");
  await Bun.sleep(1_000);
  if (ctx.terminal.alive()) return fail("接管后终端里的 claude 仍在运行");
  const back = await runTurn(ctx, threadId, "Reply with exactly: BACK-OK");
  if (back.status !== "completed" || !back.text.includes("BACK-OK")) return fail(`接管后续聊状态 ${back.status}`);
  steps.push(`接管（${takeover.result.takeover.signal}）后续聊正常`);
  // 单一驱动方：两个进程同时写同一个会话会让 transcript 分叉，历史从此分岔。
  const transcript = forkPoints(threadId);
  if (!transcript) return fail(`${steps.join("；")}；找不到 transcript，无法检查分叉`);
  if (transcript.forks) return fail(`${steps.join("；")}；transcript 有 ${transcript.forks} 个分叉点，两个进程同时写过这个会话`);
  steps.push(transcript.synthetic ? `transcript 无分叉（CLI 恢复被结束的回合时补写了 ${transcript.synthetic} 条合成回复）` : "transcript 无分叉");
  return pass(steps.join("；"));
}

/** CLI（`claude --resume`）的视图：SDK 读出的主链里的提问与回复文本。 */
async function cliView(sessionId: string): Promise<{ prompts: string[]; replies: string[] }> {
  const prompts: string[] = [];
  const replies: string[] = [];
  for (const message of (await getSessionMessages(sessionId)) as any[]) {
    const content = message.message?.content;
    const blocks = typeof content === "string" ? [{ type: "text", text: content }] : Array.isArray(content) ? content : [];
    const text = blocks.filter((block: any) => block.type === "text").map((block: any) => String(block.text)).join("\n").trim();
    if (!text) continue;
    if (message.type === "assistant") {
      replies.push(text);
    } else if (message.type === "user" && !message.isCompactSummary && !message.isMeta) {
      // 斜杠命令在 CLI 里显示为「/命令 参数」；命令输出、后台任务通知、中断标记不算提问。
      const command = /^<command-name>([^<]*)<\/command-name>/.exec(text);
      if (command) {
        const args = /<command-args>([^<]*)<\/command-args>/.exec(text)?.[1]?.trim();
        prompts.push(args ? `${command[1]} ${args}` : command[1]!);
      } else if (!/^(<local-command|<task-notification|\[Request interrupted)/.test(text)) {
        prompts.push(text);
      }
    }
  }
  return { prompts, replies };
}

/**
 * 网关对完整历史有全局下行预算（与 iPhone 共用）。被限流时按它给的 retryAfterMs 等一等再取，
 * 不连续猛拉，免得挤占手机加载历史。
 */
async function historyPage(ctx: Context, threadId: string, cursor: string | undefined) {
  for (let attempt = 0; attempt < 6; attempt += 1) {
    const response = await ctx.client.call("thread/turns/list", {
      threadId,
      limit: 20,
      sortDirection: "asc",
      itemsView: "full",
      ...(cursor ? { cursor } : {}),
    });
    if (!response.error) return response;
    const retryAfterMs = Number(response.error.data?.retryAfterMs);
    if (!Number.isFinite(retryAfterMs) || retryAfterMs <= 0) throw new Error(`thread/turns/list 失败：${response.error.message}`);
    await Bun.sleep(retryAfterMs + 250);
  }
  throw new Error("thread/turns/list 持续被历史下行预算限流");
}

/** Mimi 的视图：经网关分页读出的全部回合里的提问与回复。 */
async function mimiView(ctx: Context, threadId: string): Promise<{ prompts: string[]; replies: string[] }> {
  const prompts: string[] = [];
  const replies: string[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 200; page += 1) {
    const response = await historyPage(ctx, threadId, cursor);
    for (const turn of response.result.data) {
      for (const item of turn.items) {
        if (item.type === "userMessage") {
          const text = (item.content ?? []).filter((part: any) => part.type === "text").map((part: any) => String(part.text)).join("\n").trim();
          if (text) prompts.push(text);
        } else if (item.type === "agentMessage" && String(item.text ?? "").trim()) {
          replies.push(String(item.text).trim());
        }
      }
    }
    cursor = response.result.nextCursor ?? undefined;
    if (!cursor) break;
  }
  return { prompts, replies };
}

/** 整个序列拼成一段再统一空白：Mimi 会把一条回复里的多个文本块拆成多个 item，内容与顺序不变。 */
const flatten = (texts: string[]) => texts.join(" ").replace(/\s+/g, " ").trim();

function compareViews(cli: { prompts: string[]; replies: string[] }, mimi: { prompts: string[]; replies: string[] }): string | undefined {
  for (const kind of ["prompts", "replies"] as const) {
    const expected = flatten(cli[kind]);
    const actual = flatten(mimi[kind]);
    if (expected !== actual) {
      let at = 0;
      while (at < expected.length && expected[at] === actual[at]) at += 1;
      // 只报告位置与条数，不把会话内容写进报告。
      return `${kind === "prompts" ? "提问" : "回复"}不一致：CLI ${cli[kind].length} 条（${expected.length} 字）、Mimi ${mimi[kind].length} 条（${actual.length} 字），从第 ${at + 1} 个字开始不同`;
    }
  }
  return undefined;
}

export async function parityCase(ctx: Context): Promise<CaseOutcome> {
  const problems: string[] = [];
  let checked = 0;
  const targets = [...ctx.created];
  if (ctx.parityRepo) {
    const recent = (await listAll(ctx, ctx.parityRepo)).slice(0, ctx.parityLimit);
    targets.push(...recent.map((thread) => ({ id: thread.id as string, label: `已有会话 ${String(thread.id).slice(0, 8)}` })));
  }
  for (const target of targets) {
    const [cli, mimi] = await Promise.all([cliView(target.id), mimiView(ctx, target.id)]);
    const difference = compareViews(cli, mimi);
    checked += 1;
    if (difference) problems.push(`${target.label}（${target.id.slice(0, 8)}）：${difference}`);
  }
  if (problems.length) return fail(problems.join("；"));
  return pass(`${checked} 个会话的提问与回复，Mimi 与 CLI 视图完全一致`);
}
