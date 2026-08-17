---
name: resume
description: Pick up the most recent handover brief and carry on working, with no filename to type. The zero-argument counterpart to /prune:handover and /prune:distill — instead of re-injecting the brief by `@`-mention, this finds the newest brief on disk (workspace first, then system temp), absorbs it, moves it out of the repo, and continues from its Next steps. Use when the operator invokes /prune:resume, or says "continue", "pick up where we left off", or "resume the handover" in a freshly cleared session — especially on mobile or remote clients where the `@` file picker is unreliable.
disable-model-invocation: true
argument-hint: [focus hint, optional]
---

# /prune:resume — absorb the latest brief and keep going

The operator has just `/clear`ed and wants the previous session's context back
**without typing a filename**. The `@.handover-<sid>.md` flow needs the file
picker, and the picker is unreliable on the mobile and remote clients — which is
precisely where a `/clear` happens and where typing a session-id from memory is
worst. This command replaces the picker with a filesystem lookup.

`$1` is an optional focus hint. If non-empty, bias what you resume toward that
thread rather than blindly taking the brief's first Next step.

## Step 0 — Refuse to resume into a session that is already full

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-freshness.sh"
```

Prints `STATE<TAB>LINES<TAB>TRANSCRIPT`, where STATE is `fresh`, `full`, or
`unknown`.

`/prune:resume` is meant to be the **first** thing a post-`/clear` session does.
Run in a session that still has its context it is a no-op at best — the brief
summarises what is already loaded — and harmful at worst, because Step 2 MOVES
the brief out of the workspace into temp: the operator ends up with a stale file
in temp, a session that never needed it, and nothing in the repo to resume from
later. That happened on 2026-08-13.

- **`fresh`** — carry on to Step 1.
- **`full`** — STOP. Say in one line that this session still has its context
  (quote the line count), that the brief was therefore not moved, and offer the
  two things the operator probably meant: `/clear` first and re-run, or
  `/prune:handover` to refresh the brief with what this session has done since.
  Do not read the brief, do not move it.
- **`unknown`** — no `CLAUDE_SESSION_ID` or no transcript found. Do not block on
  it; say so in half a line and continue, since a wrong refusal is worse than a
  redundant resume.

## Step 1 — Find the brief

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-handover.sh"
```

It prints one tab-separated line — `PATH<TAB>AGE_MINUTES<TAB>BYTES<TAB>LOCATION`
— searching, newest mtime wins:

| candidate | meaning |
| --- | --- |
| `<cwd>/.handover-*.md` | `/prune:handover` output, never absorbed |
| `<cwd>/.prune-handover-*.md` | `/prune:distill` output, never absorbed |
| `$TMPDIR/handover-*.md` | absorbed by an earlier session, still resumable |
| `$TMPDIR/prune-handover-*.md` | same, from `/prune:distill` |

Exit 1 with a message on stderr means nothing was found. Say so in one line and
stop — do **not** invent context or guess what the session was about. Suggest
`/prune:handover` if they still have the old session open in another tab.

If the operator passed an explicit path as `$1`, use that instead of the script.

## Step 2 — Read it, then get it out of the repo

`Read` the path. That is the absorb — treat the brief as your working memory for
the rest of the session, exactly as if it had been `@`-mentioned.

If `LOCATION` is `workspace`, move it to temp so it does not pollute
`git status`, mirroring the absorb footer the brief itself carries:

```bash
mv <PATH> "${TMPDIR:-/tmp}/$(basename <PATH> | sed 's/^\.//')"
```

The leading dot is stripped so the temp copy matches what the `@`-flow produces
(`.handover-abc.md` → `handover-abc.md`). If `LOCATION` is already `temp`, leave
it alone — it is already out of the way, and a second resume should still find it.

## Step 3 — Sanity-check the age

`AGE_MINUTES` matters. A brief is a snapshot of a moving repo:

- **under ~2h** — resume without ceremony.
- **2–24h** — resume, but say the age out loud in your confirmation line, and
  re-check anything the brief asserts about in-flight state (a running job, a
  pending deploy, an armed cron) rather than trusting it.
- **over ~24h** — the repo has almost certainly moved. Say how old it is and ask
  whether to resume from it or start fresh, before acting on its Next steps.

Cheap corroboration in every case: `git log --oneline -5` and `git status
--short`. A brief that names commits you cannot see, or claims a clean tree that
is dirty, is stale in ways worth flagging *before* you act on it.

## Step 4 — Confirm briefly, then actually continue

Print **two or three lines at most**: which brief you picked up, how old it is,
and the single thing you are about to do. Do not replay the brief — the operator
wrote it, or watched it be written, and re-reading it back is exactly the context
bloat this plugin exists to avoid.

Then **do the work**. This command's whole purpose is momentum: it should end
with the first Next step underway, not with "ready when you are". Pick the target
by, in order:

1. the focus hint in `$1`, if given;
2. the brief's first **Next steps** entry;
3. anything the brief flags as in-flight or blocked on the operator — surface
   that instead, marked **you:**, since it cannot be actioned unilaterally.

If the brief's first step turns out to be blocked (needs a decision, a field
observation, or an answer only the operator has), do not stall on it: say so in
one line, and start the highest-value step that is not blocked.
