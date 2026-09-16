// #498 协议补测（第二版）：使用从 typert 描述符提取的正确参数名，验证
// session/list、session/search、session/page 的真实结果形状。
// 只打印结构骨架，绝不打印值。报告写到本机缓存，不进仓库。
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve, join } from 'node:path';

assert(process.argv[2] && isAbsolute(process.argv[2]), 'Pass the dedicated absolute research cache path');
const root = resolve(process.argv[2]);
assert.equal((await readFile(join(root, '.gh-492-harness-smoke-root'), 'utf8')).trim(), 'isolated-gh-492');
const require = createRequire(join(root, 'runtime/package.json'));
const WebSocket = require('ws');
const state = join(root, 'state');
const cwd = join(root, 'workspace');

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, label, timeout = 60000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await delay(25);
  }
  throw new Error(`Timed out: ${label}`);
}

function kindOf(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}
function shape(value, depth = 0, maxDepth = 8) {
  if (depth >= maxDepth) return '<' + kindOf(value) + '>';
  if (Array.isArray(value)) {
    if (value.length === 0) return [];
    const merged = {};
    let scalar = false;
    for (const item of value.slice(0, 12)) {
      const s = shape(item, depth + 1, maxDepth);
      if (s && typeof s === 'object' && !Array.isArray(s)) {
        for (const [k, v] of Object.entries(s)) merged[k] ??= v;
      } else {
        scalar = true;
      }
    }
    if (Object.keys(merged).length && scalar) return ['<scalar>', merged];
    if (Object.keys(merged).length) return [merged];
    return [kindOf(value[0])];
  }
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = shape(value[key], depth + 1, maxDepth);
    return out;
  }
  return kindOf(value);
}

let child;
let base;
let cookie;
let output = '';
let ws;

async function rpc(endpoint, args) {
  const response = await fetch(`${base}/api/${endpoint}`, {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId: crypto.randomUUID(), method: endpoint, payload: { args } }),
  });
  const envelope = await response.json().catch(() => null);
  return {
    http: response.status,
    ok: envelope?.result?.ok,
    error: envelope?.result?.error?.code ? String(envelope.result.error.code) : undefined,
    detail: envelope?.result?.error?.message ? String(envelope.result.error.message).slice(0, 200) : undefined,
    value: envelope?.result?.value,
  };
}

const report = {};
async function probe(label, endpoint, args) {
  const result = await rpc(endpoint, args);
  report[label] = {
    endpoint,
    args: args,
    ok: result.ok,
    errorCode: result.error,
    errorDetail: result.detail,
    resultShape: result.ok ? shape(result.value) : undefined,
  };
  console.log(`PROBE ${label} ok=${result.ok}${result.error ? ' code=' + result.error + ' detail=' + (result.detail ?? '') : ''}`);
  return result;
}

try {
  child = spawn(join(root, 'runtime/node_modules/.bin/dsh'), ['web', '--no-open', '--port', '0'], {
    cwd,
    env: { PATH: process.env.PATH, LANG: 'en_US.UTF-8', DSH_HOME: state },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  const launch = await until(() => output.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=\S+/)?.[0], 'server launch');
  base = new URL(launch).origin;
  const auth = await fetch(launch, { redirect: 'manual' });
  assert.equal(auth.status, 303);
  cookie = auth.headers.getSetCookie().map(value => value.split(';')[0]).join('; ');
  assert(cookie);

  // session/list：descriptor 的 wire 名是 _request。
  const listed = await probe('sessionList', 'session/list', { _request: {} });
  await probe('sessionList.badName', 'session/list', { request: {} });

  // session/search：query。
  await probe('sessionSearch', 'session/search', { request: { query: 'fixture' } });
  await probe('sessionSearch.badName', 'session/search', { query: 'fixture' });

  // 取一个真实 sessionId（不打印）。
  let sessionId = listed.value?.items?.[0]?.sessionId;
  if (!sessionId) {
    const created = await rpc('session/create', { request: { cwd } });
    sessionId = created.value?.sessionId;
  }
  assert(sessionId, 'no sessionId available');

  // session/page 需要 throughSeq：先从 follow opening snapshot 拿 cursor。
  ws = new WebSocket(`${base.replace('http:', 'ws:')}/api/remote.mux`, { headers: { Cookie: cookie } });
  const frames = [];
  ws.on('message', data => frames.push(JSON.parse(data)));
  await once(ws, 'open');
  ws.send(JSON.stringify({
    type: 'open',
    streamId: 'session/follow',
    endpoint: 'session/follow',
    payload: { args: { request: { address: { kind: 'session', sessionId }, assistantStream: true } } },
  }));
  const snapshot = await until(
    () => frames.find(frame => frame.streamId === 'session/follow' && frame.value?.type === 'snapshot')?.value,
    'follow snapshot',
  );
  report.followSnapshot = { resultShape: shape(snapshot), cursorKind: kindOf(snapshot.cursor) };
  console.log(`PROBE sessionFollow snapshot cursor=${kindOf(snapshot.cursor)} records=${Array.isArray(snapshot.records) ? snapshot.records.length : 'n/a'}`);
  await probe('sessionPage', 'session/page', { request: { address: { kind: 'session', sessionId }, throughSeq: snapshot.cursor } });
  await probe('sessionPage.maxMessages', 'session/page', { request: { address: { kind: 'session', sessionId }, throughSeq: snapshot.cursor, maxMessages: 5 } });
  await probe('sessionControl', 'session/control', {});
} finally {
  if (ws) { try { ws.terminate(); } catch { /* 已关闭 */ } }
  const reportPath = process.argv[3];
  if (reportPath) {
    await writeFile(reportPath, JSON.stringify(report, null, 2), { mode: 0o600 });
    console.log(`WROTE ${reportPath}`);
  }
  if (child && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    child.kill('SIGTERM');
    const hardStop = setTimeout(() => child.kill('SIGKILL'), 5000);
    try { await exited; } finally { clearTimeout(hardStop); }
  }
}
