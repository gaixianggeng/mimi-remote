// JSON-RPC 2.0 帧的最小模型。app-server 协议按行传输，每行一个 JSON 对象。

export type RequestId = string | number;

export interface RpcRequest {
  id: RequestId;
  method: string;
  params?: unknown;
}

export interface RpcNotification {
  method: string;
  params?: unknown;
}

export interface RpcErrorBody {
  code: number;
  message: string;
  data?: unknown;
}

export type OutboundFrame = Record<string, unknown>;

export const ErrorCode = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
} as const;

export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
  }

  static invalidParams(message: string): RpcError {
    return new RpcError(ErrorCode.invalidParams, message);
  }
}

export type ClassifiedFrame =
  | { kind: "request"; frame: RpcRequest }
  | { kind: "notification"; frame: RpcNotification }
  | { kind: "response"; id: RequestId }
  | { kind: "invalid"; reason: string };

function isRequestId(value: unknown): value is RequestId {
  return typeof value === "string" || (typeof value === "number" && Number.isFinite(value));
}

export function classifyFrame(value: unknown): ClassifiedFrame {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { kind: "invalid", reason: "frame must be a JSON object" };
  }
  const frame = value as Record<string, unknown>;
  const method = frame.method;
  const hasId = "id" in frame && frame.id !== null && frame.id !== undefined;
  if (typeof method === "string") {
    if (!hasId) return { kind: "notification", frame: { method, params: frame.params } };
    if (!isRequestId(frame.id)) return { kind: "invalid", reason: "request id must be a string or number" };
    return { kind: "request", frame: { id: frame.id, method, params: frame.params } };
  }
  if (hasId && isRequestId(frame.id) && ("result" in frame || "error" in frame)) {
    return { kind: "response", id: frame.id };
  }
  return { kind: "invalid", reason: "frame is neither a request, notification nor response" };
}

export function resultFrame(id: RequestId, result: unknown): OutboundFrame {
  return { jsonrpc: "2.0", id, result };
}

export function errorFrame(id: RequestId | null, error: RpcErrorBody): OutboundFrame {
  return { jsonrpc: "2.0", id, error };
}

export function notificationFrame(method: string, params: unknown): OutboundFrame {
  return { jsonrpc: "2.0", method, params };
}

/** 客户端请求的响应只属于发起它的那条连接，断线重放时不能交给新连接。 */
export function isClientRequestResponse(frame: OutboundFrame): boolean {
  return typeof frame.method !== "string" && "id" in frame && ("result" in frame || "error" in frame);
}
