---
name: setup
description: Onboarding for prune — prints what the plugin gives you, the exact statusLine snippet to wire into your Claude Code settings (so you see ctx-size + nudge in the status bar), whether the tmux auto-resume cycle is available in this session, and whether the optional prune-watch channel watcher is enabled. Run once after installing.
disable-model-invocation: true
allowed-tools: Bash(bash *) Bash(echo *) Bash(test *) Read
---

# prune setup

The operator just ran `/prune:setup`. Render the diagnostic block below verbatim (most values are already expanded by Claude Code), then walk them through the next steps based on what's currently configured.

---

## What you have (after installing prune)

- **`/prune:distill`** — operator-driven context prune. Reads this session's transcript, delegates bucketing to a fresh subagent, hands back a ranked toggle list, builds a seed brief for `/clear`. Always available.
- **`/prune:handover`** — lighter cousin of `/prune:distill`. No subagent, no transcript parsing — Claude writes the brief itself from already-loaded conversation context. Faster; use when you still remember the session.
- **`/prune:resume`** — the way back in after `/clear`: finds the newest brief on disk itself, absorbs it, moves it out of the repo, and carries on. No filename, no `@` picker — the one that works from a phone.
- **Auto-resume** — when claude runs inside a tmux pane, `/prune:handover` and `/prune:distill` arm a detached watcher that runs the `/clear` → `/prune:resume` cycle for you once the turn ends. Set `PRUNE_AUTO_RESUME=0` to opt out; the diagnostic below reports whether it's available here.
- **Statusline script** — a small bash script you can wire into Claude Code's `statusLine` setting. Shows `ctx Xk (Y%)` in your status bar; turns red with a `📋 ctx — /prune:distill or /prune:handover` nudge when context crosses the threshold. **This is the default nudge mechanism.** No background process, no MCP server, no extra launch flags.

## What the optional `prune-watch` plugin adds (only if separately installed)

- **MCP tools** under `plugin:prune-watch:prune-watch`:
  - `check` — force an immediate context-size check; returns current token estimate
  - `snooze` / `unsnooze` — silence/re-arm channel nudges
- **Channel server** — background process that watches the session transcript on disk and pushes a one-way `<channel>` nudge into the running session when context crosses ~200k tokens. Requires `--dangerously-load-development-channels plugin:prune-watch@prune-watch` at claude launch. **Most users don't need this** — the statusline is enough. Install it only if you specifically want a model-side nudge that interrupts the assistant's reply rather than a passive status-bar indicator.

---

## Diagnostic

### Statusline script path

- **Resolved path** (use in your settings.json `statusLine.command`): !`echo "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh"`
- **Exists**: !`test -f "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" && echo "yes" || echo "NO — plugin install may be incomplete"`

### Session diagnostics — channel watcher and auto-resume

!`bash ${CLAUDE_SKILL_DIR}/diagnose.sh ${CLAUDE_SESSION_ID}`

---

## What the operator should do next

Branch on what the diagnostic showed.

### Always — wire up the statusline (the default nudge mechanism)

Tell the operator to add this to their Claude Code `settings.json` (either `~/.claude/settings.json` for global or `.claude/settings.json` in this project). Substitute the resolved path from the diagnostic above:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash <RESOLVED-PATH-FROM-DIAGNOSTIC>"
  }
}
```

Then mention that:
- The statusline shows `ctx Xk (Y%)` in dim text by default.
- It turns yellow at ~70% of the threshold and bold-red with a nudge at 100%+.
- Threshold defaults to 200000 tokens; override with `PRUNE_THRESHOLD_TOKENS` env var.
- The script self-caches per transcript mtime, so it's fast.
- Restart Claude Code (or run `/config` and re-save) for the `statusLine` change to pick up.

### If the operator wants the optional channel-watcher plugin too

Branch on the **Channel status** value from the diagnostic.

#### If `prune-watch` plugin is not installed at all

Tell them:

> The channel watcher is a separate optional plugin. Install with:
> ```
> /plugin install prune-watch@prune-watch
> ```
> Then launch claude with the channel flag:
> ```
> claude --dangerously-load-development-channels plugin:prune-watch@prune-watch [your existing flags]
> ```
> Re-run `/prune:setup` to verify.

#### If `prune-watch` plugin is installed but channel status is `NOT ENABLED`

The watcher's MCP server runs, but Claude Code drops its notifications because the launch flag isn't set. Tell them:

> Add to your launcher (until prune-watch is on the official channel allowlist):
> ```
> claude --dangerously-load-development-channels plugin:prune-watch@prune-watch [your existing flags]
> ```
> **Do not also pass** `--channels plugin:prune-watch@prune-watch` — they're alternatives, not complements; passing both makes Claude Code skip notifications. Once prune-watch is approved, swap the dev flag for `--channels`.

Persistent vs one-off:
1. **Persistent (recommended)** — edit the launcher script that starts your claude session. The flags need to go on the actual `claude …` invocation, before `--resume`/`--session-id` if those are present. After editing, fully restart the session.
2. **One-off** — close this session and start a new one with the flags appended manually.

Don't auto-edit any launcher script. Different operators have very different setups; offer to look at theirs only if they ask.

#### If `prune-watch` plugin is installed and channel is ENABLED

Tell them: "You're fully set up — both the statusline indicator and the channel nudges are live. Run `/prune:distill` whenever context feels heavy, or wait for a nudge."

---

## Notes for you

- The diagnostic block above is rendered before you see this skill — values are already expanded into the prose. Don't re-run the bash commands; just read what's there and surface it.
- Most operators only need the statusline. Push the channel watcher only if they ask — it's an extra moving part.
- This skill is one-shot informational. Don't follow up with action unless the operator asks.
- If the operator's question is about pruning rather than setup, suggest `/prune:distill` (or `/prune:handover` for the lighter option) instead.
