// 适配器日志：只写 stderr（stdio 模式下 stdout 是协议通道）。格式固定，agentd 按级别分流：
//   [mimi-claude-adapter] <level> <event> key=value …
// 级别由 MIMI_CLAUDE_ADAPTER_LOG（error|warn|info|debug|trace，默认 info）决定。agentd 托管时
// 默认 debug，由 agentd 决定是否落盘：debug 行只在 Mac App「诊断 → 详细记录」窗口内写进本机
// 调试日志。MIMI_CLAUDE_ADAPTER_TRACE=1 额外输出每条 SDK 消息的类型（trace）。
// 不记录消息正文、提示词、工具输入输出与凭据；用户主目录写成 ~。
import os from "node:os";
import { ADAPTER_NAME } from "../version.ts";

export type LogLevel = "error" | "warn" | "info" | "debug" | "trace";
export type LogFields = Record<string, string | number | boolean | null | undefined>;

const ORDER: Record<LogLevel, number> = { error: 0, warn: 1, info: 2, debug: 3, trace: 4 };

function levelFromEnv(): LogLevel {
  if (process.env.MIMI_CLAUDE_ADAPTER_TRACE === "1") return "trace";
  const value = process.env.MIMI_CLAUDE_ADAPTER_LOG?.trim().toLowerCase();
  return value && value in ORDER ? (value as LogLevel) : "info";
}

let threshold: LogLevel = levelFromEnv();
let sink: (line: string) => void = (line) => {
  process.stderr.write(`${line}\n`);
};
const home = os.homedir();

/** 测试用：替换输出与级别。返回恢复函数。 */
export function configureLogging(options: { level?: LogLevel; sink?: (line: string) => void }): () => void {
  const previous = { threshold, sink };
  if (options.level) threshold = options.level;
  if (options.sink) sink = options.sink;
  return () => {
    threshold = previous.threshold;
    sink = previous.sink;
  };
}

export function logEnabled(level: LogLevel): boolean {
  return ORDER[level] <= ORDER[threshold];
}

function scrub(text: string): string {
  const single = text.replace(/[\r\n]+/g, " ");
  return home && home !== "/" ? single.split(home).join("~") : single;
}

function formatValue(value: string | number | boolean | null): string {
  const text = scrub(String(value));
  return text === "" || /[\s"=]/.test(text) ? JSON.stringify(text) : text;
}

export function formatLogLine(level: LogLevel, event: string, fields: LogFields = {}): string {
  const parts = [`[${ADAPTER_NAME}]`, level, event];
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue;
    parts.push(`${key}=${formatValue(value)}`);
  }
  return parts.join(" ");
}

function write(level: LogLevel, event: string, fields?: LogFields): void {
  if (!logEnabled(level)) return;
  sink(formatLogLine(level, event, fields));
}

/** 自由文本（启动、致命错误等）：仍带级别，便于 agentd 分流。 */
export function logText(level: LogLevel, text: string): void {
  if (!logEnabled(level)) return;
  sink(`[${ADAPTER_NAME}] ${level} ${scrub(text)}`);
}

export const logger = {
  error: (event: string, fields?: LogFields) => write("error", event, fields),
  warn: (event: string, fields?: LogFields) => write("warn", event, fields),
  info: (event: string, fields?: LogFields) => write("info", event, fields),
  debug: (event: string, fields?: LogFields) => write("debug", event, fields),
  trace: (event: string, fields?: LogFields) => write("trace", event, fields),
};

/** 错误只记类型与简短说明，不带堆栈。 */
export function errorText(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`.slice(0, 300);
  return String(error).slice(0, 300);
}
