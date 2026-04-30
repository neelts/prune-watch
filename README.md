# prune-watch

Operator-guided context pruning for [Claude Code](https://code.claude.com) — the golden ratio between `/clear` and `/compact`.

`/compact` is lossy and direction-blind, and it runs at the context ceiling when the model is already degraded. `/clear` with a hand-written brief is precise but high-effort. **prune-watch** sits between them: a fresh subagent buckets your session transcript while it's still sharp, you toggle which buckets to keep, and a seed brief is written to disk so the next session starts with exactly the context you chose — nothing else.

A separate channel server watches the transcript on disk and pings you when context grows past a threshold so you don't have to remember to prune.

## What you get

- **`/prune-watch:prune`** — read this session's transcript, delegate bucketing to a fresh Haiku subagent (`transcript-bucketer`), present a ranked toggle list (`NEW` vs `DOC` axis based on whether the bucket's content is already in your CLAUDE.md), let you accept/customize/cancel via dialog, write a seed brief to `<cwd>/.prune-handover-<sid>.md`. After `/clear` you inject the brief by typing `@.prune-handover-<sid>.md`; the post-`/clear` Claude reads it, then moves the file to `${TMPDIR:-/tmp}/` so it doesn't pollute the repo (recoverable until reboot).
- **`/prune-watch:setup`** — onboarding diagnostic. Tells you what's installed, whether the channel is enabled in this session, and exactly what flag to add to your launcher if not.
- **MCP tools** under `plugin:prune-watch:prune-watch`:
  - `check` — force an immediate context-size check; returns the current token estimate.
  - `snooze` — silence further nudges. Accepts an optional `seconds` arg for time-bounded snooze (auto-expires); without args, indefinite.
  - `unsnooze` — re-arm immediately.
- **Channel server (`server.ts`)** — runs as an MCP subprocess. Watches the active session's JSONL on disk, estimates token count from the latest assistant message's `usage` block, pushes a `<channel source="prune-watch">` event when context grows past 200k tokens. Combined cooldown (10 min AND +100k tokens) prevents spam.

## How a typical session flows

1. You're working in claude. Channel watches your transcript silently.
2. Context crosses ~200k tokens → channel pushes a nudge → on your next assistant turn, the reply opens with: `📋 prune-watch: ~210k tokens (21%) — consider /prune-watch:prune.`
3. You run `/prune-watch:prune`. The skill auto-snoozes for 15 minutes, delegates to `transcript-bucketer`, prints a ranked toggle list:
   ```
   Prune proposal — ctx ~210k tokens, 8 buckets
   CLAUDE.md cross-checked: /path/to/CLAUDE.md

     [x] 1. NEW HIGH  decisions      — auth middleware refactor (42k)
            chose express-session over JWT, legal/compliance
     [x] 2. NEW MED   open-threads   — Redis migration pending (12k)
     [ ] 3. DOC HIGH  files-touched  — server/auth/* (28k)  ← already in CLAUDE.md
     ...
   ```
4. The skill prompts (via `AskUserQuestion` or plain-text fallback): `Accept` / `Accept & note` / `Customize` / `Cancel`. `Accept & note` additionally appends the kept `NEW` buckets to your CLAUDE.md as a dated session-notes block you can curate later.
5. You pick `Accept`. Brief is written to `.prune-handover-1f71f5fb.md` (the file's named after the first 8 chars of your session id).
6. You run `/clear`, then type `@.prune-handover-1f71f5fb.md`. The fresh Claude reads the brief, then moves the file to `/tmp/` per the absorb footer.
7. You're back to work with exactly the context you kept.

## Installation

### Option 1 — local marketplace (the dogfooding shape)

For testing or running prune-watch on a machine where the repo is checked out:

```bash
git clone https://github.com/neelts/prune-watch.git ~/Dev/prune-watch
```

Per-project enablement via `.claude/settings.local.json`:

```json
{
  "extraKnownMarketplaces": {
    "prune-watch": {
      "source": { "source": "directory", "path": "/absolute/path/to/prune-watch" }
    }
  },
  "enabledPlugins": {
    "prune-watch@prune-watch": true
  }
}
```

Or install globally:

```
/plugin marketplace add /absolute/path/to/prune-watch
/plugin install prune-watch@prune-watch
```

### Option 2 — from GitHub

```
/plugin marketplace add neelts/prune-watch
/plugin install prune-watch@prune-watch
/reload-plugins
```

### Enabling the channel (proactive nudges)

The plugin's skills work out of the box once installed. The **channel** half — the proactive nudges — needs an additional flag at claude launch. Until prune-watch is on the official Anthropic channel allowlist, that flag is:

```
claude --dangerously-load-development-channels plugin:prune-watch@prune-watch [your existing flags]
```

**Don't also pass `--channels plugin:prune-watch@prune-watch`** — the two flags are alternatives, not complements; passing both makes Claude Code skip notifications. Once prune-watch is approved, swap the dev flag for `--channels`.

To verify, run `/prune-watch:setup` in any session — it'll tell you whether channels are active and what to add if not.

## Configuration

Channel server tunables (all env vars, all optional):

| var | default | meaning |
| --- | --- | --- |
| `PRUNE_WATCH_THRESHOLD_TOKENS` | `200000` | nudge fires when transcript usage crosses this |
| `PRUNE_WATCH_CONTEXT_WINDOW` | `1000000` | total context window the percentage is computed against |
| `PRUNE_WATCH_DEBOUNCE_MS` | `30000` | wait this long after the last fs.watch event before checking |
| `PRUNE_WATCH_MIN_PUSH_INTERVAL_MS` | `600000` | minimum time between pushes (combined with token-delta below) |
| `PRUNE_WATCH_RENUDGE_DELTA_TOKENS` | `100000` | minimum token growth between pushes (combined with time interval) |
| `PRUNE_WATCH_BYTES_PER_TOKEN` | `4` | fallback estimator when the JSONL has no `usage` blocks yet |
| `PRUNE_WATCH_DISCOVERY_TIMEOUT_S` | `600` | give up looking for the transcript after this long (only applies when session id is unknown) |

## Known design choices and limitations

- **Channel server pins to its parent claude's argv session id.** Never auto-switches. After `/clear`, this server's watch goes silent until you restart claude. This trade-off was deliberate — auto-switching to the newest jsonl in the project dir let sibling sessions in the same workspace poach each other's transcripts and double-push.
- **Linux-only `/proc` walk.** The discovery uses `/proc/<pid>/cmdline` and `/proc/<pid>/cwd` to find the parent claude. Non-Linux falls through to a heuristic blind scan of project dirs (with `/tmp/` filtered to avoid stale leftovers).
- **Plain-text token estimator (with a real fallback).** Default reads the most recent assistant message's `usage` block (`input + cache_creation + cache_read`) — same number `/context` shows. Falls back to bytes ÷ 4 only if no usage block can be found yet.
- **No automatic CLAUDE.md mutation.** The `Accept & note` option is opt-in and appends a clearly-marked block at the end of CLAUDE.md, never modifies existing content. You curate the block when you have time.

## Repo layout

```
prune-watch/
├── .claude-plugin/
│   ├── plugin.json          # plugin manifest
│   └── marketplace.json     # single-plugin marketplace
├── .mcp.json                # spawns the channel server
├── server.ts                # the channel: fs.watch + token estimate + push
├── package.json
├── skills/
│   ├── prune/
│   │   ├── SKILL.md         # /prune-watch:prune orchestrator
│   │   └── banner.sh        # channel-status one-liner for the skill body
│   └── setup/
│       ├── SKILL.md         # /prune-watch:setup onboarding diagnostic
│       └── diagnose.sh      # state.json + channel detection
├── agents/
│   └── transcript-bucketer.md   # the Haiku subagent that does the real work
└── CLAUDE.md
```

## Acknowledgements

Concept seed from [Thariq's post on session management & 1M context](https://x.com/trq212/status/2044548257058328723). Channels mechanics are documented at [code.claude.com/docs/en/channels](https://code.claude.com/docs/en/channels).
