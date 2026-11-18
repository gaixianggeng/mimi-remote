// 通用适配器结构化日志：只写 stderr（stdio 模式下 stdout 是协议通道）。格式固定，agentd 按级别分流：
//   [<adapterName>] <level> <event> key=value …
// 不记录消息正文、提示词、工具输入输出与凭据；用户主目录写成 ~。
import os from "node:os";

export type LogLevel = "error" | "warn" | "info" | "debug" | "trace";
export type LogFields = Record<string, string | number | boolean | null | undefined>;

const ORDER: Record<LogLevel, number> = { error: 0, warn: 1, info: 2, debug: 3, trace: 4 };

export interface AdapterLoggerConfig {
  adapterName: string;
  logEnvVar: string;
  traceEnvVar?: string;
}

export interface AdapterLogger {
  readonly adapterName: string;
  configureLogging(options: { level?: LogLevel; sink?: (line: string) => void }): () => void;
  logEnabled(level: LogLevel): boolean;
  formatLogLine(level: LogLevel, event: string, fields?: LogFields): string;
  logText(level: LogLevel, text: string): void;
  error: (event: string, fields?: LogFields) => void;
  warn: (event: string, fields?: LogFields) => void;
  info: (event: string, fields?: LogFields) => void;
  debug: (event: string, fields?: LogFields) => void;
  trace: (event: string, fields?: LogFields) => void;
}

export function createAdapterLogger(config: AdapterLoggerConfig): AdapterLogger {
  const home = os.homedir();

  function levelFromEnv(): LogLevel {
    if (config.traceEnvVar && process.env[config.traceEnvVar] === "1") return "trace";
    const value = process.env[config.logEnvVar]?.trim().toLowerCase();
    return value && value in ORDER ? (value as LogLevel) : "info";
  }

  let threshold: LogLevel = levelFromEnv();
  let sink: (line: string) => void = (line) => {
    process.stderr.write(`${line}\n`);
  };

  function scrub(text: string): string {
    const single = text.replace(/[\r\n]+/g, " ");
    return home && home !== "/" ? single.split(home).join("~") : single;
  }

  function formatValue(value: string | number | boolean | null): string {
    const text = scrub(String(value));
    return text === "" || /[\s"=]/.test(text) ? JSON.stringify(text) : text;
  }

  function logEnabled(level: LogLevel): boolean {
    return ORDER[level] <= ORDER[threshold];
  }

  function formatLogLine(level: LogLevel, event: string, fields: LogFields = {}): string {
    const parts = [`[${config.adapterName}]`, level, event];
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

  function logText(level: LogLevel, text: string): void {
    if (!logEnabled(level)) return;
    sink(`[${config.adapterName}] ${level} ${scrub(text)}`);
  }

  function configureLogging(options: { level?: LogLevel; sink?: (line: string) => void }): () => void {
    const previous = { threshold, sink };
    if (options.level) threshold = options.level;
    if (options.sink) sink = options.sink;
    return () => {
      threshold = previous.threshold;
      sink = previous.sink;
    };
  }

  return {
    adapterName: config.adapterName,
    configureLogging,
    logEnabled,
    formatLogLine,
    logText,
    error: (event, fields) => write("error", event, fields),
    warn: (event, fields) => write("warn", event, fields),
    info: (event, fields) => write("info", event, fields),
    debug: (event, fields) => write("debug", event, fields),
    trace: (event, fields) => write("trace", event, fields),
  };
}

/** 错误只记类型与简短说明，不带堆栈。 */
export function errorText(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`.slice(0, 300);
  return String(error).slice(0, 300);
}
