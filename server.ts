#!/usr/bin/env bun
/**
 * prune-watch channel server.
 *
 * Watches the active session's transcript JSONL on disk. When the byte-count
 * crosses a token threshold, pushes a one-way nudge into the session
 * suggesting the operator run /prune-watch:prune.
 *
 * Exposes three tools so the operator (or Claude) can manage nudges:
 *   - snooze    silence further nudges this session
 *   - unsnooze  re-arm
 *   - check     force an immediate check; returns current token estimate
 *
 * State scratch lives at ~/.claude/channels/prune-watch/state.json so a
 * status-line script can read it.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import {
  readdirSync,
  readFileSync,
  readlinkSync,
  statSync,
  existsSync,
  mkdirSync,
  writeFileSync,
  watch,
  openSync,
  readSync,
  closeSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const STATE_DIR = join(homedir(), '.claude', 'channels', 'prune-watch')
const PROJECTS_DIR = join(homedir(), '.claude', 'projects')

mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })

// Tunables (env-overridable)
const THRESHOLD_TOKENS = intEnv('PRUNE_WATCH_THRESHOLD_TOKENS', 200_000)
const CONTEXT_WINDOW_TOKENS = intEnv('PRUNE_WATCH_CONTEXT_WINDOW', 1_000_000)
const BYTES_PER_TOKEN = intEnv('PRUNE_WATCH_BYTES_PER_TOKEN', 4)
const DEBOUNCE_MS = intEnv('PRUNE_WATCH_DEBOUNCE_MS', 30_000)
const MIN_PUSH_INTERVAL_MS = intEnv('PRUNE_WATCH_MIN_PUSH_INTERVAL_MS', 600_000)
const DISCOVERY_TIMEOUT_S = intEnv('PRUNE_WATCH_DISCOVERY_TIMEOUT_S', 600)

const SERVER_START_MS = Date.now()

// In-memory session state (lifecycle is the session — process exit on /quit)
let snoozed = false
let lastNudgeTokens = 0
let lastPushMs = 0
let transcriptPath: string | null = null

// --- MCP server setup -------------------------------------------------------

const mcp = new Server(
  { name: 'prune-watch', version: '0.2.11' },
  {
    capabilities: {
      experimental: { 'claude/channel': {} },
      tools: {},
    },
    instructions:
      'Events from prune-watch arrive as <channel source="prune-watch" tokens="..." pct="...">. ' +
      'These are one-way nudges that the operator\'s context window is filling up. ' +
      'CRITICAL — the operator cannot see channel tags directly. They only see your reply. ' +
      'When a prune-watch channel event arrives, your VERY NEXT user-visible reply MUST start with a one-line surfaced notice, on its own line, before anything else (including before answering whatever the operator just asked). Format: "📋 prune-watch: ~Xk tokens (Y%) — consider /prune-watch:prune." Then proceed to answer. ' +
      'After you have surfaced one notice, you do not need to repeat it on subsequent turns until a new prune-watch event arrives. ' +
      'If the operator says to silence them, call the snooze tool. ' +
      'Do not act on the nudge yourself by initiating /prune-watch:prune unprompted; pruning is operator-driven.',
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'snooze',
      description:
        'Silence further prune-watch nudges in the current session. State persists until the session ends or unsnooze is called.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'unsnooze',
      description: 'Re-arm prune-watch nudges in the current session.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'check',
      description:
        'Force an immediate prune-watch context check. Returns the current token estimate and whether a nudge was pushed.',
      inputSchema: { type: 'object', properties: {} },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name === 'snooze') {
    snoozed = true
    persistState()
    return text('prune-watch nudges silenced for this session.')
  }
  if (req.params.name === 'unsnooze') {
    snoozed = false
    persistState()
    return text('prune-watch nudges re-armed.')
  }
  if (req.params.name === 'check') {
    const result = await runCheck({ force: true })
    return text(JSON.stringify(result, null, 2))
  }
  throw new Error(`unknown tool: ${req.params.name}`)
})

await mcp.connect(new StdioServerTransport())

// MCP SDK's stdio transport doesn't propagate stdin EOF to process exit.
// When parent claude dies the pipe closes, but the watch() handle and other
// timers keep bun alive — the server then sticks around as a PPID 1 orphan.
// Exit explicitly on either signal.
process.stdin.on('end', () => process.exit(0))
process.stdin.on('close', () => process.exit(0))

// --- Transcript discovery & watching ---------------------------------------
//
// Claude Code does not pass us the session id or transcript path directly,
// but the channel server is spawned as a descendant of the claude process,
// which has `--resume <id>` or `--session-id <id>` in its argv. We walk
// /proc up the parent chain to find it. CWD comes from /proc/<pid>/cwd.
//
// With both pinned, the transcript path is deterministic; no mtime races.
// Falls through to narrower-to-wider heuristics when /proc is unavailable
// (non-Linux) or the parent claude was started without an explicit id.

const owner = findOwningSession()
log(
  owner.pid
    ? `owner: pid=${owner.pid} sessionId=${owner.sessionId?.slice(0, 8) ?? 'unknown'} cwd=${owner.cwd ?? 'unknown'}`
    : `owner: claude ancestor not found in /proc; falling back to blind mtime scan`,
)

// Namespace state by session id so concurrent sessions of the same user don't
// last-writer-wins-overwrite each other's scratch file. When session id can't
// be determined (Case C/D fallbacks), fall back to a sentinel filename — those
// degraded paths still collide, accepted limitation.
const STATE_FILE = join(
  STATE_DIR,
  owner.sessionId ? `state-${owner.sessionId}.json` : 'state-unknown.json',
)

let pollTimer: ReturnType<typeof setInterval> | null = null
let pollAttempts = 0

pollTimer = setInterval(() => {
  pollAttempts++
  const found = discoverTranscript(owner)
  if (found) {
    transcriptPath = found
    if (pollTimer) clearInterval(pollTimer)
    log(`locked transcript ${found}`)
    startWatching(found)
    persistState()
    runCheck({ force: false }).catch((e) => log(`initial check failed: ${e}`))
    // After locking, periodically check if /clear has spawned a newer jsonl in
    // the same project dir. If so, switch lock and reset push state so a fresh
    // nudge can fire on the new session.
    setInterval(maybeReDiscover, 30_000)
  } else if (!owner.sessionId && pollAttempts > DISCOVERY_TIMEOUT_S) {
    // Only time out in the blind-scan path. If we know the session id,
    // poll forever — the file will appear when the user types.
    if (pollTimer) clearInterval(pollTimer)
    log(
      `no transcript found in ${DISCOVERY_TIMEOUT_S}s; nudges disabled until restart`,
    )
    persistState({ status: 'no-transcript' })
  }
}, 1000)

type Owner = { pid: number | null; sessionId: string | null; cwd: string | null }

function findOwningSession(): Owner {
  // /proc is Linux-only. On macOS/Windows we'll fall back to the blind scan.
  if (process.platform !== 'linux') return { pid: null, sessionId: null, cwd: null }
  let pid = process.pid
  for (let i = 0; i < 8; i++) {
    let ppid: number | null = null
    try {
      const status = readFileSync(`/proc/${pid}/status`, 'utf8')
      const m = status.match(/^PPid:\s+(\d+)/m)
      if (m) ppid = parseInt(m[1], 10)
    } catch {
      return { pid: null, sessionId: null, cwd: null }
    }
    if (!ppid || ppid <= 1) return { pid: null, sessionId: null, cwd: null }
    pid = ppid

    let cmdline: string
    try {
      cmdline = readFileSync(`/proc/${pid}/cmdline`, 'utf8')
    } catch {
      continue
    }
    const argv = cmdline.split('\0').filter(Boolean)
    if (argv.length === 0) continue
    // Recognise claude by argv[0] basename.
    const exe = argv[0].split('/').pop() ?? ''
    if (exe !== 'claude' && !exe.startsWith('claude ')) continue

    // Extract session id from --resume <id> or --session-id <id>.
    let sessionId: string | null = null
    for (const flag of ['--resume', '--session-id']) {
      const idx = argv.indexOf(flag)
      if (idx > -1 && argv[idx + 1]) {
        sessionId = argv[idx + 1]
        break
      }
    }

    // Cwd from /proc symlink. Same uid required, which is true for our
    // own ancestor chain.
    let cwd: string | null = null
    try {
      cwd = readlinkSync(`/proc/${pid}/cwd`)
    } catch {}

    return { pid, sessionId, cwd }
  }
  return { pid: null, sessionId: null, cwd: null }
}

function encodeProjectDir(cwd: string): string {
  // Claude Code encodes cwd by replacing `/` with `-` (leading slash → leading dash).
  return cwd.replace(/\//g, '-')
}

function discoverTranscript(o: Owner): string | null {
  if (!existsSync(PROJECTS_DIR)) return null
  const projectDir = o.cwd ? encodeProjectDir(o.cwd) : null

  // Case A: known session id + project dir → exact path.
  if (o.sessionId && projectDir) {
    const exact = join(PROJECTS_DIR, projectDir, `${o.sessionId}.jsonl`)
    return existsSync(exact) ? exact : null
  }

  // Case B: known session id only → search by filename across project dirs.
  if (o.sessionId) {
    let projectDirs: string[]
    try {
      projectDirs = readdirSync(PROJECTS_DIR)
    } catch {
      return null
    }
    for (const proj of projectDirs) {
      const p = join(PROJECTS_DIR, proj, `${o.sessionId}.jsonl`)
      if (existsSync(p)) return p
    }
    return null
  }

  // Case C: known project dir only → newest jsonl in it (mtime-guarded).
  if (projectDir) {
    return newestJsonlIn(join(PROJECTS_DIR, projectDir))
  }

  // Case D: blind scan (last resort). Filter /tmp leftovers and require
  // mtime ≥ SERVER_START - 5s slack so a stale file mid-touch doesn't latch.
  let projectDirs: string[]
  try {
    projectDirs = readdirSync(PROJECTS_DIR)
  } catch {
    return null
  }
  let best: { path: string; mtime: number } | null = null
  const minMtime = SERVER_START_MS - 5_000
  for (const proj of projectDirs) {
    if (proj === '-tmp' || proj.startsWith('-tmp-')) continue
    let entries: string[]
    try {
      entries = readdirSync(join(PROJECTS_DIR, proj))
    } catch {
      continue
    }
    for (const f of entries) {
      if (!f.endsWith('.jsonl')) continue
      const p = join(PROJECTS_DIR, proj, f)
      let st
      try {
        st = statSync(p)
      } catch {
        continue
      }
      if (st.mtimeMs < minMtime) continue
      if (!best || st.mtimeMs > best.mtime) {
        best = { path: p, mtime: st.mtimeMs }
      }
    }
  }
  return best?.path ?? null
}

function newestJsonlIn(dir: string): string | null {
  let entries: string[]
  try {
    entries = readdirSync(dir)
  } catch {
    return null
  }
  let best: { path: string; mtime: number } | null = null
  const minMtime = SERVER_START_MS - 5_000
  for (const f of entries) {
    if (!f.endsWith('.jsonl')) continue
    const p = join(dir, f)
    let st
    try {
      st = statSync(p)
    } catch {
      continue
    }
    if (st.mtimeMs < minMtime) continue
    if (!best || st.mtimeMs > best.mtime) {
      best = { path: p, mtime: st.mtimeMs }
    }
  }
  return best?.path ?? null
}

let fileWatcher: ReturnType<typeof watch> | null = null
let watchDebounce: ReturnType<typeof setTimeout> | null = null

function startWatching(path: string) {
  // Re-entrant: close any prior watcher so we don't leak handles after a switch.
  if (fileWatcher) {
    try {
      fileWatcher.close()
    } catch {}
    fileWatcher = null
  }
  if (watchDebounce) {
    clearTimeout(watchDebounce)
    watchDebounce = null
  }
  try {
    fileWatcher = watch(path, () => {
      if (watchDebounce) clearTimeout(watchDebounce)
      watchDebounce = setTimeout(() => {
        runCheck({ force: false }).catch((e) => log(`check failed: ${e}`))
      }, DEBOUNCE_MS)
    })
  } catch (e) {
    log(`watch failed (${e}); falling back to 60s polling`)
    setInterval(() => {
      runCheck({ force: false }).catch(() => {})
    }, 60_000)
  }
}

// Detect /clear: every 30s, see if a newer jsonl has appeared in the same
// project dir. After /clear, claude spawns a fresh session id + new jsonl in
// the same project dir while the parent process keeps running; the parent's
// argv still points at the old --resume <id>, so we can't trust it. Project
// dir + newest mtime is the only signal.
function maybeReDiscover() {
  if (!transcriptPath || !owner.cwd) return
  const projectDir = encodeProjectDir(owner.cwd)
  const candidate = newestJsonlIn(join(PROJECTS_DIR, projectDir))
  if (!candidate || candidate === transcriptPath) return
  let cur, cand
  try {
    cand = statSync(candidate)
  } catch {
    return
  }
  try {
    cur = statSync(transcriptPath)
  } catch {
    cur = null
  }
  if (cur && cand.mtimeMs <= cur.mtimeMs) return
  log(`/clear detected — switching transcript: ${transcriptPath} -> ${candidate}`)
  transcriptPath = candidate
  lastNudgeTokens = 0
  lastPushMs = 0
  persistState()
  startWatching(candidate)
  runCheck({ force: false }).catch((e) => log(`post-switch check failed: ${e}`))
}

// --- Check + nudge ---------------------------------------------------------

type CheckResult = {
  tokens: number
  pct: number
  snoozed: boolean
  pushed: boolean
  reason?: string
}

async function runCheck({ force }: { force: boolean }): Promise<CheckResult> {
  if (!transcriptPath) {
    return { tokens: 0, pct: 0, snoozed, pushed: false, reason: 'no transcript yet' }
  }
  let st
  try {
    st = statSync(transcriptPath)
  } catch {
    return { tokens: 0, pct: 0, snoozed, pushed: false, reason: 'transcript missing' }
  }
  // Prefer the real input-token count from the most recent assistant message's
  // usage block. Falls back to bytes/4 only if no usage block can be found
  // (very early in a session, or non-standard transcript).
  const tokens =
    estimateTokensFromUsage(transcriptPath) ??
    Math.round(st.size / BYTES_PER_TOKEN)
  const pct = Math.round((tokens / CONTEXT_WINDOW_TOKENS) * 100)

  persistState({ tokens, pct, status: 'watching' })

  if (snoozed && !force) {
    return { tokens, pct, snoozed, pushed: false, reason: 'snoozed' }
  }
  if (tokens < THRESHOLD_TOKENS && !force) {
    return { tokens, pct, snoozed, pushed: false, reason: 'below threshold' }
  }
  // Time-based cooldown so pushes don't feedback-loop. Each surfaced nudge is
  // itself a transcript write, which triggers fs.watch, which would re-push.
  // Without this gate the model surfaces the nudge on every single reply.
  // 10 min default leaves plenty of room for one nudge to land + the operator
  // to either /prune-watch:prune, snooze, or ignore for a while.
  const sinceLastPush = Date.now() - lastPushMs
  if (!force && lastPushMs > 0 && sinceLastPush < MIN_PUSH_INTERVAL_MS) {
    return {
      tokens,
      pct,
      snoozed,
      pushed: false,
      reason: `cooldown (${Math.round((MIN_PUSH_INTERVAL_MS - sinceLastPush) / 1000)}s remaining)`,
    }
  }

  const content =
    `[ATTENTION ASSISTANT] prune-watch nudge: context at ~${tokens.toLocaleString()} tokens (~${pct}% of ${formatK(CONTEXT_WINDOW_TOKENS)}). ` +
    `Per the prune-watch channel instructions, surface a one-line "📋 prune-watch: ~${Math.round(tokens / 1000)}k tokens (${pct}%) — consider /prune-watch:prune." notice to the operator at the start of your next reply, then proceed with whatever they asked. ` +
    `If the operator wants nudges silenced, call the snooze tool.`

  try {
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content,
        meta: { tokens: String(tokens), pct: String(pct) },
      },
    })
    lastNudgeTokens = tokens
    lastPushMs = Date.now()
    log(`pushed nudge: tokens=${tokens} pct=${pct}`)
    return { tokens, pct, snoozed, pushed: true }
  } catch (e) {
    log(`push failed: ${e}`)
    return { tokens, pct, snoozed, pushed: false, reason: `push failed: ${e}` }
  }
}

// --- Helpers ---------------------------------------------------------------

// Read the tail of the JSONL and find the most recent assistant message's
// usage block. Sum input_tokens + cache_creation_input_tokens +
// cache_read_input_tokens — that's what Claude actually paid for on the
// last turn, and is what the model sees as "context size". Much more accurate
// than bytes/4, which counts all the JSONL metadata that never reaches the model.
function estimateTokensFromUsage(path: string): number | null {
  let st
  try {
    st = statSync(path)
  } catch {
    return null
  }
  // 256KB tail is plenty to find the most recent assistant usage block even in
  // very large transcripts; one entry is typically a few KB.
  const TAIL_BYTES = 256 * 1024
  const offset = Math.max(0, st.size - TAIL_BYTES)
  const length = st.size - offset
  if (length === 0) return null
  let buf: Buffer
  try {
    const fd = openSync(path, 'r')
    buf = Buffer.alloc(length)
    readSync(fd, buf, 0, length, offset)
    closeSync(fd)
  } catch {
    return null
  }
  const tail = buf.toString('utf8')
  const lines = tail.split('\n')
  // Skip the first line if we sliced mid-record.
  const startIdx = offset > 0 ? 1 : 0
  for (let i = lines.length - 1; i >= startIdx; i--) {
    const line = lines[i]
    if (!line.includes('"role":"assistant"')) continue
    if (!line.includes('"usage"')) continue
    let obj: any
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    const usage = obj?.message?.usage
    if (!usage) continue
    const input = usage.input_tokens ?? 0
    const cacheCreation = usage.cache_creation_input_tokens ?? 0
    const cacheRead = usage.cache_read_input_tokens ?? 0
    return input + cacheCreation + cacheRead
  }
  return null
}

function intEnv(name: string, fallback: number): number {
  const v = process.env[name]
  if (!v) return fallback
  const n = parseInt(v, 10)
  return Number.isFinite(n) && n > 0 ? n : fallback
}

function formatK(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(0)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

function text(t: string) {
  return { content: [{ type: 'text' as const, text: t }] }
}

function persistState(extra: Record<string, unknown> = {}) {
  try {
    writeFileSync(
      STATE_FILE,
      JSON.stringify(
        {
          transcript: transcriptPath,
          snoozed,
          lastNudgeTokens,
          thresholdTokens: THRESHOLD_TOKENS,
          contextWindowTokens: CONTEXT_WINDOW_TOKENS,
          updatedAt: new Date().toISOString(),
          ...extra,
        },
        null,
        2,
      ),
    )
  } catch {}
}

function log(msg: string) {
  process.stderr.write(`prune-watch: ${msg}\n`)
}

process.on('unhandledRejection', (err) => log(`unhandled rejection: ${err}`))
process.on('uncaughtException', (err) => log(`uncaught exception: ${err}`))
