---
name: prune
description: Golden-ratio context prune. Read this session's transcript, delegate bucketing to a fresh subagent, show the operator a ranked toggle list, and build a seed brief so the operator can /clear without losing what matters. Use when the operator invokes /prune-watch:prune, or when they ask to "prune context" or "compact smartly".
disable-model-invocation: true
argument-hint: [aggressive|conservative|keyword]
allowed-tools: Bash(ls *) Bash(wc *) Bash(stat *) Bash(test *) Read
---

# /prune — operator-guided context prune

The operator just invoked `/prune-watch:prune`. Your job is to **orchestrate** the prune. The actual bucketing happens in a fresh subagent (`transcript-bucketer`) so the analysis isn't done in a degraded context window.

Session info (expanded before you see this):

- **Session ID**: `${CLAUDE_SESSION_ID}`
- **Transcript path (resolved)**: !`echo "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl"`
- **Transcript size**: !`ls -lh "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl" 2>/dev/null | awk '{print $5, "bytes,", $6, $7, $8}' || echo "MISSING — transcript not found at expected path"`
- **Transcript line count**: !`wc -l "$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/${CLAUDE_SESSION_ID}.jsonl" 2>/dev/null | awk '{print $1}' || echo "n/a"`
- **Operator hint**: `$ARGUMENTS`

## Step 1 — Sanity check

If the transcript path above says `MISSING`, stop and tell the operator: "Can't find the transcript at the expected path. Check `~/.claude/projects/` for the right session file." Do not proceed.

Otherwise continue.

## Step 2 — Delegate to the bucketer

Spawn the `transcript-bucketer` subagent via the Agent tool. Pass it:

- **subagent_type**: `transcript-bucketer`
- **description**: `Bucket session transcript`
- **prompt**: something like:

  ```
  Read and bucket this Claude Code session transcript:

  Transcript path: <resolved path from above>

  Operator hint (may be empty): <$ARGUMENTS>

  Return the JSON object exactly as specified in your instructions — no prose.
  ```

Do **not** paste transcript contents into the prompt. The subagent has `Read` and will fetch the file itself.

## Step 3 — Parse and render

The subagent returns a JSON object of shape:

```json
{
  "transcript_tokens_estimate": <int>,
  "buckets": [
    {"id": 1, "title": "...", "bucket_type": "...", "importance": "high|medium|low",
     "tokens": <int>, "keep_default": true|false, "summary": "...", "key_facts": ["..."]}
  ]
}
```

If parsing fails, show the operator the raw subagent output and stop.

Otherwise render a compact ranked list. Format:

```
Prune proposal — ctx ~<total>k tokens, <N> buckets

  [x] 1. HIGH  decisions      — auth middleware refactor (42k)
         chose express-session over JWT after legal/compliance review
  [x] 2. HIGH  files-touched  — server/auth/* (28k)
         middleware, store, login route
  [ ] 3. LOW   tool-exhaust   — grep output 1200-1400 (18k)
         bulk search results, no longer referenced
  ...

[x] = kept by default, [ ] = dropped by default

Reply with:
  keep 1,3,5          → keep these (override all defaults)
  drop 2,4            → drop these (from the default-kept set)
  accept              → go with defaults
  cancel              → abort, change nothing
```

Use checkboxes based on `keep_default`. Keep the summary line to one line per bucket (truncate if needed). Colour/markdown is fine if the terminal renders it; ASCII is the fallback.

## Step 4 — Await operator reply

The operator replies with one of the four forms above. In the next turn, parse their reply into a final kept-set:

- `accept` → kept = all buckets where `keep_default == true`
- `keep 1,3,5` → kept = buckets with those ids (override defaults entirely)
- `drop 2,4` → kept = defaults minus those ids
- `cancel` → stop here, tell the operator "Prune cancelled, nothing changed."

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
````

Skip sections that have no kept buckets. Do not pad. Do not invent content — only use what the bucketer returned.

## Step 6 — Hand off

Print the seed brief inside a fenced code block so the operator can copy it verbatim, then give them the two-step instruction:

> Prune ready. To apply:
>
> 1. Run `/clear` to reset the session.
> 2. Paste the brief above as your first message.
>
> The new session will start with exactly the context you kept and nothing else.

Do **not** run `/clear` yourself — it's a user command and applying it would discard the brief before the operator sees it. Leave the operator in control.

## Notes for you

- The subagent runs in a fresh context on Haiku. It's cheap. Don't second-guess its output; render what it returns.
- If the operator's reply is ambiguous ("keep the auth stuff"), ask for ids — don't guess.
- Don't summarise this skill's behaviour back to the operator before doing it. Just do it.
