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
  statSync,
  existsSync,
  mkdirSync,
  writeFileSync,
  watch,
} from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const STATE_DIR = join(homedir(), '.claude', 'channels', 'prune-watch')
const STATE_FILE = join(STATE_DIR, 'state.json')
const PROJECTS_DIR = join(homedir(), '.claude', 'projects')

mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })

// Tunables (env-overridable)
const THRESHOLD_TOKENS = intEnv('PRUNE_WATCH_THRESHOLD_TOKENS', 200_000)
const CONTEXT_WINDOW_TOKENS = intEnv('PRUNE_WATCH_CONTEXT_WINDOW', 1_000_000)
const BYTES_PER_TOKEN = intEnv('PRUNE_WATCH_BYTES_PER_TOKEN', 4)
const DEBOUNCE_MS = intEnv('PRUNE_WATCH_DEBOUNCE_MS', 30_000)
const RENUDGE_DELTA_TOKENS = intEnv('PRUNE_WATCH_RENUDGE_DELTA', 50_000)
const DISCOVERY_TIMEOUT_S = intEnv('PRUNE_WATCH_DISCOVERY_TIMEOUT_S', 600)

const SERVER_START_MS = Date.now()

// In-memory session state (lifecycle is the session — process exit on /quit)
let snoozed = false
let lastNudgeTokens = 0
let transcriptPath: string | null = null

// --- MCP server setup -------------------------------------------------------

const mcp = new Server(
  { name: 'prune-watch', version: '0.2.0' },
  {
    capabilities: {
      experimental: { 'claude/channel': {} },
      tools: {},
    },
    instructions:
      'Events from prune-watch arrive as <channel source="prune-watch" tokens="..." pct="...">. ' +
      'These are one-way nudges that the operator\'s context is getting heavy. ' +
      'Surface the nudge to the operator verbatim (or paraphrased) and recommend running /prune-watch:prune. ' +
      'If the operator says to silence them, call the snooze tool. ' +
      'Do not act on the nudge yourself; pruning is operator-driven.',
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

// --- Transcript discovery & watching ---------------------------------------
//
// Claude Code does not pass us the active session id or transcript path.
// We discover by scanning ~/.claude/projects for the JSONL whose mtime
// crosses our startup time. Whichever appears first is "ours" — it's the
// session that just typed something while we were the only new server.
// Multiple concurrent sessions confuse this; that's a known limitation.

let pollTimer: ReturnType<typeof setInterval> | null = null
let pollAttempts = 0

pollTimer = setInterval(() => {
  pollAttempts++
  const found = discoverTranscript()
  if (found) {
    transcriptPath = found
    if (pollTimer) clearInterval(pollTimer)
    log(`locked transcript ${found}`)
    startWatching(found)
    persistState()
    runCheck({ force: false }).catch((e) => log(`initial check failed: ${e}`))
  } else if (pollAttempts > DISCOVERY_TIMEOUT_S) {
    if (pollTimer) clearInterval(pollTimer)
    log(
      `no transcript found in ${DISCOVERY_TIMEOUT_S}s; nudges disabled until restart`,
    )
    persistState({ status: 'no-transcript' })
  }
}, 1000)

function discoverTranscript(): string | null {
  if (!existsSync(PROJECTS_DIR)) return null
  let best: { path: string; mtime: number } | null = null
  let projectDirs: string[]
  try {
    projectDirs = readdirSync(PROJECTS_DIR)
  } catch {
    return null
  }
  for (const proj of projectDirs) {
    const dir = join(PROJECTS_DIR, proj)
    let entries: string[]
    try {
      entries = readdirSync(dir)
    } catch {
      continue
    }
    for (const f of entries) {
      if (!f.endsWith('.jsonl')) continue
      const p = join(dir, f)
      let st
      try {
        st = statSync(p)
      } catch {
        continue
      }
      if (st.mtimeMs < SERVER_START_MS) continue
      if (!best || st.mtimeMs > best.mtime) {
        best = { path: p, mtime: st.mtimeMs }
      }
    }
  }
  return best?.path ?? null
}

function startWatching(path: string) {
  let debounceTimer: ReturnType<typeof setTimeout> | null = null
  try {
    watch(path, () => {
      if (debounceTimer) clearTimeout(debounceTimer)
      debounceTimer = setTimeout(() => {
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
  const tokens = Math.round(st.size / BYTES_PER_TOKEN)
  const pct = Math.round((tokens / CONTEXT_WINDOW_TOKENS) * 100)

  persistState({ tokens, pct, status: 'watching' })

  if (snoozed && !force) {
    return { tokens, pct, snoozed, pushed: false, reason: 'snoozed' }
  }
  if (tokens < THRESHOLD_TOKENS && !force) {
    return { tokens, pct, snoozed, pushed: false, reason: 'below threshold' }
  }
  if (!force && tokens < lastNudgeTokens + RENUDGE_DELTA_TOKENS) {
    return { tokens, pct, snoozed, pushed: false, reason: 'cooldown' }
  }

  const content =
    `Context at ~${tokens.toLocaleString()} tokens (~${pct}% of ${formatK(CONTEXT_WINDOW_TOKENS)}). ` +
    `Run /prune-watch:prune to bucket and prune the session, or call the snooze tool to silence further nudges.`

  try {
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content,
        meta: { tokens: String(tokens), pct: String(pct) },
      },
    })
    lastNudgeTokens = tokens
    return { tokens, pct, snoozed, pushed: true }
  } catch (e) {
    log(`push failed: ${e}`)
    return { tokens, pct, snoozed, pushed: false, reason: `push failed: ${e}` }
  }
}

// --- Helpers ---------------------------------------------------------------

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
