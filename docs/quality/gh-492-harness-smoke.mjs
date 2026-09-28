// #492 的隔离协议实验。仅连接回环模拟模型，不使用真实模型凭据或用户项目。
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve, join } from 'node:path';

assert(process.argv[2] && isAbsolute(process.argv[2]), 'Pass the dedicated absolute research cache path');
const root = resolve(process.argv[2]);
// 显式标记由复现步骤创建，防止误把生产 DSH_HOME 或用户项目当作实验目录。
assert.equal((await readFile(join(root, '.gh-492-harness-smoke-root'), 'utf8')).trim(), 'isolated-gh-492');
const require = createRequire(join(root, 'runtime/package.json'));
const WebSocket = require('ws');
const yaml = require('js-yaml');
for (const name of ['dsh', 'dsh-api-gateway', 'dsh-api-session-controller', 'dsh-llm-pi-ai', 'dsh-client-connection', 'dsh-user-approval']) {
  assert.equal(require(`@deepseek-ai/${name}/package.json`).version, '0.1.5-rc.2', `Unexpected ${name} version`);
}
const state = join(root, 'state');
const cwd = join(root, 'workspace');
const logs = join(root, 'logs');
await Promise.all([state, cwd, logs].map(path => mkdir(path, { recursive: true })));
await writeFile(join(cwd, 'fixture.txt'), 'controlled fixture\n');
let child;
let base;
let cookie;
let modelCalls = 0;
let output = '';
const requests = [];
const peers = [];
const checks = [];
const deniedPath = join(root, 'blocked-fixture.txt');
assert.equal(await access(deniedPath).then(() => true, () => false), false);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, label, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await delay(25);
  }
  throw new Error(`Timed out: ${label}`);
}
function pass(name) { checks.push(name); console.log(`PASS ${name}`); }

// Anthropic Messages 模拟器只生成固定工具参数。它验证协议，不代表火山兼容性或编码能力。
const mock = createServer(async (req, res) => {
  try {
    assert.equal(new URL(req.url, 'http://localhost').pathname, '/v1/messages');
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks));
    assert.equal(body.stream, true);
    // 标题生成也会访问模型；只把带工具的任务请求计入多轮实验。
    const names = (body.tools ?? []).map(tool => tool.name);
    const call = names.length > 0 ? ++modelCalls : 0;
    if (call) requests.push(body);
    const tool = call === 1 ? { name: 'read', input: { file_path: join(cwd, 'fixture.txt') } }
      : call === 2 ? { name: 'ask_user_question', input: { questions: [{ id: 'confirm', question: 'Continue fixture?', options: [{ label: 'Continue' }] }] } }
        : call === 4 || call === 5 ? { name: 'write', input: { file_path: deniedPath, content: 'must not be written', ...(call === 5 ? { sandbox_permissions: 'danger-full-access', justification: 'Controlled fixture: request and reject this same denied write.' } : {}) } }
          : call === 7 ? { name: 'ask_user_question', input: { questions: [{ id: 'cancel', question: 'This fixture will be cancelled.' }] } }
            : null;
    if (tool) assert(names.includes(tool.name), `Missing tool ${tool.name}`);
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const event = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
    event('message_start', { message: { id: `msg_fixture_${call}`, type: 'message', role: 'assistant', content: [], model: body.model, stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } } });
    event('content_block_start', { index: 0, content_block: tool ? { type: 'tool_use', id: `tool_fixture_${call}`, name: tool.name, input: {} } : { type: 'text', text: '' } });
    await delay(40);
    event('content_block_delta', { index: 0, delta: tool ? { type: 'input_json_delta', partial_json: JSON.stringify(tool.input) } : { type: 'text_delta', text: 'fixture ' } });
    if (!tool) { await delay(40); event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: 'complete' } }); }
    event('content_block_stop', { index: 0 });
    event('message_delta', { delta: { stop_reason: tool ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: 10 } });
    event('message_stop', {});
    res.end();
  } catch (error) { if (!res.headersSent) res.writeHead(500); res.end(String(error)); }
});
mock.listen(0, '127.0.0.1');
await once(mock, 'listening');

async function rpc(endpoint, args) {
  const response = await fetch(`${base}/api/${endpoint}`, {
    method: 'POST', headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId: crypto.randomUUID(), method: endpoint, payload: { args } }),
  });
  assert.equal(response.status, 200);
  const envelope = await response.json();
  assert.equal(envelope.result.ok, true, JSON.stringify(envelope.result.error));
  return envelope.result.value;
}
async function connect() {
  const ws = new WebSocket(`${base.replace('http:', 'ws:')}/api/remote.mux`, { headers: { Cookie: cookie } });
  const frames = [];
  ws.on('message', data => frames.push(JSON.parse(data)));
  await once(ws, 'open');
  const peer = { ws, frames, open(endpoint, args, id = endpoint) { ws.send(JSON.stringify({ type: 'open', streamId: id, endpoint, payload: { args } })); } };
  peers.push(peer);
  peer.open('$events', {});
  peer.clientId = (await until(() => frames.find(frame => frame.value?.type === 'ready'), 'event generation')).value.clientId;
  return peer;
}
function waterfall(peer) { return peer.frames.find(frame => frame.value?.type === 'waterfall')?.value; }
async function closePeer(peer) { if (peer.ws.readyState === WebSocket.OPEN) { peer.ws.close(); await once(peer.ws, 'close'); } }
function toolResult(body, id) {
  return body.messages.flatMap(message => Array.isArray(message.content) ? message.content : [])
    .find(block => block.type === 'tool_result' && block.tool_use_id === id);
}
function resultText(block) { return typeof block.content === 'string' ? block.content : block.content.filter(item => item.type === 'text').map(item => item.text).join(''); }
function turnEnds(peer) { return peer.frames.filter(frame => frame.streamId === 'session/follow' && frame.value?.event?.type === 'turn/end').map(frame => frame.value.event); }

try {
  await writeFile(join(state, 'settings.yaml'), yaml.dump({ 'llm-pi-ai': { providers: { 'research-mock': { api: 'anthropic-messages', baseURL: `http://127.0.0.1:${mock.address().port}`, apiKeyEnv: 'MIMI_RESEARCH_MOCK_KEY', retryPolicy: { mode: 'normal', maxRetries: 0 }, models: [{ id: 'fixture-model', contextWindow: 100000, maxTokens: 1024 }] } } } }), { mode: 0o600 });
  child = spawn(join(root, 'runtime/node_modules/.bin/dsh'), ['web', '--no-open', '--port', '0'], {
    cwd, env: { PATH: process.env.PATH, LANG: 'en_US.UTF-8', DSH_HOME: state, MIMI_RESEARCH_MOCK_KEY: 'local-fixture' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  const launch = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=\S+/)?.[0], 'server launch', 60000);
  base = new URL(launch).origin;
  assert.equal((await fetch(`${base}/api/session/modelCatalog`, { method: 'POST' })).status, 401);
  const auth = await fetch(launch, { redirect: 'manual' });
  assert.equal(auth.status, 303);
  cookie = auth.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  assert(cookie);
  pass('loopback launch and Cookie authentication');
  const catalog = await rpc('session/modelCatalog', {});
  await writeFile(join(logs, 'catalog.json'), JSON.stringify(catalog, null, 2));
  const ark = catalog.groups.find(group => group.id === 'ark-coding-plan-cn');
  assert(ark?.models.some(model => model.id === 'deepseek-v4-pro'));
  assert(ark.models.some(model => model.id === 'deepseek-v4-flash'));
  pass('official Ark plugin Coding Plan model catalog without credentials');
  const { sessionId } = await rpc('session/create', { request: { cwd } });
  await rpc('session/selectModel', { request: { sessionId, provider: 'research-mock', model: 'fixture-model' } });
  const a = await connect();
  const b = await connect();
  const follow = { request: { address: { kind: 'session', sessionId }, assistantStream: true } };
  a.open('session/follow', follow);
  b.open('session/follow', follow);
  // Opening snapshot 的真实类型在失败时仅写本地帧日志，避免打印会话标识。
  await until(() => [a, b].every(peer => peer.frames.some(frame => frame.streamId === 'session/follow' && frame.value?.type === 'snapshot')), 'both follow openings');
  const request = { sessionId, requestId: crypto.randomUUID(), mode: 'queue', content: [{ type: 'text', text: 'Run the controlled fixture: read fixture.txt, ask for confirmation, then finish.' }] };
  await rpc('session/prompt', { request });
  const first = await until(() => waterfall(a), 'user question');
  const second = await until(() => waterfall(b), 'second observer question');
  assert.equal(first.event, 'user-questions/request');
  assert.equal(first.eventId, second.eventId);
  const start = peer => peer.frames.find(frame => frame.value?.event?.type === 'turn/start')?.value.event;
  await until(() => start(a) && start(b), 'shared durable turn event');
  assert.deepEqual(start(a), start(b));
  assert([a, b].every(peer => peer.frames.some(frame => frame.value?.type === 'assistant-stream' && frame.value.frame.type === 'chunk')));
  assert.equal(modelCalls, 2);
  pass('streaming model → real read tool → second model → user question on two subscribers');
  await closePeer(a);
  await closePeer(b);
  const c = await connect();
  c.open('session/follow', follow);
  const replay = await until(() => waterfall(c), 'pending interaction replay');
  assert.equal(replay.eventId, first.eventId);
  const d = await connect();
  assert.equal((await until(() => waterfall(d), 'second replay observer')).eventId, replay.eventId);
  pass('all clients disconnect; replacement client receives same pending eventId');
  const answer = { answers: [{ id: 'confirm', selected: ['Continue'] }] };
  await rpc('$events/result', { clientId: c.clientId, eventId: replay.eventId, outcome: { kind: 'result', value: answer } });
  await until(() => d.frames.some(frame => frame.value?.type === 'cancel' && frame.value.eventId === replay.eventId), 'other client cancellation');
  await rpc('$events/result', { clientId: d.clientId, eventId: replay.eventId, outcome: { kind: 'result', value: answer } });
  await until(() => modelCalls >= 3, 'model resumes after question');
  await until(() => turnEnds(c).length === 1, 'turn completion');
  assert.equal(turnEnds(c)[0].data.reason.kind, 'completed');
  assert.equal(modelCalls, 3);
  pass('first answer wins; other subscriber cancelled; late answer harmless; task completes');
  const e = await connect();
  e.open('session/follow', follow);
  const opening = await until(() => e.frames.find(frame => frame.streamId === 'session/follow')?.value, 'restored history');
  await writeFile(join(logs, 'history-opening.json'), JSON.stringify(opening, null, 2));
  assert(JSON.stringify(opening).includes('fixture complete'));
  pass('new connection restores completed history');
  const callsBeforeRetry = modelCalls;
  await rpc('session/prompt', { request });
  await delay(200);
  assert.equal(modelCalls, callsBeforeRetry);
  pass('observed prompt retry reuses requestId without another model request');
  const readResult = toolResult(requests[1], 'tool_fixture_1');
  assert(readResult && !readResult.is_error);
  assert(resultText(readResult).includes('1: controlled fixture\n'));
  const answerResult = toolResult(requests[2], 'tool_fixture_2');
  assert(answerResult && !answerResult.is_error);
  assert.deepEqual(JSON.parse(resultText(answerResult)), answer);
  pass('read result and structured user answer reach next model requests');
  await rpc('session/prompt', { request: { ...request, requestId: crypto.randomUUID(), content: [{ type: 'text', text: 'Run the controlled denied-write fixture.' }] } });
  const approval = await until(() => c.frames.find(frame => frame.value?.event === 'approval/request')?.value, 'permission approval');
  assert.equal(approval.request.toolName, 'write');
  assert.equal(modelCalls, 5);
  assert.equal(await access(deniedPath).then(() => true, () => false), false);
  await rpc('$events/result', { clientId: c.clientId, eventId: approval.eventId, outcome: { kind: 'result', value: 'rejected' } });
  await until(() => turnEnds(c).length === 2, 'denied-write completion');
  assert.equal(modelCalls, 6);
  assert(toolResult(requests[4], 'tool_fixture_4').is_error);
  assert(toolResult(requests[5], 'tool_fixture_5').is_error);
  assert.equal(await access(deniedPath).then(() => true, () => false), false);
  pass('outside-workspace write denied; escalation approval rejected; file absent');
  await rpc('session/prompt', { request: { ...request, requestId: crypto.randomUUID(), content: [{ type: 'text', text: 'Run the controlled cancellation fixture.' }] } });
  const waiting = await until(() => c.frames.find(frame => frame.value?.type === 'waterfall' && frame.value.request?.questions?.[0]?.id === 'cancel')?.value, 'cancel fixture question');
  await rpc('session/cancel', { request: { sessionId } });
  await until(() => c.frames.some(frame => frame.value?.type === 'cancel' && frame.value.eventId === waiting.eventId), 'cancel pending interaction');
  await until(() => turnEnds(c).length === 3, 'cancelled turn');
  assert.notEqual(turnEnds(c)[2].data.reason.kind, 'completed');
  assert.equal(modelCalls, 7);
  pass('session cancellation withdraws pending question and ends shared turn');
} finally {
  // 无论断言或日志写入是否失败，都先释放本实验持有的连接与进程。
  for (const peer of peers) peer.ws.terminate();
  if (child && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    const hardStop = setTimeout(() => child.kill('SIGKILL'), 5000);
    try { await exited; } finally { clearTimeout(hardStop); }
  }
  mock.closeAllConnections();
  await new Promise(resolve => mock.close(resolve));
  await writeFile(join(logs, 'smoke-server.log'), output, { mode: 0o600 });
  await writeFile(join(logs, 'smoke-frames.json'), JSON.stringify(peers.map(peer => peer.frames)), { mode: 0o600 });
  await writeFile(join(logs, 'smoke-summary.json'), JSON.stringify({ checks, modelCalls, realModelCalls: 0 }, null, 2));
}
