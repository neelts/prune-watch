#!/usr/bin/env bash
# Is this session FRESH (just cleared) or FULL (already carrying context)?
#
# /prune:resume is meant to be the first thing a post-/clear session does. Run in
# a session that still has its context, it is a no-op at best — the brief it
# absorbs is a summary of what is already loaded — and actively harmful at worst,
# because it MOVES the brief out of the workspace into temp. The operator then
# has a stale file in temp, a session that never needed it, and nothing left in
# the repo to resume from later (observed 2026-08-13).
#
# Claude Code writes one JSONL transcript per session, and /clear starts a new
# session with a new id. So the current transcript's length is a direct measure:
# a freshly cleared session has a handful of lines, a working session has
# thousands (3401 in the one that prompted this).
#
# Prints: STATE<TAB>LINES<TAB>TRANSCRIPT   (STATE = fresh | full | unknown)
# Exit 0 always — the caller decides what to do; this only reports.
set -uo pipefail

: "${CLAUDE_SESSION_ID:=}"
FRESH_MAX_LINES="${PRUNE_FRESH_MAX_LINES:-40}"

if [ -z "$CLAUDE_SESSION_ID" ]; then
	printf 'unknown\t0\t(no CLAUDE_SESSION_ID)\n'
	exit 0
fi

# Claude Code slugifies the project path: /root/Dev/sl-smart -> -root-Dev-sl-smart
slug=$(printf '%s' "$PWD" | sed 's#/#-#g')
transcript=""
for base in "$HOME/.claude/projects" "${CLAUDE_CONFIG_DIR:-}/projects"; do
	[ -n "$base" ] || continue
	cand="$base/$slug/$CLAUDE_SESSION_ID.jsonl"
	if [ -f "$cand" ]; then transcript="$cand"; break; fi
done

# Fall back to a search: worktrees and symlinked cwds slugify unpredictably.
if [ -z "$transcript" ]; then
	transcript=$(find "$HOME/.claude/projects" -name "$CLAUDE_SESSION_ID.jsonl" -type f 2>/dev/null | head -1)
fi

if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
	printf 'unknown\t0\t(no transcript for %s)\n' "$CLAUDE_SESSION_ID"
	exit 0
fi

lines=$(wc -l < "$transcript" | tr -d ' ')
if [ "$lines" -le "$FRESH_MAX_LINES" ]; then
	printf 'fresh\t%s\t%s\n' "$lines" "$transcript"
else
	printf 'full\t%s\t%s\n' "$lines" "$transcript"
fi
