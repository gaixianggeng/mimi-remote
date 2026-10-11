// Codex UserInput[] → Claude 用户消息内容。规则与旧 bridge 一致：文本按行拼接，
// 技能写成 `/名称`，提及写成 `@名称`，图片转 base64 图片块；只有一段文本时用字符串。
import { readFileSync } from "node:fs";
import path from "node:path";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { RpcError } from "../rpc/frames.ts";

type ImageMediaType = "image/png" | "image/jpeg" | "image/gif" | "image/webp";
type ContentBlock =
  | { type: "text"; text: string }
  | { type: "image"; source: { type: "base64"; media_type: ImageMediaType; data: string } };

const MIME_BY_EXTENSION: Record<string, ImageMediaType> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};

function appendLine(buffer: string, chunk: string): string {
  if (!buffer) return chunk;
  return buffer.endsWith("\n") || buffer.endsWith(" ") ? buffer + chunk : `${buffer}\n${chunk}`;
}

function imageFromDataUrl(url: string): ContentBlock {
  const match = /^data:(image\/[a-z+.-]+);base64,(.*)$/is.exec(url);
  if (!match) throw RpcError.invalidParams("图片输入必须是 base64 data URL");
  const mediaType = match[1]!.toLowerCase() as ImageMediaType;
  return { type: "image", source: { type: "base64", media_type: mediaType, data: match[2]!.replace(/\s+/g, "") } };
}

function imageFromFile(file: string): ContentBlock {
  const mediaType = MIME_BY_EXTENSION[path.extname(file).toLowerCase()];
  if (!mediaType) throw RpcError.invalidParams(`不支持的图片类型：${path.basename(file)}`);
  let data: string;
  try {
    data = readFileSync(file).toString("base64");
  } catch {
    throw RpcError.invalidParams(`无法读取图片：${path.basename(file)}`);
  }
  return { type: "image", source: { type: "base64", media_type: mediaType, data } };
}

export function toClaudeContent(inputs: readonly UserInput[]): string | ContentBlock[] {
  if (!inputs.length) throw RpcError.invalidParams("input 不能为空");
  const blocks: ContentBlock[] = [];
  let text = "";
  const flush = () => {
    if (text) blocks.push({ type: "text", text });
    text = "";
  };
  for (const input of inputs) {
    switch (input.type) {
      case "text":
        text = appendLine(text, input.text);
        break;
      case "skill":
        text = appendLine(text, `/${input.name}`);
        break;
      case "mention":
        text = `${text}${text && !/[ \n]$/.test(text) ? " " : ""}@${input.name}`;
        break;
      case "image":
        flush();
        if (!("url" in input)) throw RpcError.invalidParams("图片输入缺少 url");
        blocks.push(imageFromDataUrl(input.url));
        break;
      case "localImage":
        flush();
        blocks.push(imageFromFile(input.path));
        break;
      default:
        throw RpcError.invalidParams(`不支持的输入类型 ${input.type}`);
    }
  }
  flush();
  const [first] = blocks;
  return blocks.length === 1 && first?.type === "text" ? first.text : blocks;
}
