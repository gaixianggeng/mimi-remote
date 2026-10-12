// 测试用的假 Claude CLI：实现 SDK 依赖的 stream-json 与控制协议（按真实 CLI 的帧录制而来），
// 行为由提示词脚本化。也写 transcript 与占用登记，让历史与持有方检测走真实路径。
//   TOOL <Name> <json>  先请求权限再执行；ASK 走 AskUserQuestion；SLOW 慢速输出，可被中断或引导；
//   THINK 先输出思考；TITLE <名字> 写一条 ai-title 记录；CRASH <名字> 写完 ai-title 不回结果直接退出；
//   其他输入原样回显（带当前模型）。
import { appendFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";
import readline from "node:readline";

type Json = Record<string, any>;

const argv = process.argv.slice(2);
if (argv.includes("--version")) {
  process.stdout.write("2.1.296 (Claude Code)\n");
  process.exit(0);
}
function flag(name: string): string | undefined {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === `--${name}`) return argv[i + 1];
    if (arg.startsWith(`--${name}=`)) return arg.slice(name.length + 3);
  }
  return undefined;
}

const sessionId = flag("session-id") ?? flag("resume") ?? randomUUID();
let model = flag("model") ?? "fake-default";
let permissionMode = flag("permission-mode") ?? "default";
const cwd = process.cwd();
const configDir = process.env.CLAUDE_CONFIG_DIR!;
const transcript = path.join(configDir, "projects", cwd.replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
const registry = path.join(configDir, "sessions", `${process.pid}.json`);
mkdirSync(path.dirname(transcript), { recursive: true });
mkdirSync(path.dirname(registry), { recursive: true });
let lastUuid: string | null = null;

function register(status: string) {
  writeFileSync(registry, JSON.stringify({ pid: process.pid, sessionId, cwd, entrypoint: "sdk-ts", kind: "interactive", status, version: "fake" }));
}
register("idle");
process.on("exit", () => rmSync(registry, { force: true }));

function out(frame: Json) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

function record(type: "user" | "assistant", message: Json, uuid = randomUUID(), extra: Json = {}) {
  const entry = { type, uuid, parentUuid: lastUuid, sessionId, cwd, isSidechain: false, timestamp: new Date().toISOString(), message, ...extra };
  lastUuid = uuid;
  appendFileSync(transcript, `${JSON.stringify(entry)}\n`);
  return uuid;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const pendingControl = new Map<string, (response: Json) => void>();
const queue: Json[] = [];
let wake: (() => void) | undefined;
let nowMessage: Json | undefined;
let interrupted = false;
let busy = false;
/** 当前这一轮回应的用户消息 uuid：真实 CLI 在每轮第一帧输出上标注，结果里列出全部被吸收的消息。 */
let answering: string[] = [];
let stamped = false;

function stream(event: Json) {
  const stamp = !stamped && answering.length ? { user_message_uuid: answering.at(-1) } : {};
  stamped = true;
  out({ type: "stream_event", event, session_id: sessionId, parent_tool_use_id: null, uuid: randomUUID(), ...stamp });
}

/** 一条 API 消息：流式块事件 + 每个内容块一条 assistant 消息（与真实 CLI 相同）。 */
async function apiMessage(blocks: Json[], delayMs = 0): Promise<boolean> {
  const id = `msg_${randomUUID().slice(0, 8)}`;
  stream({ type: "message_start", message: { id, model, role: "assistant", content: [] } });
  for (const [index, block] of blocks.entries()) {
    if (block.type === "text" || block.type === "thinking") {
      const key = block.type === "text" ? "text" : "thinking";
      stream({ type: "content_block_start", index, content_block: { type: block.type, [key]: "" } });
      for (const piece of block[key].match(/.{1,6}/gs) ?? []) {
        if (interrupted) return false;
        stream({ type: "content_block_delta", index, delta: { type: `${key}_delta`, [key]: piece } });
        if (delayMs) await sleep(delayMs);
      }
    } else {
      stream({ type: "content_block_start", index, content_block: { ...block, input: {} } });
    }
    stream({ type: "content_block_stop", index });
    const message = { id, model, role: "assistant", type: "message", content: [block] };
    const uuid = record("assistant", message);
    out({ type: "assistant", message, parent_tool_use_id: null, session_id: sessionId, uuid });
  }
  stream({ type: "message_stop" });
  return true;
}

async function controlRequest(request: Json): Promise<Json> {
  const requestId = randomUUID();
  const answer = new Promise<Json>((resolve) => pendingControl.set(requestId, resolve));
  out({ type: "control_request", request_id: requestId, request });
  return answer;
}

async function toolTurn(name: string, input: Json, toolId = `toolu_${randomUUID().slice(0, 8)}`) {
  await apiMessage([{ type: "tool_use", id: toolId, name, input }]);
  const response = await controlRequest({
    subtype: "can_use_tool",
    tool_name: name,
    input,
    tool_use_id: toolId,
    permission_suggestions: [{ type: "addRules", rules: [{ toolName: name }], behavior: "allow", destination: "localSettings" }],
  });
  const decision = response.response ?? {};
  const allowed = decision.behavior === "allow";
  const content = allowed ? `ran ${name} ${JSON.stringify(decision.updatedInput ?? input)}` : String(decision.message);
  const message = { role: "user", content: [{ type: "tool_result", tool_use_id: toolId, content, is_error: !allowed }] };
  const uuid = record("user", message);
  out({ type: "user", message, parent_tool_use_id: null, session_id: sessionId, uuid });
  return { allowed, decision };
}

function result(subtype: string, text: string) {
  out({
    type: "result",
    ...(answering.length ? { user_message_uuid: answering.at(-1), user_message_uuids: answering } : {}),
    subtype,
    is_error: subtype !== "success",
    result: text,
    ...(subtype === "success" ? {} : { errors: [`fake ${subtype}`] }),
    session_id: sessionId,
    num_turns: 1,
    duration_ms: 10,
    total_cost_usd: 0,
    usage: { input_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 0, output_tokens: 5, output_tokens_details: { thinking_tokens: 0 } },
    modelUsage: { [model]: { contextWindow: 200000 } },
    permission_denials: [],
    uuid: randomUUID(),
  });
  out({ type: "system", subtype: "session_state_changed", state: "idle", session_id: sessionId, uuid: randomUUID() });
  register("idle");
}

async function runTurn(message: Json) {
  const text = typeof message.message.content === "string" ? message.message.content : message.message.content.map((block: Json) => block.text ?? "").join("");
  record("user", message.message, message.uuid);
  answering = message.uuid ? [message.uuid] : [];
  stamped = false;
  interrupted = false;
  register("busy");
  out({ type: "system", subtype: "init", session_id: sessionId, cwd, model, permissionMode, tools: [], mcp_servers: [], uuid: randomUUID() });
  out({ type: "system", subtype: "session_state_changed", state: "running", session_id: sessionId, uuid: randomUUID() });
  out({ type: "rate_limit_event", rate_limit_info: { status: "allowed", unifiedWindows: { five_hour: { utilization: 0.25, resetsAt: 1_800_000_000 } } }, session_id: sessionId, uuid: randomUUID() });

  if (text.startsWith("TOOL ")) {
    const [, name, ...rest] = text.split(" ");
    const { allowed } = await toolTurn(name!, JSON.parse(rest.join(" ") || "{}"));
    await apiMessage([{ type: "text", text: allowed ? `done ${name}` : `skipped ${name}` }]);
    return result("success", "done");
  }
  if (text === "ASK") {
    const input = { questions: [{ question: "Tea or coffee?", header: "Drink", multiSelect: false, options: [{ label: "Tea", description: "tea" }, { label: "Coffee", description: "coffee" }] }] };
    const { decision } = await toolTurn("AskUserQuestion", input);
    await apiMessage([{ type: "text", text: `picked ${JSON.stringify(decision.updatedInput?.answers ?? null)}` }]);
    return result("success", "asked");
  }
  if (text === "THINK") {
    await apiMessage([{ type: "thinking", thinking: "considering options" }, { type: "text", text: "thought it through" }]);
    return result("success", "thought");
  }
  if (text === "SLOW") {
    const completed = await apiMessage([{ type: "text", text: "tick ".repeat(40) }], 40);
    if (!completed && nowMessage) {
      // priority now 的人工输入：当前输出让位，同一轮继续回应新消息，一个结果收尾。
      const entry = nowMessage;
      nowMessage = undefined;
      interrupted = false;
      record("user", entry.message, entry.uuid);
      answering.push(entry.uuid);
      await apiMessage([{ type: "text", text: `steered: ${entry.message.content}` }]);
      return result("success", "slow steered");
    }
    if (!completed || interrupted) {
      const marker = { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] };
      out({ type: "user", message: marker, parent_tool_use_id: null, session_id: sessionId, uuid: record("user", marker) });
      return result("error_during_execution", "");
    }
    return result("success", "slow done");
  }
  if (text.startsWith("CRASH ")) {
    // 标题已经写好，进程却在回合中途退出（崩溃或被结束），没有结果帧。
    appendFileSync(transcript, `${JSON.stringify({ type: "ai-title", aiTitle: text.slice("CRASH ".length), sessionId })}\n`);
    process.exit(1);
  }
  if (text.startsWith("TITLE ")) {
    // 真实 CLI 会异步生成 AI 标题，写成一条 ai-title 记录（SDK 读成会话名）。
    appendFileSync(transcript, `${JSON.stringify({ type: "ai-title", aiTitle: text.slice("TITLE ".length), sessionId })}\n`);
  }
  await apiMessage([{ type: "text", text: `echo[${model}]: ${text}` }]);
  return result("success", text);
}

async function loop() {
  while (true) {
    const next = queue.shift();
    if (!next) {
      await new Promise<void>((resolve) => (wake = resolve));
      continue;
    }
    busy = true;
    await runTurn(next);
    busy = false;
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  const frame = JSON.parse(line) as Json;
  if (frame.type === "control_request") {
    const subtype = frame.request?.subtype;
    if (subtype === "interrupt") interrupted = true;
    if (subtype === "set_model") model = frame.request.model ?? model;
    if (subtype === "set_permission_mode") permissionMode = frame.request.mode;
    const response =
      subtype === "initialize"
        ? { commands: [], agents: [], output_style: "default", available_output_styles: ["default"], models: [], account: {}, pid: process.pid, current_permission_mode: permissionMode, session_state: "idle", capabilities: [] }
        : {};
    out({ type: "control_response", response: { subtype: "success", request_id: frame.request_id, response } });
    return;
  }
  if (frame.type === "control_response") {
    const id = frame.response?.request_id;
    pendingControl.get(id)?.(frame.response);
    pendingControl.delete(id);
    return;
  }
  if (frame.type === "user") {
    // 运行中的 priority now 消息打断当前输出并并入这一轮；其余排队成为下一轮。
    if (busy && frame.priority === "now") {
      nowMessage = frame;
      interrupted = true;
      return;
    }
    queue.push(frame);
    wake?.();
  }
});
rl.on("close", () => process.exit(0));
void loop();
