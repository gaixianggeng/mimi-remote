#!/usr/bin/env node
// #498 H12 隔离验收：真实 Harness + 当前 agentd + Simulator 中的原生 iOS 客户端。
// 模型是回环确定性 SSE 服务，不读取供应商凭据；所有状态写入既有隔离研究缓存。

import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { createRequire } from 'node:module'
import { access, mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'

const [researchRootArgument, agentdArgument] = process.argv.slice(2)
assert(researchRootArgument && isAbsolute(researchRootArgument), 'Pass the absolute isolated Harness cache root')
assert(agentdArgument && isAbsolute(agentdArgument), 'Pass the absolute current agentd binary path')
const researchRoot = resolve(researchRootArgument)
const agentd = resolve(agentdArgument)
assert.equal(
  (await readFile(join(researchRoot, '.gh-492-harness-smoke-root'), 'utf8')).trim(),
  'isolated-gh-492',
  'Refusing to use a directory that is not the isolated Harness cache',
)
await access(join(researchRoot, 'runtime/node_modules/.bin/dsh'))
await access(agentd)

const repositoryRoot = resolve(dirname(new URL(import.meta.url).pathname), '../..')
const runRoot = join(researchRoot, 'h12-gh498', `run-${Date.now()}-${randomUUID().slice(0, 8)}`)
const state = join(runRoot, 'state')
const logs = join(runRoot, 'logs')
const configPath = join(runRoot, 'agentd', 'config.json')
await Promise.all([state, logs, dirname(configPath)].map(path => mkdir(path, { recursive: true })))

const require = createRequire(join(researchRoot, 'runtime/package.json'))
const WebSocket = require('ws')
const yaml = require('js-yaml')
for (const name of ['dsh', 'dsh-api-gateway', 'dsh-api-session-controller', 'dsh-llm-pi-ai', 'dsh-client-connection']) {
  assert.equal(require(`@deepseek-ai/${name}/package.json`).version, '0.1.5-rc.2', `Unexpected ${name} version`)
}

const agentdOrigin = 'http://127.0.0.1:28787'
const agentdToken = 'h12-local-fixture-token-not-secret'
let harness
let agentdServer
let modelServer
let harnessOrigin
let harnessCookie
let harnessOutput = ''
let agentdOutput = ''
let xcodeOutput = ''
let modelCalls = 0
let webPeer
let releaseWebReady
const webReady = new Promise(resolvePromise => { releaseWebReady = resolvePromise })

const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds))
async function until(predicate, label, timeout = 30_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await delay(25)
  }
  throw new Error(`Timed out: ${label}`)
}

async function run(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd ?? repositoryRoot,
    env: options.env ?? process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  let stdout = ''
  let stderr = ''
  child.stdout.on('data', data => { stdout += data })
  child.stderr.on('data', data => { stderr += data })
  if (options.input !== undefined) child.stdin.end(options.input)
  else child.stdin.end()
  const [code, signal] = await once(child, 'exit')
  if (code !== 0) {
    await writeFile(join(logs, `${options.label ?? 'command'}-stdout.log`), stdout, { mode: 0o600 })
    await writeFile(join(logs, `${options.label ?? 'command'}-stderr.log`), stderr, { mode: 0o600 })
    throw new Error(`${options.label ?? command} failed: code=${String(code)} signal=${String(signal)}`)
  }
  return { stdout, stderr }
}

function startModelServer() {
  modelServer = createServer(async (request, response) => {
    try {
      assert.equal(new URL(request.url, 'http://localhost').pathname, '/v1/messages')
      const chunks = []
      for await (const chunk of request) chunks.push(chunk)
      const body = JSON.parse(Buffer.concat(chunks))
      assert.equal(body.stream, true)
      const toolNames = (body.tools ?? []).map(tool => tool.name)
      const isTaskCall = toolNames.length > 0
      if (isTaskCall) await webReady
      const call = isTaskCall ? ++modelCalls : 0
      const question = call === 1
        ? {
            name: 'ask_user_question',
            input: {
              questions: [{
                id: 'confirm',
                question: 'Continue deterministic H12 fixture?',
                options: [{ label: 'Continue' }],
              }],
            },
          }
        : undefined
      if (question) assert(toolNames.includes(question.name))
      response.writeHead(200, { 'Content-Type': 'text/event-stream' })
      const event = (type, data) => response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`)
      event('message_start', {
        message: {
          id: `msg_h12_${call}`,
          type: 'message',
          role: 'assistant',
          content: [],
          model: body.model,
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 10, output_tokens: 0 },
        },
      })
      event('content_block_start', {
        index: 0,
        content_block: question
          ? { type: 'tool_use', id: 'tool_h12_question', name: question.name, input: {} }
          : { type: 'text', text: '' },
      })
      await delay(40)
      event('content_block_delta', {
        index: 0,
        delta: question
          ? { type: 'input_json_delta', partial_json: JSON.stringify(question.input) }
          : { type: 'text_delta', text: call === 0 ? 'fixture title' : 'fixture ' },
      })
      if (!question && call > 0) {
        await delay(40)
        event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: 'complete' } })
      }
      event('content_block_stop', { index: 0 })
      event('message_delta', {
        delta: { stop_reason: question ? 'tool_use' : 'end_turn', stop_sequence: null },
        usage: { output_tokens: 10 },
      })
      event('message_stop', {})
      response.end()
    } catch (error) {
      if (!response.headersSent) response.writeHead(500)
      response.end(String(error))
    }
  })
  modelServer.listen(0, '127.0.0.1')
  return once(modelServer, 'listening')
}

async function harnessRPC(method, args) {
  const response = await fetch(`${harnessOrigin}/api/${method}`, {
    method: 'POST',
    headers: { Cookie: harnessCookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `h12-${randomUUID()}`,
      method,
      payload: { args },
    }),
  })
  assert.equal(response.status, 200)
  const envelope = await response.json()
  assert.equal(envelope.result?.ok, true, JSON.stringify(envelope.result?.error))
  return envelope.result.value
}

async function observeWebPeer() {
  const sessionID = await until(async () => {
    const listed = await harnessRPC('session/list', { _request: {} })
    return listed.items?.find(item => item.sessionId?.startsWith('h12-ios-'))?.sessionId
  }, 'iOS-created Harness session')
  const socket = new WebSocket(`${harnessOrigin.replace('http:', 'ws:')}/api/remote.mux`, {
    headers: { Cookie: harnessCookie },
  })
  const frames = []
  socket.on('message', data => frames.push(JSON.parse(data)))
  await once(socket, 'open')
  const open = (streamId, endpoint, args) => socket.send(JSON.stringify({
    type: 'open', streamId, endpoint, payload: { args },
  }))
  open('web-events', '$events', {})
  await until(() => frames.some(frame => frame.streamId === 'web-events' && frame.value?.type === 'ready'), 'Web $events ready')
  open('web-follow', 'session/follow', {
    request: { address: { kind: 'session', sessionId: sessionID }, assistantStream: true, maxMessages: 50 },
  })
  await until(() => frames.some(frame => frame.streamId === 'web-follow' && frame.value?.type === 'snapshot'), 'Web opening snapshot')
  webPeer = { socket, frames, sessionID }
  releaseWebReady()
  return webPeer
}

async function stopChild(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return
  const exited = once(child, 'exit')
  child.kill('SIGTERM')
  const hardStop = setTimeout(() => child.kill('SIGKILL'), 5_000)
  try { await exited } finally { clearTimeout(hardStop) }
}

try {
  assert.rejects(fetch(`${agentdOrigin}/healthz`), undefined)
  await startModelServer()
  await writeFile(join(state, 'settings.yaml'), yaml.dump({
    'llm-pi-ai': {
      providers: {
        'research-mock': {
          api: 'anthropic-messages',
          baseURL: `http://127.0.0.1:${modelServer.address().port}`,
          apiKeyEnv: 'MIMI_RESEARCH_MOCK_KEY',
          retryPolicy: { mode: 'normal', maxRetries: 0 },
          models: [{ id: 'fixture-model', contextWindow: 100000, maxTokens: 1024 }],
        },
      },
    },
  }), { mode: 0o600 })

  harness = spawn(join(researchRoot, 'runtime/node_modules/.bin/dsh'), ['web', '--no-open', '--port', '0'], {
    cwd: repositoryRoot,
    env: {
      PATH: process.env.PATH,
      LANG: 'en_US.UTF-8',
      DSH_HOME: state,
      MIMI_RESEARCH_MOCK_KEY: 'local-fixture',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  harness.stdout.on('data', data => { harnessOutput += data })
  harness.stderr.on('data', data => { harnessOutput += data })
  const startupURL = await until(
    () => harnessOutput.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=\S+/)?.[0],
    'Harness startup',
    60_000,
  )
  harnessOrigin = new URL(startupURL).origin
  const authentication = await fetch(startupURL, { redirect: 'manual' })
  assert.equal(authentication.status, 303)
  harnessCookie = authentication.headers.getSetCookie().map(value => value.split(';')[0]).join('; ')
  assert(harnessCookie)

  await run(agentd, [
    'setup', '--config', configPath,
    '--scan-root', repositoryRoot,
    '--browse-root', repositoryRoot,
    '--listen', '127.0.0.1:28787',
    '--force', '--json',
  ], { label: 'agentd-setup' })
  await run(agentd, [
    'runtime', '--config', configPath,
    '--deepseek', 'connect', '--deepseek-url-stdin', '--json',
  ], { input: `${startupURL}\n`, label: 'agentd-runtime-connect' })

  agentdServer = spawn(agentd, ['serve', '--config', configPath], {
    cwd: repositoryRoot,
    env: { ...process.env, AGENTD_TOKEN: agentdToken },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  agentdServer.stdout.on('data', data => { agentdOutput += data })
  agentdServer.stderr.on('data', data => { agentdOutput += data })
  await until(async () => {
    try { return (await fetch(`${agentdOrigin}/healthz`)).ok } catch { return false }
  }, 'agentd health', 30_000)
  const nativeCatalog = await fetch(`${agentdOrigin}/api/harness/rpc`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${agentdToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ rpcId: 'h12-catalog', method: 'session/modelCatalog', args: {} }),
  })
  assert.equal(nativeCatalog.status, 200)

  const webObservation = observeWebPeer()
  const xcode = spawn('bash', [
    './scripts/ios-dev.sh', 'test',
    '-only-testing:MimiRemoteTests/HarnessEventClientTests/testLiveH12RealHarnessQuestionFlow',
  ], { cwd: repositoryRoot, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] })
  xcode.stdout.on('data', data => { xcodeOutput += data })
  xcode.stderr.on('data', data => { xcodeOutput += data })
  const [xcodeCode, xcodeSignal] = await once(xcode, 'exit')
  assert.equal(xcodeCode, 0, `iOS test failed: signal=${String(xcodeSignal)}`)
  const peer = await webObservation
  const question = await until(
    () => peer.frames.find(frame => frame.value?.event === 'user-questions/request')?.value,
    'Web question',
  )
  await until(
    () => peer.frames.some(frame => frame.value?.type === 'cancel' && frame.value.eventId === question.eventId),
    'Web cancellation after iOS answer',
  )
  await until(() => modelCalls === 2, 'deterministic model completion')
  await until(() => JSON.stringify(peer.frames).includes('fixture complete'), 'Web final assistant output')
  assert.match(xcodeOutput, /testLiveH12RealHarnessQuestionFlow.*passed/)
  assert.match(xcodeOutput, /Executed 1 test, with 0 failures/)
  assert.doesNotMatch(xcodeOutput, /skipped/)

  const summary = {
    status: 'PASS',
    source: 'current worktree binary and Simulator build',
    harnessVersion: '0.1.5-rc.2',
    agentdOrigin,
    iosTestsExecuted: 1,
    iosFailures: 0,
    webObservedQuestion: true,
    webObservedCancelAfterIOSAnswer: true,
    webObservedFinalAssistant: true,
    deterministicModelCalls: modelCalls,
    realProviderCalls: 0,
  }
  await writeFile(join(logs, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`, { mode: 0o600 })
  process.stdout.write(`PASS H12 native Harness dual-client flow\nEvidence: ${join(logs, 'summary.json')}\n`)
} finally {
  if (webPeer?.socket?.readyState === WebSocket.OPEN) webPeer.socket.close()
  await stopChild(agentdServer)
  await stopChild(harness)
  if (modelServer) {
    modelServer.closeAllConnections()
    await new Promise(resolvePromise => modelServer.close(resolvePromise))
  }
  await writeFile(join(logs, 'harness.log'), harnessOutput, { mode: 0o600 })
  await writeFile(join(logs, 'agentd.log'), agentdOutput, { mode: 0o600 })
  await writeFile(join(logs, 'xcode.log'), xcodeOutput, { mode: 0o600 })
}
