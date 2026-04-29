---
name: prune
description: Golden-ratio context prune. Read this session's transcript, delegate bucketing to a fresh subagent, show the operator a ranked toggle list, and write a seed brief to .prune-handover-<sid>.md in the project root so the operator can /clear and re-inject it via @.prune-handover-<sid>.md. The post-/clear Claude moves the file to system temp after absorbing, so the workspace doesn't get polluted but the brief stays recoverable. Use when the operator invokes /prune-watch:prune, or when they ask to "prune context" or "compact smartly". For first-time setup or to enable proactive nudges, run /prune-watch:setup.
disable-model-invocation: true
argument-hint: [aggressive|conservative|keyword]
allowed-tools: Bash(bash *) Bash(stat *) Bash(wc *) Bash(test *) Bash(echo *) Read Write Edit AskUserQuestion
---

# /prune — operator-guided context prune

The operator just invoked `/prune-watch:prune`. Your job is to **orchestrate** the prune. The actual bucketing happens in a fresh subagent (`transcript-bucketer`) so the analysis isn't done in a degraded context window.

Session info (expanded before you see this):

- **Session ID**: `${CLAUDE_SESSION_ID}`
- **Transcript path (resolved)**: !`echo "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl"`
- **Transcript size**: !`stat -c '%s bytes, modified %y' "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl" 2>/dev/null | sed 's/\.[0-9]* +/ +/' || echo "MISSING — transcript not found at expected path"`
- **Transcript line count**: !`wc -l < "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl" 2>/dev/null || echo "n/a"`
- **Handover file path** (workspace; write here so the operator can `@`-mention with project-tree autocomplete): !`echo ".prune-handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Post-absorb destination** (where the post-`/clear` Claude moves it after reading): !`echo "${TMPDIR:-/tmp}/prune-handover-$(echo "${CLAUDE_SESSION_ID}" | head -c 8).md"`
- **Channel status**: !`bash ${CLAUDE_SKILL_DIR}/banner.sh`
- **Operator hint**: `$ARGUMENTS`

## Step 1 — Sanity check

If the transcript path above says `MISSING`, stop and tell the operator: "Can't find the transcript at the expected path. Check `~/.claude/projects/` for the right session file." Do not proceed.

If **Channel status** says `NOT ENABLED`, surface a one-line note to the operator BEFORE proceeding with the prune — something like *"Heads-up: prune-watch channel isn't enabled in this session, so you won't get proactive nudges going forward. Pruning will still work right now."* Then continue with the prune. Don't block on it; it's informational.

Otherwise continue.

## Step 2 — Snooze, then delegate to the bucketer

**First, auto-snooze the channel for 15 minutes** so a context-size nudge can't surface mid-prune. Call the prune-watch snooze tool with `{"seconds": 900}` (the snooze auto-expires; if anything goes wrong below, nudges re-arm by themselves):

- **tool**: `mcp__plugin_prune-watch_prune-watch__snooze`
- **arguments**: `{"seconds": 900}`

If the snooze tool isn't available (plugin's MCP server not running in this session), skip silently and continue — the prune still works, you just risk one nudge interrupting the operator's view.

Next, find any CLAUDE.md files the bucketer should use as the documented baseline. Check these in order; include each one that exists:

- `<cwd>/CLAUDE.md` (project root)
- `<cwd>/.claude/CLAUDE.md` (project-local override)

Use a quick `test -f` to check existence; pass only the readable ones. Don't recursively walk the project — the project-root CLAUDE.md is the canonical source; nested ones are for subprojects and aren't worth the bucketer's read budget here.

Then spawn the `transcript-bucketer` subagent via the Agent tool. Pass it:

- **subagent_type**: `transcript-bucketer`
- **description**: `Bucket session transcript`
- **prompt**: something like:

  ```
  Read and bucket this Claude Code session transcript:

  Transcript path: <resolved path from above>

  claude_md_paths: <newline-separated list of CLAUDE.md absolute paths you confirmed exist; empty if none>

  Operator hint (may be empty): <$ARGUMENTS>

  Return the JSON object exactly as specified in your instructions — no prose.
  ```

Do **not** paste transcript contents into the prompt. The subagent has `Read` and will fetch the file itself.

## Step 3 — Parse and render

The subagent returns a JSON object of shape:

```json
{
  "transcript_tokens_estimate": <int>,
  "claude_md_read": ["..."],
  "buckets": [
    {"id": 1, "title": "...", "bucket_type": "...", "importance": "high|medium|low",
     "novelty": "new|documented", "tokens": <int>, "keep_default": true|false,
     "summary": "...", "key_facts": ["..."]}
  ]
}
```

If parsing fails, show the operator the raw subagent output and stop.

Otherwise render a compact ranked list. Format:

```
Prune proposal — ctx ~<total>k tokens, <N> buckets
CLAUDE.md cross-checked: <list claude_md_read paths, or "none — no docs baseline used">

  [x] 1. NEW HIGH  decisions      — auth middleware refactor (42k)
         chose express-session over JWT after legal/compliance review
  [x] 2. NEW HIGH  open-threads   — pending Redis migration (12k)
         decided in conversation, not yet in CLAUDE.md
  [ ] 3. DOC HIGH  files-touched  — server/auth/* (28k)
         middleware/store/login — already covered in CLAUDE.md
  [ ] 4. DOC LOW   tool-exhaust   — grep output 1200-1400 (18k)
         bulk search results, no longer referenced
  ...

[x] = kept by default, [ ] = dropped by default
NEW = not in CLAUDE.md (load-bearing, you'll lose it on /clear)
DOC = covered in CLAUDE.md (safe to drop, post-/clear session re-reads it)
```

Use checkboxes based on `keep_default`. Always render `NEW` / `DOC` before the importance label so the load-bearing axis is the most scannable column. Keep the summary line to one line per bucket (truncate if needed). If `claude_md_read` is empty, replace the cross-checked line with a one-line note: "No CLAUDE.md found — novelty is best-effort guesswork."

## Step 4 — Ask the operator how to apply

After printing the toggle list, prompt the operator with four options. **Try `AskUserQuestion` first; fall back to a plain-text prompt if that tool isn't available in this harness** — it's missing in some Claude Code environments and you'll know because calling it errors or doesn't surface a UI.

### Building the option set

The same four options are shown either way:

- **Accept (recommended)** — use the default keep set (the `[x]` rows), build brief, hand off
- **Accept & note** — same as accept, plus append the kept `new` buckets to CLAUDE.md as a dated session-notes block (omit this option entirely if `claude_md_read` was empty in the bucketer output, i.e. no CLAUDE.md exists in the project)
- **Customize** — pick specific buckets via `keep 1,3,5` or `drop 2,4` (operator types the list in their next turn)
- **Cancel** — abort, no brief written, channel re-armed

### Path A — `AskUserQuestion` available

```
AskUserQuestion({
  questions: [{
    question: "Apply this prune?",
    header: "Prune",
    multiSelect: false,
    options: [
      { label: "Accept (Recommended)",
        description: "Use the default keep set (the [x] rows above). Build the seed brief and hand off." },
      { label: "Accept & note",  // OMIT this option if claude_md_read is empty
        description: "Same as Accept, AND append the kept `new` buckets to CLAUDE.md as a dated session-notes block (curate or move them later; safe to delete)." },
      { label: "Customize",
        description: "Pick specific buckets to keep or drop. You'll then reply with `keep 1,3,5` or `drop 2,4`." },
      { label: "Cancel",
        description: "Abort the prune. No brief written. Channel nudges re-armed." },
    ],
  }],
})
```

The `Other` option is auto-added by the tool, covering free-form replies.

### Path B — plain-text fallback (when `AskUserQuestion` errors or isn't available)

Print this block verbatim (omit the `accept & note` line if no CLAUDE.md):

```
Apply this prune?
- accept — use the default keep set, build brief, hand off
- accept & note — same as accept, plus append the kept new buckets to CLAUDE.md as a dated session-notes block
- customize — pick specific buckets via `keep 1,3,5` or `drop 2,4`
- cancel — abort, no brief written, channel re-armed
```

Then wait for the operator's next turn.

### Mapping answers to outcomes

The mapping below applies to BOTH paths — match case-insensitively. The plain-text path will give you lowercase strings; the dialog gives you the labelled forms.

| answer (any case) | kept set | side effect |
| --- | --- | --- |
| `accept` / `Accept (Recommended)` | all `keep_default: true` | none |
| `accept & note` / `Accept & note` | all `keep_default: true` | also append `new` kept buckets to CLAUDE.md (Step 5b) |
| `customize` / `Customize` | ask the operator in the next turn for `keep …` / `drop …` | none |
| `cancel` / `Cancel` | (none) | call the prune-watch unsnooze tool, tell operator "Prune cancelled, nothing changed.", stop |
| free-form `keep 1,3,5` / `drop 2,4` (any source) | parse directly | none |

Always surface the final kept list back to the operator before building the brief, so they can double-check.

## Step 5 — Build the seed brief

For the kept buckets, concatenate into a seed brief the operator can paste after `/clear`. Shape:

````markdown
# Carryover brief

Previous session distilled the following context. Treat this as your working memory.

## What's decided

<kept buckets of type `decisions` — their summary + key_facts as bullet points>

## Files currently relevant

<kept buckets of type `files-touched` — paths + one-line why>

## Open threads

<kept buckets of type `open-threads` — each as a bullet>

## Ruled out (don't re-explore)

<kept buckets of type `ruled-out` — each as a bullet>

## Other kept context

<anything else that was kept>

---

<!-- prune-watch absorb footer — keep verbatim, substitute the real paths -->
**After absorbing:** This brief lives at `<HANDOVER-PATH>` in the workspace. Move it out of the repo so it doesn't pollute git status: `mv <HANDOVER-PATH> <POST-ABSORB-PATH>`. The file survives in temp and is recoverable until system reboot — don't delete it.
````

Skip sections that have no kept buckets. Do not pad. Do not invent content — only use what the bucketer returned.

Within each section, list `novelty: new` buckets before `novelty: documented` ones — `new` buckets are why the brief exists at all; `documented` ones are the operator-overridden "keep this even though CLAUDE.md covers it" cases.

The absorb footer is required — substitute `<HANDOVER-PATH>` with the **Handover file path** value (e.g. `.prune-handover-1f71f5fb.md`) and `<POST-ABSORB-PATH>` with the **Post-absorb destination** value (e.g. `/tmp/prune-handover-1f71f5fb.md`) from the session-info block at the top. Both come from the same skill render, so they reference the same session-id slice.

## Step 5b — (only if the operator chose `Accept & note`) append to CLAUDE.md

Skip this step entirely unless the answer in Step 4 was `Accept & note`. When it was:

1. Read the project's CLAUDE.md (the first path in `claude_md_read` from the bucketer output).
2. Append a clearly-marked, dated block at the END of the file. Use the `Edit` tool with `old_string = ""` semantics is unsupported — instead, Read the current content, then Write the full content with the new block appended. Or use `Edit` with the file's last few lines as `old_string` and `<old_string> + new block` as `new_string`. Either works; use whichever is cleaner.
3. Block content (substitute the real session id and ISO date):

```markdown


<!-- prune-watch session notes — appended {ISO date} from session {short-sid} -->
## Session notes ({YYYY-MM-DD})

Auto-appended by `/prune-watch:prune` (Accept & note). These are decisions/facts that lived only in the conversation, not yet in the rest of CLAUDE.md. **Curate, move, or delete.**

<one ## subsection per kept `novelty: new` bucket — use the bucket title as the heading, summary + key_facts as bullets>

<!-- end prune-watch notes -->
```

Only `novelty: new` buckets in the kept set go into this block. `documented` buckets are by definition already in CLAUDE.md — appending them again would be redundant.

After writing, tell the operator briefly: *"Also appended N notes to CLAUDE.md — review when convenient."* Then continue to Step 6.

## Step 6 — Hand off

**Save the seed brief to disk** using the `Write` tool with path = the **Handover file path** value from the session-info block at the top (e.g. `.prune-handover-1f71f5fb.md`). The path is project-root-relative — that way the operator's `@`-mention picker autocompletes it cleanly from `@.p<tab>`. The post-`/clear` Claude moves it out of the workspace as part of absorbing it, so it doesn't sit in git status long.

This file is the carryover artefact — the operator will inject it into the fresh post-`/clear` session via Claude Code's `@` file-mention picker.

Then print a short hand-off message — NOT the full brief, just the path and instructions. Don't render the brief inline; the file IS the deliverable. Substitute the actual filename into the message:

> Prune ready. Brief saved to `.prune-handover-XXXXXXXX.md` (N kept buckets, ~Xk tokens).
>
> To apply:
> 1. Run `/clear` to reset the session.
> 2. Type `@.prune-handover-XXXXXXXX.md` as your first message — the `@` picker autocompletes from `.prune-handover-`. Claude Code injects the brief, then the absorb footer instructs the new session to move the file to `${TMPDIR:-/tmp}/` so it doesn't linger in the repo.
>
> The moved file stays recoverable in temp until system reboot — re-injectable from there if you need it again, or `rm` it any time.

Do **not** run `/clear` yourself — it's a user command and applying it would happen before the operator's seen the hand-off message. Leave the operator in control.

After printing the hand-off message, call the prune-watch unsnooze tool to re-arm nudges immediately (the 15-min auto-snooze from Step 2 would also expire on its own, but unsnoozing now keeps the next session's threshold-tracking honest).

## Notes for you

- The subagent runs in a fresh context on Haiku. It's cheap. Don't second-guess its output; render what it returns.
- If the operator's reply is ambiguous ("keep the auth stuff"), ask for ids — don't guess.
- Don't summarise this skill's behaviour back to the operator before doing it. Just do it.
