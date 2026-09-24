#!/usr/bin/env node
// H00 协议探针：只读采集 Harness 原生 RPC 与流帧，产出脱敏骨架。
//
// 纪律：
//   - 只读。只调用 session/list、session/modelCatalog、session/page、session/follow、
//     session/control、$events。不调用 create/prompt/cancel/selectModel/updateQueue。
//   - 不启动、不安装、不重启、不升级任何 Harness。本脚本只连接一个已经在运行的服务。
//   - 不打印也不落盘 token 与 Cookie；输出里所有标识都替换成 fixture 前缀的虚构值。
//   - 报告写到隔离研究缓存，不进仓库；只有脱敏骨架允许进仓库。
//
// 用法：
//   HARNESS_ORIGIN=http://127.0.0.1:<port> HARNESS_TOKEN=<启动 token> \
//     node scripts/harness-native-probe.mjs <absolute-research-root>
//
// 研究根目录必须含一个标记文件，避免误写用户目录：
//   .h00-harness-probe-root  内容为 isolated-h00

import { randomUUID } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { isAbsolute, join, resolve } from 'node:path'

const RESEARCH_MARKER = '.h00-harness-probe-root'
const RESEARCH_MARKER_VALUE = 'isolated-h00'

const MUX_PATH = '/api/remote.mux'
const ENDPOINT_EVENTS = '$events'

const READ_ONLY_RPC = [
  { method: 'session/list', args: { _request: {} } },
  { method: 'session/modelCatalog', args: {} },
]

function fail(message) {
  process.stderr.write(`探针失败：${message}\n`)
  process.exit(2)
}

const rootArgument = process.argv[2]
if (rootArgument === undefined || !isAbsolute(rootArgument)) {
  fail('必须传入绝对研究缓存路径作为第一个参数。')
}
const root = resolve(rootArgument)

const origin = (process.env.HARNESS_ORIGIN ?? '').trim()
const token = (process.env.HARNESS_TOKEN ?? '').trim()
if (origin === '') fail('缺少 HARNESS_ORIGIN。')
if (token === '') fail('缺少 HARNESS_TOKEN。')

const marker = await readFile(join(root, RESEARCH_MARKER), 'utf8').catch(() => undefined)
if (marker === undefined || marker.trim() !== RESEARCH_MARKER_VALUE) {
  fail(`研究根目录缺少标记文件 ${RESEARCH_MARKER}，拒绝写入。`)
}

const base = origin.replace(/\/+$/, '')
const parsed = new URL(base)
if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
  fail('HARNESS_ORIGIN 只允许 http 或 https。')
}

let cookie = ''
const observations = []
const raw = {}

function note(label, detail) {
  observations.push({ label, detail })
}

// 认证：GET /?token=<token> 必须返回 303 并下发 Cookie。普通 API 不接受 Authorization 头。
async function authenticate() {
  const target = new URL(`${base}/`)
  target.searchParams.set('token', token)
  const response = await fetch(target, { redirect: 'manual' })
  if (response.status !== 303) {
    fail(`认证未返回 303，实际 status=${String(response.status)}。`)
  }
  const cookies = response.headers.getSetCookie?.() ?? []
  if (cookies.length === 0) fail('认证响应没有下发 Cookie。')
  cookie = cookies.map(value => value.split(';', 1)[0]).join('; ')
  note('auth', { status: response.status, cookieCount: cookies.length })
}

async function rpc(method, args) {
  const response = await fetch(`${base}/api/${method}`, {
    method: 'POST',
    headers: { Cookie: cookie, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `probe-${randomUUID()}`,
      method,
      payload: { args },
    }),
  })
  const text = await response.text()
  let decoded
  try {
    decoded = JSON.parse(text)
  } catch {
    return { status: response.status, envelope: undefined, note: 'body is not JSON' }
  }
  return { status: response.status, envelope: decoded }
}

// 只保留结构骨架：键名、类型、数组长度。绝不保留值。
function skeleton(value, depth = 0, maxDepth = 8) {
  if (depth >= maxDepth) return `<${kindOf(value)}>`
  if (Array.isArray(value)) {
    if (value.length === 0) return []
    const merged = {}
    let sawScalar = false
    for (const item of value.slice(0, 12)) {
      const shape = skeleton(item, depth + 1, maxDepth)
      if (shape !== null && typeof shape === 'object' && !Array.isArray(shape)) {
        for (const [key, entry] of Object.entries(shape)) merged[key] ??= entry
      } else {
        sawScalar = true
      }
    }
    if (Object.keys(merged).length > 0) return sawScalar ? ['<scalar>', merged] : [merged]
    return [kindOf(value[0])]
  }
  if (value !== null && typeof value === 'object') {
    const out = {}
    for (const key of Object.keys(value).sort()) out[key] = skeleton(value[key], depth + 1, maxDepth)
    return out
  }
  return kindOf(value)
}

function kindOf(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  return typeof value
}

async function probeRpc() {
  for (const { method, args } of READ_ONLY_RPC) {
    const { status, envelope } = await rpc(method, args)
    const entry = { method, status, resultOk: envelope?.result?.ok }
    if (envelope?.result?.ok === true) {
      entry.valueSkeleton = skeleton(envelope.result.value)
    } else if (envelope?.result?.ok === false) {
      entry.errorCode = envelope.result.error?.code
      entry.errorDetailsSkeleton = skeleton(envelope.result.error?.details ?? {})
    }
    raw[method] = entry
    note(`rpc ${method}`, entry)
  }
}

async function probeStream(endpoint, args, label, maxFrames) {
  const url = new URL(base)
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  url.pathname = MUX_PATH
  url.search = ''

  const socket = new WebSocket(url, { headers: { Cookie: cookie } })
  const frames = []
  const streamId = `probe-${endpoint.replaceAll('/', '-').replaceAll('$', '')}-${String(Date.now())}`

  await new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => { resolvePromise() }, 15000)
    socket.addEventListener('open', () => {
      socket.send(JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }))
    })
    socket.addEventListener('message', event => {
      let decoded
      try {
        decoded = JSON.parse(typeof event.data === 'string' ? event.data : '')
      } catch {
        return
      }
      if (decoded.streamId !== streamId) return
      const frameType = decoded.type
      if (frameType === 'error') {
        frames.push({ carrier: 'error', code: decoded.error?.code })
        clearTimeout(timer); resolvePromise(); return
      }
      if (frameType === 'end') {
        frames.push({ carrier: 'end' })
        clearTimeout(timer); resolvePromise(); return
      }
      frames.push({ carrier: 'item', valueSkeleton: skeleton(decoded.value) })
      if (frames.length >= maxFrames) {
        clearTimeout(timer); resolvePromise()
      }
    })
    socket.addEventListener('error', () => { clearTimeout(timer); rejectPromise(new Error(`${label} socket error`)) })
  }).catch(error => { note(`${label} error`, String(error)) })

  try { socket.send(JSON.stringify({ type: 'cancel', streamId })) } catch { /* 已关闭 */ }
  socket.close()
  raw[label] = frames
  note(`stream ${label}`, { frameCount: frames.length, carriers: frames.map(frame => frame.carrier) })
}

// 从 session/list 里取一个真实会话，用于只读 follow 与 page 探针。
async function firstSessionId() {
  const { envelope } = await rpc('session/list', { _request: {} })
  const items = envelope?.result?.value?.items
  if (!Array.isArray(items) || items.length === 0) return undefined
  const candidate = items.find(item => typeof item?.sessionId === 'string')
  return candidate?.sessionId
}

await authenticate()
await probeRpc()

const sessionId = await firstSessionId()
if (sessionId === undefined) {
  note('follow', '本机没有可见会话，跳过 follow/page 探针。')
} else {
  await probeStream(
    'session/follow',
    { request: { address: { kind: 'session', sessionId }, assistantStream: true, maxMessages: 50 } },
    'session/follow',
    8,
  )
  const { envelope } = await rpc('session/page', {
    request: { address: { kind: 'session', sessionId }, throughSeq: 0, maxMessages: 1 },
  })
  raw['session/page'] = {
    status: envelope?.result?.ok === true ? 200 : 200,
    resultOk: envelope?.result?.ok,
    valueSkeleton: envelope?.result?.ok === true ? skeleton(envelope.result.value) : undefined,
    errorCode: envelope?.result?.ok === false ? envelope.result.error?.code : undefined,
  }
  note('rpc session/page', raw['session/page'])
}

await probeStream('session/control', {}, 'session/control', 3)
await probeStream(ENDPOINT_EVENTS, {}, '$events', 3)

const report = {
  capturedAt: new Date().toISOString(),
  harnessOriginHost: parsed.host,
  readOnly: true,
  observations,
  skeletons: raw,
}

await mkdir(root, { recursive: true })
const output = join(root, `h00-probe-${Date.now()}.json`)
await writeFile(output, `${JSON.stringify(report, null, 2)}\n`, 'utf8')

process.stdout.write(`只读探针完成。骨架报告：${output}\n`)
process.stdout.write('报告只含结构骨架与错误码，不含 token、Cookie、真实路径、会话标识或正文。\n')
