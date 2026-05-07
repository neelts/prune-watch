# prune-watch

Operator-guided context tools for [Claude Code](https://code.claude.com) — the golden ratio between `/clear` and `/compact`.

`/compact` is lossy and direction-blind, and runs at the context ceiling when the model is already degraded. `/clear` with a hand-written brief is precise but high-effort. **This marketplace gives you two pluggable middle paths** plus a passive nudge so you remember to use them.

## What's in the marketplace

Two plugins, install whichever you need:

### `prune` — the everyday plugin (recommended; install this one)

- **`/prune:distill`** — read this session's transcript, delegate bucketing to a fresh Haiku subagent (`transcript-bucketer`), present a ranked toggle list (`NEW` vs `DOC` axis based on whether the bucket's content is already in your CLAUDE.md), let you accept/customize/cancel via dialog, write a seed brief to `<cwd>/.prune-handover-<sid>.md`. After `/clear` you inject the brief by typing `@.prune-handover-<sid>.md`; the post-`/clear` Claude reads it, then moves the file to `${TMPDIR:-/tmp}/` so it doesn't pollute the repo (recoverable until reboot).
- **`/prune:handover`** — simpler cousin of `/prune:distill`. No subagent, no transcript bucketing — Claude writes the brief itself from already-loaded conversation context, straight to `<cwd>/.handover-<sid>.md`. Same `@`-mention re-injection flow. Optional focus hint: `/prune:handover focus on the auth refactor`.
- **`/prune:setup`** — onboarding diagnostic. Prints what's installed and the exact `statusLine` snippet to wire up the in-status-bar nudge.
- **Statusline script** (`prune/scripts/statusline.sh`) — reads the active session's transcript, computes `input + cache_creation + cache_read` from the latest assistant message's `usage` block (same number `/context` shows), and emits a colored one-liner: dim under threshold, yellow at ~70%, bold-red with `📋 ctx Xk (Y%) — /prune:distill or /prune:handover` above. No background process, no MCP server, no extra launch flags. Wire it into your `settings.json` (`/prune:setup` prints the exact path).

### `prune-watch` — the optional channel watcher

- **Channel server (`watcher/server.ts`)** — runs as an MCP subprocess. Watches the active session's JSONL on disk, estimates token count from the latest assistant message's `usage` block, pushes a `<channel source="prune-watch">` event when context grows past 200k tokens. Combined cooldown (10 min AND +100k tokens) prevents spam. Surfaces as a one-line notice prepended to the assistant's next reply.
- **MCP tools** under `plugin:prune-watch:prune-watch`:
  - `check` — force an immediate context-size check; returns the current token estimate.
  - `snooze` — silence further nudges. Optional `seconds` arg for time-bounded snooze (auto-expires); without args, indefinite.
  - `unsnooze` — re-arm immediately.
- Requires `--dangerously-load-development-channels plugin:prune-watch@prune-watch` at claude launch (until prune-watch is on the official channel allowlist).

**Most users don't need the watcher.** The statusline gives you the same signal passively, in your status bar, with zero process cost and no launch flags. Install `prune-watch` only if you specifically want a model-side nudge that injects into the assistant's reply rather than a passive indicator.

## When to use what

| You want… | Reach for | Why |
| --- | --- | --- |
| A long, branchy session distilled before `/clear` (you've lost track of what's load-bearing) | `/prune:distill` | Fresh subagent buckets the transcript; you only have to toggle. Best when the session is too big to remember, or context is already degraded. |
| A quick brief from a still-fresh session (you remember roughly what happened) | `/prune:handover` | No subagent overhead, no transcript parsing — Claude writes from live memory. Faster, cheaper, no Haiku call. Use when you'd be embarrassed to spin up a bucketer for what's basically two threads of work. |
| Passive awareness of context size while you work | Statusline (in `prune`) | Always-on `ctx Xk (Y%)` indicator. Color shift + nudge text once you cross threshold. Doesn't interrupt the model. |
| An aggressive "the model just told me to prune" nudge | The optional `prune-watch` plugin (channel server) | One-way nudge that the model is required to surface in its next reply. More attention-grabbing than the status bar. |
| `/prune:distill` is mid-flight and you don't want a channel nudge interrupting | (nothing — it auto-snoozes for 15 min when the watcher is installed) | The skill calls the snooze tool automatically when present, no-ops gracefully when absent. |

Rule of thumb: **install `prune` and wire the statusline.** Add `prune-watch` only if the statusline isn't aggressive enough for your workflow.

## How a typical session flows

1. You're working in claude with the statusline wired up. Status bar shows `ctx 80k (8%)` in dim text.
2. Context crosses ~70% of threshold (default 140k). Status bar turns yellow: `ctx 145k (15%)`.
3. Context crosses threshold (default 200k). Status bar turns bold-red: `📋 ctx 210k (21%) — /prune:distill or /prune:handover`.
4. You decide: do you remember the session well enough?
   - Yes → run `/prune:handover` with an optional focus hint. Brief written; you `/clear` and `@.handover-<sid>.md`.
   - No → run `/prune:distill`. Skill auto-snoozes the channel for 15 minutes (if the watcher's installed), delegates to `transcript-bucketer`, prints a ranked toggle list:
     ```
     Prune proposal — ctx ~210k tokens, 8 buckets
     CLAUDE.md cross-checked: /path/to/CLAUDE.md

       [x] 1. NEW HIGH  decisions      — auth middleware refactor (42k)
              chose express-session over JWT, legal/compliance
       [x] 2. NEW MED   open-threads   — Redis migration pending (12k)
       [ ] 3. DOC HIGH  files-touched  — server/auth/* (28k)  ← already in CLAUDE.md
       ...
     ```
5. The skill prompts (via `AskUserQuestion` or plain-text fallback): `Accept` / `Accept & note` / `Customize` / `Cancel`. `Accept & note` additionally appends the kept `NEW` buckets to your CLAUDE.md as a dated session-notes block you can curate later.
6. You pick `Accept`. Brief is written to `.prune-handover-1f71f5fb.md` (named after the first 8 chars of your session id).
7. You run `/clear`, then type `@.prune-handover-1f71f5fb.md`. The fresh Claude reads the brief, then moves the file to `/tmp/` per the absorb footer.
8. You're back to work with exactly the context you kept.

## Installation

### Option 1 — local marketplace (the dogfooding shape)

For testing, or running the plugins on a machine where the repo is checked out:

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
    "prune@prune-watch": true
  }
}
```

Or install globally:

```
/plugin marketplace add /absolute/path/to/prune-watch
/plugin install prune@prune-watch
```

To also enable the optional channel watcher:

```
/plugin install prune-watch@prune-watch
```

### Option 2 — from GitHub

```
/plugin marketplace add neelts/prune-watch
/plugin install prune@prune-watch
/reload-plugins
```

Channel watcher (optional):

```
/plugin install prune-watch@prune-watch
```

### Wiring the statusline (the default nudge mechanism)

Run `/prune:setup` and copy the snippet it prints. Or add this to your Claude Code `settings.json` (`~/.claude/settings.json` for global, `.claude/settings.json` for project), substituting the absolute path the setup skill gave you:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /absolute/path/to/prune/scripts/statusline.sh"
  }
}
```

Optional env tunables (set them on the claude process or in the statusLine command line):

| var | default | meaning |
| --- | --- | --- |
| `PRUNE_THRESHOLD_TOKENS` | `200000` | red nudge fires above this |
| `PRUNE_WARN_RATIO` | `0.7` | yellow band starts at this fraction of threshold |
| `PRUNE_CONTEXT_WINDOW` | `1000000` | total ctx for the percentage column |
| `PRUNE_QUIET_BELOW_TOKENS` | `0` | print nothing under this many tokens (use to keep the bar clean early-session) |
| `PRUNE_NO_COLOR` | unset | disable ANSI colors |

Restart Claude Code (or re-save settings via `/config`) for the `statusLine` change to pick up.

### Enabling the optional channel (proactive model-side nudges)

The `prune` plugin works fully without the channel — the statusline IS the nudge. The watcher adds an additional, more-aggressive signal: a one-way `<channel>` event that the model is instructed to surface in its next assistant reply.

If you want that, install the watcher and pass the channel flag at claude launch:

```
claude --dangerously-load-development-channels plugin:prune-watch@prune-watch [your existing flags]
```

**Don't also pass `--channels plugin:prune-watch@prune-watch`** — the two flags are alternatives, not complements; passing both makes Claude Code skip notifications. Once prune-watch is approved, swap the dev flag for `--channels`.

To verify, run `/prune:setup` in any session — it'll tell you whether channels are active and what to add if not.

## Configuration

### Statusline (in `prune`)

See the env-var table above.

### Channel watcher (in `prune-watch`)

All env vars, all optional:

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

- **Channel server pins to its parent claude's argv session id.** Never auto-switches. After `/clear`, this server's watch goes silent until you restart claude. This trade-off was deliberate — auto-switching to the newest jsonl in the project dir let sibling sessions in the same workspace poach each other's transcripts and double-push. (The statusline doesn't have this problem because Claude Code passes it `transcript_path` directly on every invocation.)
- **Linux-only `/proc` walk for channel discovery.** The discovery uses `/proc/<pid>/cmdline` and `/proc/<pid>/cwd` to find the parent claude. Non-Linux falls through to a heuristic blind scan of project dirs (with `/tmp/` filtered to avoid stale leftovers). The statusline works on macOS (uses `stat -f` fallback).
- **Plain-text token estimator (with a real fallback).** Both the statusline and the channel server read the most recent assistant message's `usage` block (`input + cache_creation + cache_read`) — same number `/context` shows. Statusline falls back to coarse grep math if `jq` isn't on PATH; server falls back to bytes ÷ 4 only if no usage block can be found yet.
- **No automatic CLAUDE.md mutation.** The `Accept & note` option in `/prune:distill` is opt-in and appends a clearly-marked block at the end of CLAUDE.md, never modifies existing content. You curate the block when you have time.

## Repo layout

```
prune-watch/                       # marketplace root (this GitHub repo)
├── .claude-plugin/
│   └── marketplace.json           # lists prune + prune-watch plugins
├── README.md
├── CLAUDE.md
├── prune/                     # main plugin: skills + statusline
│   ├── .claude-plugin/
│   │   └── plugin.json
│   ├── skills/
│   │   ├── prune/SKILL.md         # /prune:distill orchestrator
│   │   ├── handover/SKILL.md      # /prune:handover bucketer-free brief
│   │   └── setup/
│   │       ├── SKILL.md           # /prune:setup onboarding diagnostic
│   │       └── diagnose.sh        # state.json + channel-flag detection
│   ├── agents/
│   │   └── transcript-bucketer.md # the Haiku subagent /prune:distill calls
│   └── scripts/
│       └── statusline.sh          # the in-status-bar context indicator
└── watcher/                       # optional plugin: channel watcher
    ├── .claude-plugin/
    │   └── plugin.json
    ├── .mcp.json                  # spawns the channel server
    ├── server.ts                  # fs.watch + token estimate + push
    ├── package.json
    └── bun.lock
```

## Acknowledgements

Concept seed from [Thariq's post on session management & 1M context](https://x.com/trq212/status/2044548257058328723). Channels mechanics are documented at [code.claude.com/docs/en/channels](https://code.claude.com/docs/en/channels). Statusline contract: [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline).
