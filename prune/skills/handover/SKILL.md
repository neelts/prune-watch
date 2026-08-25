---
name: handover
description: Generate a session handover brief before /clear. Distills session intent, completed work, latest actions, and next steps from live conversation context into a single markdown file the post-/clear session absorbs via `@`-mention — and, when claude runs inside a tmux pane, arms an auto-resume cycle that runs `/clear` and `/prune:resume` for the operator once this turn ends. Simplified cousin of /prune:distill — no subagent, no transcript bucketing; you write the brief yourself from what you already remember. Use when the operator invokes /prune:handover, or asks for a "handover", "carryover", or "session brief" before clearing.
disable-model-invocation: true
argument-hint: [focus hint, optional]
allowed-tools: Bash(echo *) Bash(test *) Bash(bash *) Read Write Edit
---

# /prune:handover — session handover brief

The operator wants to `/clear` the session but keep its load-bearing context. Your job: distill the session into a compact markdown file the post-`/clear` Claude can absorb via `@`-mention.

Unlike `/prune:distill`, there is **no subagent and no transcript parsing**. You do this yourself, from your already-loaded conversation context. You already remember the session — just write down what matters.

Session info (expanded before you see this):

- **Session ID**: `${CLAUDE_SESSION_ID}`
- **Handover file path** (workspace; project-tree autocomplete from `@.h<tab>`): !`echo ".handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Post-absorb destination** (where the post-`/clear` Claude moves it after reading): !`echo "${TMPDIR:-/tmp}/handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Operator hint**: `$ARGUMENTS`
- **Skill version** (baked into this file at write time): `0.5.1`
- **Plugin version on disk right now**: !`sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null | head -1`

Claude Code loads plugin skills **when the session starts**, so a long-running
session keeps executing the version it booted with. If those two versions differ,
you are running a stale copy of this skill: say so in one line at the end of your
hand-off — "this session loaded prune X, disk has Y; restart claude to pick up
the newer skill" — and carry on with the steps below regardless.

If `$ARGUMENTS` is non-empty, treat it as a focus hint — bias the brief toward that thread, but still cover the rest in brief.

## Step 1 — Distill from your live context

Look back over the session. Pull out, in this order:

1. **Intent** — What is the operator actually trying to accomplish? The high-level goal and the *why*. Not the latest tactical step.
2. **Completed work** — What is actually done. Files written/edited, decisions made, problems solved. Be specific: paths, function names, line refs where useful.
3. **Latest actions** — The most recent moves, including anything in flight, partially done, or waiting on the operator.
4. **Next steps** — What the post-`/clear` session should do first to keep momentum. Concrete and ordered.
5. **Gotchas** — Non-obvious constraints, ruled-out approaches, operator preferences, surprises. Anything not recoverable from `git log`, `git status`, or CLAUDE.md.

Skip anything already covered by CLAUDE.md, the code itself, or recent commits — the post-`/clear` session reads those fresh. The brief exists to carry what would otherwise *only* live in the conversation.

## Step 2 — Write the brief

Use `Write` with path = the **Handover file path** value from the session-info block. Shape:

````markdown
# Handover brief

Previous session distilled the following context. Treat this as your working memory.

## Intent

<one short paragraph: what we're doing, and why>

## Completed work

- <concrete done things, with `file:line` refs where useful>

## Latest actions

- <most recent moves; flag anything in-flight or partially done>

## Next steps

1. <first concrete action the next session should take>
2. <…>

## Gotchas

- <non-obvious constraints, ruled-out approaches, operator preferences>

---

<!-- handover absorb footer — keep verbatim, substitute the real paths -->
**After absorbing:** This brief lives at `<HANDOVER-PATH>` in the workspace. Move it out of the repo so it doesn't pollute git status: `mv <HANDOVER-PATH> <POST-ABSORB-PATH>`. The file survives in temp and is recoverable until system reboot — don't delete it.
````

Rules:

- Skip any section that has no content (don't write an empty heading).
- Don't pad. Don't invent. Only what the conversation actually contained.
- Keep it tight — aim for ~1–3k tokens. This is a seed, not a transcript replay.
- Substitute `<HANDOVER-PATH>` with the **Handover file path** value (e.g. `.handover-1f71f5fb.md`) and `<POST-ABSORB-PATH>` with the **Post-absorb destination** value (e.g. `/tmp/handover-1f71f5fb.md`) from the session-info block. Both share the same session-id slice.

## Step 3 — Arm the auto-resume cycle

The brief only pays off after a `/clear` and a `/prune:resume`. Both are user
commands typed into the input box — you cannot run either, and neither can the
model in the fresh session. But when claude runs inside a **tmux pane**, they can
be typed *from outside*, through the tmux server, once this turn ends. That is
what `auto-resume.sh` does: it forks a detached watcher, waits for your turn to
finish, sends `/clear`, waits a few seconds, sends `/prune:resume`.

Run it (substitute the real **Handover file path**):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto-resume.sh" arm --brief ".handover-XXXXXXXX.md"
```

If the operator gave a focus hint worth carrying into the resume, append
`--hint "<hint>"` — it becomes `/prune:resume <hint>`. Only pass a short,
quote-free hint; skip the flag otherwise rather than fight the shell quoting.

If `${CLAUDE_PLUGIN_ROOT}` reached you unexpanded and the path doesn't resolve,
locate the script once with `find ~/.claude/plugins -name auto-resume.sh 2>/dev/null | head -1`
and use that. If it isn't there either, skip this step and go straight to the
manual hand-off below — never let a missing script block the brief.

One tab-separated line comes back:

| output | meaning |
| --- | --- |
| `armed<TAB>PID<TAB>PANE<TAB>LOG` | the cycle will run by itself; `PID` is the abort handle |
| `skipped<TAB>not in a tmux pane` | no tmux (or no access to its server socket) — manual flow |
| `skipped<TAB>disabled by PRUNE_AUTO_RESUME=0` | operator opted out |
| `skipped<TAB>no --brief given` | you forgot the flag; re-run with it |

The watcher refuses to clear if the brief is missing or empty, or if the operator
has typed anything into the input box — so a half-written message is never
swallowed by a `/clear`, and a failed `Write` never costs a session its context.
A box that is merely mid-word gets 30 seconds to clear before that counts as an
abort, and ghost text (`<no suggestion>`, inline completions) is not input. Every
abort is logged and flashed on the pane's tmux status line, so a cycle that
doesn't run says why.

## Step 4 — Hand off

Print a short hand-off message — **NOT** the full brief, just the path and what happens next. The file IS the deliverable. Substitute the actual filename.

**If Step 3 printed `armed`**, the operator's job is to do nothing:

> Handover ready. Brief saved to `.handover-XXXXXXXX.md`.
>
> Auto-resume armed (pid `PID`): as soon as this turn ends I'll `/clear` this pane and run `/prune:resume` in the fresh session — it picks the brief up itself.
>
> To stop it: `kill PID`, or just start typing — the watcher aborts if the input box isn't empty.

**If Step 3 printed `skipped`**, fall back to the manual flow — say the auto-cycle was skipped and why, in half a line, then:

> Handover ready. Brief saved to `.handover-XXXXXXXX.md`.
>
> To apply:
> 1. Run `/clear` to reset the session.
> 2. Run `/prune:resume` — it finds this brief itself, no filename to type. (Or type `@.handover-XXXXXXXX.md` as your first message — the `@` picker autocompletes from `.handover-`. Claude Code injects the brief, then the absorb footer instructs the new session to move the file to `${TMPDIR:-/tmp}/` so it doesn't linger in the repo.) On mobile or remote clients prefer `/prune:resume` — the `@` picker is unreliable there.
>
> The moved file stays recoverable in temp until reboot — re-injectable from there if you need it again, or `rm` it any time.

Either way, do **not** try to run `/clear` yourself as a tool call — it's a client-side command, and the armed watcher is the only thing that gets to type it. Keep this message short; every token you spend here is context the cycle is about to throw away anyway.

## Notes for you

- Lead with **Intent**. If the next session reads only one section, that's the one.
- Concrete beats abstract. "Refactor `server/auth/middleware.ts:42` to drop JWT in favor of express-session" beats "improve auth".
- Don't summarize this skill's behavior to the operator before doing it. Just do it.
- If the session is genuinely trivial (one Q&A, no state worth carrying), say so to the operator and skip writing the file rather than producing a brief that says "nothing happened". **Do not arm the auto-resume cycle in that case** — there is nothing to resume into, and clearing would just cost the operator their session for free.
- Once armed, this turn's remaining output is disposable: the pane clears seconds after you stop. Don't append further work, don't start a new task, don't ask a follow-up question the operator won't get to answer.
