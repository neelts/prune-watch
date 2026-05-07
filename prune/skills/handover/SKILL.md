---
name: handover
description: Generate a session handover brief before /clear. Distills session intent, completed work, latest actions, and next steps from live conversation context into a single markdown file the post-/clear session absorbs via `@`-mention. Simplified cousin of /prune:distill — no subagent, no transcript bucketing; you write the brief yourself from what you already remember. Use when the operator invokes /prune:handover, or asks for a "handover", "carryover", or "session brief" before clearing.
disable-model-invocation: true
argument-hint: [focus hint, optional]
allowed-tools: Bash(echo *) Bash(test *) Read Write Edit
---

# /prune:handover — session handover brief

The operator wants to `/clear` the session but keep its load-bearing context. Your job: distill the session into a compact markdown file the post-`/clear` Claude can absorb via `@`-mention.

Unlike `/prune:distill`, there is **no subagent and no transcript parsing**. You do this yourself, from your already-loaded conversation context. You already remember the session — just write down what matters.

Session info (expanded before you see this):

- **Session ID**: `${CLAUDE_SESSION_ID}`
- **Handover file path** (workspace; project-tree autocomplete from `@.h<tab>`): !`echo ".handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Post-absorb destination** (where the post-`/clear` Claude moves it after reading): !`echo "${TMPDIR:-/tmp}/handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Operator hint**: `$ARGUMENTS`

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

## Step 3 — Hand off

Print a short hand-off message — **NOT** the full brief, just the path and instructions. The file IS the deliverable. Substitute the actual filename:

> Handover ready. Brief saved to `.handover-XXXXXXXX.md`.
>
> To apply:
> 1. Run `/clear` to reset the session.
> 2. Type `@.handover-XXXXXXXX.md` as your first message — the `@` picker autocompletes from `.handover-`. Claude Code injects the brief, then the absorb footer instructs the new session to move the file to `${TMPDIR:-/tmp}/` so it doesn't linger in the repo.
>
> The moved file stays recoverable in temp until reboot — re-injectable from there if you need it again, or `rm` it any time.

Do **not** run `/clear` yourself — it's a user command. Leave the operator in control.

## Notes for you

- Lead with **Intent**. If the next session reads only one section, that's the one.
- Concrete beats abstract. "Refactor `server/auth/middleware.ts:42` to drop JWT in favor of express-session" beats "improve auth".
- Don't summarize this skill's behavior to the operator before doing it. Just do it.
- If the session is genuinely trivial (one Q&A, no state worth carrying), say so to the operator and skip writing the file rather than producing a brief that says "nothing happened".
