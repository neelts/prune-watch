---
name: setup
description: Onboarding for prune-watch — prints what the plugin gives you, whether the proactive-nudge channel is enabled in this session, and the exact launch flags to enable it if not. Run once after installing.
disable-model-invocation: true
allowed-tools: Bash(bash *) Read
---

# prune-watch setup

The operator just ran `/prune-watch:setup`. Render the diagnostic below verbatim (the values are already expanded), then give them the right next step depending on the channel-status section.

---

## What you have

- **Skill** `/prune-watch:prune` — operator-driven context prune. Reads this session's transcript, delegates bucketing to a fresh subagent, hands back a ranked toggle list, builds a seed brief for `/clear`. Always available.
- **MCP tools** (visible in `/mcp` under `plugin:prune-watch:prune-watch`):
  - `check` — force an immediate context-size check; returns current token estimate
  - `snooze` — silence further nudges in the current session
  - `unsnooze` — re-arm
- **Channel server** — background process that watches the session transcript on disk and pushes a one-way nudge into the session when context crosses ~200k tokens. **Requires `--channels` to actually deliver nudges** (see below).

!`bash ${CLAUDE_SKILL_DIR}/diagnose.sh ${CLAUDE_SESSION_ID}`

---

## What the operator should do next

Branch on the **Channel status** value above:

### If status is ENABLED

Tell the operator briefly: "You're fully set up. Run `/prune-watch:prune` whenever context feels heavy, or wait for a nudge — they'll surface in the assistant's reply when the threshold is crossed." Stop.

### If status is NOT ENABLED

Tell the operator that to turn on proactive nudges, the claude binary needs two extra flags at launch:

```
claude --channels plugin:prune-watch@prune-watch \
       --dangerously-load-development-channels plugin:prune-watch@prune-watch \
       [their existing flags]
```

The `--dangerously-load-development-channels` flag is required only because prune-watch isn't on the official Anthropic channel allowlist yet — it can be dropped once approved.

Then explain the two common ways to add those flags:

1. **Persistent (recommended)** — edit the launcher script that starts their claude session. Where this lives depends on their setup (e.g. tmux/systemd/login script). The flags need to go on the actual `claude …` invocation, before `--resume`/`--session-id` if those are present. After editing, fully restart the session (kill the parent claude process and let the supervisor respawn it, or close and reopen the terminal).
2. **One-off** — close this session and start a new one with the flags appended manually. Faster to test but doesn't persist.

Tell them they can verify it worked by re-running `/prune-watch:setup` — Channel status should flip to ENABLED.

Don't auto-edit any launcher script. Different operators have very different setups; offer to look at theirs only if they ask.

---

## Notes for you

- The diagnostic block above is rendered before you see this skill — values are already expanded into the prose. Don't re-run the bash commands; just read what's there and surface it.
- This skill is one-shot informational. Don't follow up with action unless the operator asks.
- If the operator's question is about pruning rather than setup, suggest `/prune-watch:prune` instead.
