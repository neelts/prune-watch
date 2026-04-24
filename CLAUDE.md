# Prune Watch

## Design context

Canonical design record lives at `CONTEXT.md` in this directory — a symlink
into the Obsidian vault at `/root/Dev/vault/Main/Projects/Claude Ideas/List/Prune Watch.md`.

**Read it first.** It's the "why" layer: motivation, explored alternatives,
handoff brief, evolving decisions. Edits here propagate back to the vault
automatically (same file on disk).

The symlink is local to `claude-nest` (not committed). If you need the
context on another machine, read the note in the vault repo directly:
<https://github.com/neelts/vault/blob/main/Main/Projects/Claude%20Ideas/List/Prune%20Watch.md>

## Working notes

- Implementation decisions that diverge from `CONTEXT.md` should be
  appended there with a date stamp, not stashed in separate notes.
- This repo's commit history is the authoritative record of *what was
  built*; `CONTEXT.md` is the authoritative record of *why*.

## Kickoff checklist

Before starting V2 (channel plugin), verify:

- `claude --version` ≥ 2.1.80
- claude.ai login active (channels don't work with API key auth)
- `bun --version` succeeds
- Read [Channels reference](https://code.claude.com/docs/en/channels-reference)
- Study [claude-plugins-official](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins) — telegram/discord/fakechat as templates

Start with V1 (slash command + subagent delegate) even if V2 is the goal —
V1's bucketer prompt and carryover format are the real IP; V2 is plumbing
around them.
