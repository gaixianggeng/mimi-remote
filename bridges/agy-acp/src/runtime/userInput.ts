import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import type { AcpContentBlock } from "../acp/types.ts";

export const PROMPT_PREVIEW_MAX_CHARS = 240;

export function normalizePromptForIdentity(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

export function hashNormalizedPrompt(normalizedText: string): string {
  return createHash("sha256").update(normalizedText).digest("hex").slice(0, 32);
}

function parseDataUrl(url: string): { mimeType: string; data: string } | undefined {
  const match = /^data:([^;,]+);base64,([\s\S]+)$/.exec(url.trim());
  if (!match) return undefined;
  return { mimeType: match[1]!.trim() || "image/png", data: match[2]!.trim() };
}

function mimeForExtension(filePath: string): string {
  switch (path.extname(filePath).toLowerCase()) {
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    default:
      return "image/png";
  }
}

export async function toAcpPromptBlocks(
  inputs: readonly UserInput[],
): Promise<{ blocks: AcpContentBlock[]; preview: string; promptHash?: string; promptTruncated: boolean }> {
  const blocks: AcpContentBlock[] = [];
  const previewParts: string[] = [];
  const skills: string[] = [];

  for (const item of inputs) {
    if (item.type === "skill") {
      const skillName = item.name.trim().replace(/^\/+/, "");
      if (skillName) skills.push(`/${skillName}`);
    }
  }

  for (const item of inputs) {
    switch (item.type) {
      case "text": {
        if (item.text) {
          blocks.push({ type: "text", text: item.text });
          previewParts.push(item.text);
        }
        break;
      }
      case "image": {
        const parsed = "url" in item ? parseDataUrl(item.url) : undefined;
        if (!parsed) {
          throw RpcError.invalidParams("Antigravity 图片输入仅支持 data URL 或本地上传图片");
        }
        blocks.push({ type: "image", mimeType: parsed.mimeType, data: parsed.data });
        break;
      }
      case "localImage": {
        const bytes = await readFile(item.path).catch(() => {
          throw RpcError.invalidParams(`无法读取本地图片：${path.basename(item.path)}`);
        });
        blocks.push({
          type: "image",
          mimeType: mimeForExtension(item.path),
          data: bytes.toString("base64"),
          uri: pathToFileURL(item.path).href,
        });
        break;
      }
      case "mention": {
        if (item.path) {
          blocks.push({
            type: "resource_link",
            uri: pathToFileURL(item.path).href,
            name: item.name || path.basename(item.path),
          });
        }
        break;
      }
      case "skill":
        break;
      default: {
        // 兼容客户端上传文件块（uploadedFile 等扩展对象）提取纯文本与页面截图。
        const raw = item as unknown as Record<string, unknown>;
        if (raw.type === "uploadedFile" && typeof raw.extractedText === "string" && raw.extractedText.trim()) {
          const name = typeof raw.name === "string" ? raw.name : "attachment";
          blocks.push({
            type: "resource",
            resource: {
              uri: `attachment://${encodeURIComponent(name)}`,
              mimeType: "text/plain",
              text: raw.extractedText,
            },
          });
        }
        break;
      }
    }
  }

  if (skills.length > 0) {
    const prefix = `${skills.join(" ")} `;
    const firstText = blocks.find((b): b is { type: "text"; text: string } => b.type === "text");
    if (firstText) {
      if (!firstText.text.trimStart().startsWith(skills[0]!)) {
        firstText.text = `${prefix}${firstText.text}`;
      }
    } else {
      blocks.unshift({ type: "text", text: skills.join(" ") });
    }
    previewParts.unshift(skills.join(" "));
  }

  if (blocks.length === 0) {
    throw RpcError.invalidParams("turn/start.input 不包含可发送的内容");
  }

  const normalizedPrompt = normalizePromptForIdentity(previewParts.join(" "));
  const promptTruncated = normalizedPrompt.length > PROMPT_PREVIEW_MAX_CHARS;
  const preview = normalizedPrompt.slice(0, PROMPT_PREVIEW_MAX_CHARS);
  const promptHash = normalizedPrompt ? hashNormalizedPrompt(normalizedPrompt) : undefined;
  return { blocks, preview, ...(promptHash ? { promptHash } : {}), promptTruncated };
}
