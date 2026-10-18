// UserInput[] → Claude 消息内容。CLI 只在消息以 `/名称` 开头时展开技能；内容数组只检查最后一个块
// （以 Claude Code 2.1.294 / 2.1.296 / 2.1.301 + 脚本化模型端点实测）。
import { describe, expect, test } from "bun:test";
import type { UserInput } from "../src/protocol/codex/v2/UserInput.ts";
import { qualifySkillCommand, toClaudeContent } from "../src/runtime/userInput.ts";

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const text = (value: string): UserInput => ({ type: "text", text: value, text_elements: [] });
const skill = (name: string): UserInput => ({ type: "skill", name, path: `/skills/${name}/SKILL.md` });
const mention = (name: string): UserInput => ({ type: "mention", name, path: `/project/${name}` });
const image: UserInput = { type: "image", url: `data:image/png;base64,${PNG}` };
const imageBlock = { type: "image", source: { type: "base64", media_type: "image/png", data: PNG } } as const;

describe("技能作为命令", () => {
  test("iOS 的正文在前、技能在后，发给 CLI 时技能在开头、正文作为参数", () => {
    expect(toClaudeContent([text("总结这次改动"), skill("review")])).toBe("/review\n总结这次改动");
    expect(toClaudeContent([text("第一行\n第二行"), skill("review")])).toBe("/review\n第一行\n第二行");
  });

  test("只有技能或技能已在开头时不变", () => {
    expect(toClaudeContent([skill("review")])).toBe("/review");
    expect(toClaudeContent([skill("review"), text("总结")])).toBe("/review\n总结");
  });

  test("多个技能只有第一个作为命令，其余留在原位置作为参数文本", () => {
    expect(toClaudeContent([text("总结"), skill("review"), skill("lint")])).toBe("/review\n总结\n/lint");
    expect(toClaudeContent([text("总结"), skill("review"), text("再检查"), skill("lint")])).toBe("/review\n总结\n再检查\n/lint");
  });

  test("提及跟在原来的文本后面", () => {
    expect(toClaudeContent([text("看看"), mention("main.ts"), skill("review")])).toBe("/review\n看看 @main.ts");
  });

  test("带图片时图片在前、命令文本作为最后一块，图片不丢", () => {
    expect(toClaudeContent([text("这张截图"), image, skill("review")])).toEqual([imageBlock, { type: "text", text: "/review\n这张截图" }]);
    // 被图片隔开的多段文本合成一块，否则最后一块不以 `/` 开头。
    expect(toClaudeContent([text("前"), image, text("后"), skill("review")])).toEqual([imageBlock, { type: "text", text: "/review\n前\n后" }]);
    expect(toClaudeContent([image, skill("review")])).toEqual([imageBlock, { type: "text", text: "/review" }]);
  });

  test("手输的 /命令 带图片时同样把图片移到前面", () => {
    expect(toClaudeContent([text("/explain 这里为什么报错"), image])).toEqual([imageBlock, { type: "text", text: "/explain 这里为什么报错" }]);
  });
});

describe("没有命令时保持原样", () => {
  test("纯文本按行拼接，提及用空格", () => {
    expect(toClaudeContent([text("a"), text("b"), mention("c")])).toBe("a\nb @c");
  });

  test("文本与图片保持原来的穿插顺序", () => {
    expect(toClaudeContent([text("看图"), image])).toEqual([{ type: "text", text: "看图" }, imageBlock]);
    expect(toClaudeContent([text("前"), image, text("后")])).toEqual([{ type: "text", text: "前" }, imageBlock, { type: "text", text: "后" }]);
    expect(toClaudeContent([image])).toEqual([imageBlock]);
  });

  test("空输入与不支持的输入报参数错误", () => {
    expect(() => toClaudeContent([])).toThrow("input 不能为空");
    expect(() => toClaudeContent([{ type: "audio", url: "data:audio/wav;base64,AA==" }])).toThrow("不支持的输入类型");
  });
});

describe("受限档位的技能命令带插件前缀", () => {
  const names = new Set(["review", "deploy"]);

  test("命令位置的 /名称 改写成 /mimi:名称，正文与换行不变", () => {
    expect(qualifySkillCommand("/review", names)).toBe("/mimi:review");
    expect(qualifySkillCommand("/review 总结", names)).toBe("/mimi:review 总结");
    expect(qualifySkillCommand(toClaudeContent([text("总结"), skill("review")]), names)).toBe("/mimi:review\n总结");
  });

  test("已带前缀、插件里没有、不在开头或没有前缀分隔的名字保持原样", () => {
    expect(qualifySkillCommand("/mimi:review 总结", names)).toBe("/mimi:review 总结");
    expect(qualifySkillCommand("/compact", names)).toBe("/compact");
    expect(qualifySkillCommand("先看 /review", names)).toBe("先看 /review");
    expect(qualifySkillCommand("/reviewer", names)).toBe("/reviewer");
    expect(qualifySkillCommand("/review/x", names)).toBe("/review/x");
  });

  test("带图片时只改最后一个文本块；最后一块不是文本时不改", () => {
    expect(qualifySkillCommand(toClaudeContent([text("这张截图"), image, skill("review")]), names)).toEqual([imageBlock, { type: "text", text: "/mimi:review\n这张截图" }]);
    // CLI 只检查最后一个块，最后是图片时不会当命令执行，也就不改写。
    const imageLast = [{ type: "text" as const, text: "/review" }, imageBlock];
    expect(qualifySkillCommand(imageLast, names)).toBe(imageLast);
  });

  test("没有插件时原样返回", () => {
    const content = toClaudeContent([text("总结"), skill("review")]);
    expect(qualifySkillCommand(content, undefined)).toBe(content);
    expect(qualifySkillCommand(content, new Set())).toBe(content);
  });
});
