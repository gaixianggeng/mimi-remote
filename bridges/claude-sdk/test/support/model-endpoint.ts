// 原生用例的本机脚本化模型端点：按 Messages API 的格式回一条 assistant 消息，不调用付费模型。
export type Block = { type: string; id?: string; name?: string; input?: Record<string, unknown>; text?: string };

/** 一条回复；stream 时按 SSE 逐块发出，与真实 API 的事件顺序相同。 */
export function modelResponse(model: string, content: Block[], stream: boolean): Response {
  const message = { id: "msg_native", type: "message", role: "assistant", model, content, stop_reason: content[0]?.type === "tool_use" ? "tool_use" : "end_turn", stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 } };
  if (!stream) return Response.json(message);
  const events: [string, unknown][] = [["message_start", { type: "message_start", message: { ...message, content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } }]];
  content.forEach((block, index) => {
    events.push(["content_block_start", { type: "content_block_start", index, content_block: block.type === "tool_use" ? { ...block, input: {} } : { ...block, text: "" } }]);
    events.push(["content_block_delta", { type: "content_block_delta", index, delta: block.type === "tool_use" ? { type: "input_json_delta", partial_json: JSON.stringify(block.input) } : { type: "text_delta", text: block.text } }]);
    events.push(["content_block_stop", { type: "content_block_stop", index }]);
  });
  events.push(["message_delta", { type: "message_delta", delta: { stop_reason: message.stop_reason, stop_sequence: null }, usage: { output_tokens: 10 } }], ["message_stop", { type: "message_stop" }]);
  return new Response(events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

/** 指向本机端点、隔离配置目录的 CLI 环境；不读用户的 ~/.claude，也不出网。 */
export function isolatedClaudeEnv(configDir: string, port: number): Record<string, string> {
  return {
    CLAUDE_CONFIG_DIR: configDir,
    ANTHROPIC_API_KEY: "test-only",
    ANTHROPIC_AUTH_TOKEN: "",
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  };
}
