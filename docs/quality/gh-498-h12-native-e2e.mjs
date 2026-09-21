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
let xcodeProcess
let uiXcodeProcess
let harnessOrigin
let harnessCookie
let harnessOutput = ''
let agentdOutput = ''
let xcodeOutput = ''
let uiXcodeOutput = ''
let modelCalls = 0
let webPeer
let agentdPeer
let releaseWebReady
const webReady = new Promise(resolvePromise => { releaseWebReady = resolvePromise })

const delay = milliseconds => new Promise(resolvePromise => setTimeout(resolvePromise, milliseconds))
async function until(predicate, label, timeout = 30_000, interval = 25) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await delay(interval)
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
          : { type: 'text_delta', text: call === 0 ? 'fixture title' : call === 3 ? 'external ' : 'fixture ' },
      })
      if (!question && call > 0) {
        await delay(40)
        event('content_block_delta', {
          index: 0,
          delta: { type: 'text_delta', text: call === 3 ? 'ready' : 'complete' },
        })
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
    try {
      const listed = await harnessRPC('session/list', { _request: {} })
      return listed.items?.find(item => item.sessionId?.startsWith('h12-ios-'))?.sessionId
    } catch (error) {
      if (harness?.exitCode !== null || harness?.signalCode !== null) {
        throw new Error(`Harness exited while waiting for iOS session:\n${harnessOutput.slice(-2_000)}`, {
          cause: error,
        })
      }
      return undefined
    }
  }, 'iOS-created Harness session', 1_200_000, 250)
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

async function connectAgentdPeer() {
  const socket = new WebSocket(`${agentdOrigin.replace('http:', 'ws:')}/api/harness/ws`, {
    headers: { Authorization: `Bearer ${agentdToken}` },
  })
  const frames = []
  socket.on('message', data => frames.push(JSON.parse(data)))
  await once(socket, 'open')
  return { socket, frames }
}

function openAgentdFollow(peer, streamId, sessionID) {
  peer.socket.send(JSON.stringify({
    type: 'open', streamId, endpoint: 'session/follow', payload: { args: {
      request: {
        address: { kind: 'session', sessionId: sessionID },
        assistantStream: true,
        maxMessages: 5,
      },
    } },
  }))
}

async function waitForAgentdFollowOutcome(peer, streamId, label) {
  return until(() => peer.frames.find(frame => (
    frame.streamId === streamId
      && (frame.type === 'error' || frame.value?.type === 'snapshot')
  )), label)
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
    'runtime', '--config', configPath, '--codex', 'disabled', '--json',
  ], { label: 'agentd-disable-codex' })
  await run(agentd, [
    'runtime', '--config', configPath, '--claude', 'disabled', '--json',
  ], { label: 'agentd-disable-claude' })
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
  const authenticatedGet = path => fetch(`${agentdOrigin}${path}`, {
    headers: { Authorization: `Bearer ${agentdToken}` },
  })
  const moduleResponse = await authenticatedGet('/api/host/modules')
  assert.equal(moduleResponse.status, 200)
  const modules = await moduleResponse.json()
  assert.equal(modules.codex_enabled, false, 'H12 必须在 Codex 关闭时运行')
  assert.equal(modules.claude_enabled, false, 'H12 必须在 Claude 关闭时运行')
  const gatewayResponse = await authenticatedGet('/api/app-server/config')
  assert.equal(gatewayResponse.status, 200)
  const gateway = await gatewayResponse.json()
  const channels = gateway.channels ?? []
  assert.deepEqual(channels.map(channel => channel.runtime_id), ['deepseek'])
  assert.equal(channels[0].enabled, true)
  assert.equal(channels[0].protocol, 'harness_native_v1')
  const nativeCatalog = await fetch(`${agentdOrigin}/api/harness/rpc`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${agentdToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ rpcId: 'h12-catalog', method: 'session/modelCatalog', args: {} }),
  })
  assert.equal(nativeCatalog.status, 200)

  const webObservation = observeWebPeer()
  const h12XcodeEnvironment = {
    ...process.env,
    IOS_DEVICE_LEASE_WAIT_SECONDS: '1200',
  }
  xcodeProcess = spawn('bash', [
    './scripts/ios-dev.sh', 'test',
    '-only-testing:MimiRemoteTests/HarnessEventClientTests/testLiveH12RealHarnessQuestionFlow',
  ], { cwd: repositoryRoot, env: h12XcodeEnvironment, stdio: ['ignore', 'pipe', 'pipe'] })
  xcodeProcess.stdout.on('data', data => { xcodeOutput += data })
  xcodeProcess.stderr.on('data', data => { xcodeOutput += data })
  const xcodeExit = once(xcodeProcess, 'exit')
  // 先等观察端完成握手，确定性模型的第一个调用才会继续；同时立即持有 exit
  // promise，避免任一并发分支的拒绝在 await 前变成未处理异常。
  const peer = await Promise.race([
    webObservation,
    xcodeExit.then(([code, signal]) => {
      throw new Error(`iOS test exited before creating the Harness session: code=${String(code)} signal=${String(signal)}`)
    }),
  ])
  const [xcodeCode, xcodeSignal] = await xcodeExit
  assert.equal(xcodeCode, 0, `iOS test failed: signal=${String(xcodeSignal)}`)
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
  assert.doesNotMatch(
    xcodeOutput,
    /Test Case '.*testLiveH12RealHarnessQuestionFlow.*' skipped/
  )

  // 从真实 App Store/UI 再走一遍正式入口。测试内部在 App 已启动后由另一个客户端
  // 创建会话，断言列表无需重启即可出现，再从现有 Composer 提交到同一 transport。
  uiXcodeProcess = spawn('bash', [
    './scripts/ios-dev.sh', 'test',
    '-only-testing:MimiRemoteUITests/MimiRemotePhysicalSmokeUITests/testLiveH12FormalHarnessPathWithoutNativeFlag',
  ], {
    cwd: repositoryRoot,
    env: {
      ...h12XcodeEnvironment,
      SCHEME: 'MimiRemotePhysicalUITests',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  uiXcodeProcess.stdout.on('data', data => { uiXcodeOutput += data })
  uiXcodeProcess.stderr.on('data', data => { uiXcodeOutput += data })
  const [uiXcodeCode, uiXcodeSignal] = await once(uiXcodeProcess, 'exit')
  assert.equal(uiXcodeCode, 0, `iOS UI test failed: signal=${String(uiXcodeSignal)}`)
  assert.match(uiXcodeOutput, /testLiveH12FormalHarnessPathWithoutNativeFlag.*passed/)
  assert.match(uiXcodeOutput, /Executed 1 test, with 0 failures/)
  assert.doesNotMatch(
    uiXcodeOutput,
    /Test Case '.*testLiveH12FormalHarnessPathWithoutNativeFlag.*' skipped/
  )
  await until(() => modelCalls === 4, 'formal UI deterministic model completion')

  // 用真实 agentd 写入口把同一会话推进到 200 条以上 durable 记录。模型仍是本机
  // 确定性服务，不读取供应商凭据；这里验证的是长历史分页，不是模型质量。
  const createdSessionID = peer.sessionID
  const historySeedPrompts = 36
  const modelCallsBeforeHistorySeed = modelCalls
  for (let index = 0; index < historySeedPrompts; index += 1) {
    const seeded = await fetch(`${agentdOrigin}/api/harness/rpc`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${agentdToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        rpcId: `h12-history-seed-${index}`,
        method: 'session/prompt',
        args: {
          request: {
            requestId: `h12-history-seed-${index}`,
            sessionId: createdSessionID,
            mode: 'queue',
            content: [{ type: 'text', text: `history seed ${index}` }],
          },
        },
      }),
    })
    assert.equal(seeded.status, 200, `历史预热 prompt ${index} 必须被 agentd 接纳`)
    const seededBody = await seeded.json()
    assert.equal(seededBody.result?.ok, true, `历史预热 prompt ${index} 失败：${JSON.stringify(seededBody)}`)
  }
  await until(
    () => modelCalls === modelCallsBeforeHistorySeed + historySeedPrompts,
    'long history deterministic model completion',
    120_000,
  )
  // modelCalls 在请求开始时递增；给最后一次 SSE 完成与 durable 落盘一个有界窗口。
  await delay(500)

  // 历史分页经**真实中继**：旧 follow 的 opening cursor 属于执行前快照，不能拿它
  // 读取执行后的历史。重新打开同一会话取得新的权威 snapshot，再把该 cursor 作为
  // throughSeq；这同时覆盖“继续翻同一快照”和“刷新后使用新边界”的区别。
  const openingCursor = peer.frames.find(
    frame => frame.streamId === 'web-follow' && frame.value?.type === 'snapshot',
  )?.value?.cursor
  const historyStreamID = 'web-history-refresh'
  peer.socket.send(JSON.stringify({
    type: 'open',
    streamId: historyStreamID,
    endpoint: 'session/follow',
    payload: { args: {
      request: {
        address: { kind: 'session', sessionId: createdSessionID },
        assistantStream: true,
        maxMessages: 50,
      },
    } },
  }))
  const refreshedSnapshot = await until(
    () => peer.frames.find(
      frame => frame.streamId === historyStreamID && frame.value?.type === 'snapshot',
    )?.value,
    'Web refreshed snapshot cursor',
  )
  const followCursor = refreshedSnapshot.cursor
  assert.ok(followCursor > openingCursor, '重新打开后的 snapshot cursor 必须推进到 durable 历史之后')
  const pageThroughAgentd = async (rpcId, beforeSeq) => {
    const request = {
      address: { kind: 'session', sessionId: createdSessionID },
      throughSeq: followCursor,
      maxMessages: 5,
    }
    if (beforeSeq !== undefined) request.beforeSeq = beforeSeq
    const response = await fetch(`${agentdOrigin}/api/harness/rpc`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${agentdToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        rpcId,
        method: 'session/page',
        args: { request },
      }),
    })
    assert.equal(response.status, 200, 'session/page 必须可用')
    const body = await response.json()
    assert.equal(body.result?.ok, true, `session/page 失败：${JSON.stringify(body)}`)
    return body.result?.value
  }
  const seenHistorySeqs = new Set()
  let page = await pageThroughAgentd('h12-page-0')
  let pageIndex = 0
  while (true) {
    const records = page?.records ?? []
    assert.ok(records.length > 0, `第 ${pageIndex + 1} 页必须包含持久记录`)
    const seqs = records.map(record => record.event?.seq).filter(Number.isInteger)
    assert.equal(seqs.length, records.length, '分页记录必须都有原生 seq')
    for (const seq of seqs) {
      assert.equal(seenHistorySeqs.has(seq), false, `历史分页不得重复 seq ${seq}`)
      seenHistorySeqs.add(seq)
    }
    if (!page.hasMore) break
    const beforeSeq = Math.min(...seqs)
    pageIndex += 1
    assert.ok(pageIndex < 100, '历史分页必须在有界页数内结束')
    page = await pageThroughAgentd(`h12-page-${pageIndex}`, beforeSeq)
  }
  assert.ok(
    seenHistorySeqs.size > 200,
    `真实长历史必须超过 200 条记录，实际 ${seenHistorySeqs.size}`,
  )
  peer.socket.send(JSON.stringify({ type: 'cancel', streamId: historyStreamID }))

  // Web peer 继续只负责跨端观察。资源验收必须走带移动端凭据的 agentd WS，才能真实
  // 覆盖 /api/harness/ws 的全局 follow 名额，而不是直接绕到 Harness remote.mux。
  agentdPeer = await connectAgentdPeer()
  const heldAgentdStreams = []
  let rejectedAtCapacity
  for (let index = 0; index < 8; index += 1) {
    const streamId = `agentd-capacity-${index}`
    openAgentdFollow(agentdPeer, streamId, createdSessionID)
    const outcome = await waitForAgentdFollowOutcome(
      agentdPeer, streamId, `agentd capacity probe ${index}`,
    )
    if (outcome.type === 'error') {
      rejectedAtCapacity = outcome
      break
    }
    heldAgentdStreams.push(streamId)
  }
  assert.ok(heldAgentdStreams.length > 0, 'agentd 容量验收必须先成功持有至少一条 follow')
  assert.ok(rejectedAtCapacity, '填满 agentd follow 上限后下一条必须被明确拒绝')
  assert.equal(
    rejectedAtCapacity.error?.code,
    'gateway/service-unavailable',
    `容量拒绝必须是可恢复错误：${JSON.stringify(rejectedAtCapacity)}`,
  )

  let recyclableStreamID = heldAgentdStreams.pop()
  agentdPeer.socket.send(JSON.stringify({ type: 'cancel', streamId: recyclableStreamID }))
  await until(
    () => agentdPeer.frames.some(
      frame => frame.streamId === recyclableStreamID && frame.type === 'end',
    ),
    'agentd cancel releases one follow slot',
  )

  const followResubscribeCycles = 8
  for (let index = 0; index < followResubscribeCycles; index += 1) {
    const streamId = `agentd-reconnect-${index}`
    openAgentdFollow(agentdPeer, streamId, createdSessionID)
    const outcome = await waitForAgentdFollowOutcome(
      agentdPeer, streamId, `agentd follow reconnect ${index}`,
    )
    assert.equal(outcome.type, 'item', `第 ${index + 1} 次重订阅必须重新取得名额`)
    agentdPeer.socket.send(JSON.stringify({ type: 'cancel', streamId }))
    await until(
      () => agentdPeer.frames.some(frame => frame.streamId === streamId && frame.type === 'end'),
      `agentd follow cancel ${index}`,
    )
  }

  // 不逐条 cancel，直接断开持有剩余名额的连接；新连接必须能重新申请，证明连接退役
  // 也归还名额，且没有依赖“没有新 token”之类的空闲猜测。
  agentdPeer.socket.close()
  await once(agentdPeer.socket, 'close')
  agentdPeer = await connectAgentdPeer()
  const afterDisconnectStreamID = 'agentd-after-disconnect'
  openAgentdFollow(agentdPeer, afterDisconnectStreamID, createdSessionID)
  const afterDisconnect = await waitForAgentdFollowOutcome(
    agentdPeer, afterDisconnectStreamID, 'agentd reacquire after connection close',
  )
  assert.equal(afterDisconnect.type, 'item', '连接断开归还后必须能重新取得 follow 名额')
  agentdPeer.socket.send(JSON.stringify({ type: 'cancel', streamId: afterDisconnectStreamID }))
  await until(
    () => agentdPeer.frames.some(
      frame => frame.streamId === afterDisconnectStreamID && frame.type === 'end',
    ),
    'agentd final follow cancellation',
  )

  const summary = {
    status: 'PASS',
    source: 'current worktree binary and Simulator build',
    harnessVersion: '0.1.5-rc.2',
    agentdOrigin,
    iosTestsExecuted: 1,
    iosUITestsExecuted: 1,
    iosFailures: 0,
    formalPathWithoutNativeTestFlag: true,
    codexDisabled: modules.codex_enabled === false,
    claudeDisabled: modules.claude_enabled === false,
    externalSessionAppearedWithoutRestart: true,
    storeUIComposerCompleted: true,
    webObservedQuestion: true,
    webObservedCancelAfterIOSAnswer: true,
    webObservedFinalAssistant: true,
    // iOS 侧由宿主级 `$events` 收到并回答：断言在
    // `testLiveH12RealHarnessQuestionFlow` 内部（含归属与撤卡回执）。
    hostObservedInteraction: true,
    nativeHistoryRecords: seenHistorySeqs.size,
    nativeHistoryPages: pageIndex + 1,
    historySeedPrompts,
    followResubscribeCycles,
    agentdFollowCapacityRejected: true,
    agentdFollowReacquiredAfterDisconnect: true,
    deterministicModelCalls: modelCalls,
    realProviderCalls: 0,
  }
  await writeFile(join(logs, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`, { mode: 0o600 })
  process.stdout.write(`PASS H12 native Harness dual-client flow\nEvidence: ${join(logs, 'summary.json')}\n`)
} finally {
  if (agentdPeer?.socket?.readyState === WebSocket.OPEN) agentdPeer.socket.close()
  if (webPeer?.socket?.readyState === WebSocket.OPEN) webPeer.socket.close()
  await stopChild(uiXcodeProcess)
  await stopChild(xcodeProcess)
  await stopChild(agentdServer)
  await stopChild(harness)
  if (modelServer) {
    modelServer.closeAllConnections()
    await new Promise(resolvePromise => modelServer.close(resolvePromise))
  }
  await writeFile(join(logs, 'harness.log'), harnessOutput, { mode: 0o600 })
  await writeFile(join(logs, 'agentd.log'), agentdOutput, { mode: 0o600 })
  await writeFile(join(logs, 'xcode.log'), xcodeOutput, { mode: 0o600 })
  await writeFile(join(logs, 'xcode-ui.log'), uiXcodeOutput, { mode: 0o600 })
}
