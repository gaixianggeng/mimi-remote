import { RpcError } from "../rpc/frames.ts";

/** 不透明分页游标：base64url 编码的 JSON。内容只由本适配器解释。 */
export function encodeCursor(value: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

export function decodeCursor<T extends Record<string, unknown>>(cursor: unknown, field: string): T | undefined {
  if (cursor === undefined || cursor === null) return undefined;
  if (typeof cursor !== "string" || cursor === "") throw RpcError.invalidParams(`${field} 必须是非空字符串`);
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    if (value && typeof value === "object" && !Array.isArray(value)) return value as T;
  } catch {
    // 落到下面统一报错
  }
  throw RpcError.invalidParams(`${field} 无效`);
}

export function readLimit(value: unknown, fallback: number, max: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw RpcError.invalidParams("limit 必须是正整数");
  }
  return Math.min(value, max);
}

export type Direction = "asc" | "desc";

export function readDirection(value: unknown, fallback: Direction): Direction {
  if (value === undefined || value === null) return fallback;
  if (value === "asc" || value === "desc") return value;
  throw RpcError.invalidParams("sortDirection 只能是 asc 或 desc");
}
