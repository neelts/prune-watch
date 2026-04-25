#!/bin/sh
# Emits the diagnostic block for /prune-watch:setup.
# Lives outside SKILL.md so awk/sed/cut field references like $2 don't get
# mangled by Claude Code's `$ARGUMENTS[N]` substitution.
#
# Argument: $1 = current session id (passed via ${CLAUDE_SESSION_ID} from skill).

SID="$1"
STATE_DIR="$HOME/.claude/channels/prune-watch"
if [ -n "$SID" ]; then
  STATE="$STATE_DIR/state-$SID.json"
else
  STATE="$STATE_DIR/state-unknown.json"
fi

echo "## Plugin process status"
echo
if [ -f "$STATE" ]; then
  WHEN=$(stat -c %y "$STATE" 2>/dev/null | cut -d. -f1)
  echo "- **Channel server state file**: \`$STATE\` (last updated $WHEN)"
  TRANSCRIPT=$(sed -n 's/.*"transcript": *"\([^"]*\)".*/\1/p' "$STATE" | head -1)
  TOKENS=$(sed -n 's/.*"tokens": *\([0-9]*\).*/\1/p' "$STATE" | head -1)
  PCT=$(sed -n 's/.*"pct": *\([0-9]*\).*/\1/p' "$STATE" | head -1)
  SNOOZED=$(sed -n 's/.*"snoozed": *\([a-z]*\).*/\1/p' "$STATE" | head -1)
  echo "- **Watching transcript**: ${TRANSCRIPT:-n/a}"
  echo "- **Current token estimate**: ${TOKENS:-0} tokens (~${PCT:-0}% of 1M context window)"
  echo "- **Snoozed**: ${SNOOZED:-n/a}"
else
  echo "- **Channel server state file**: MISSING — server has not started yet, or failed at startup"
  echo "- **Watching transcript**: n/a"
  echo "- **Current token estimate**: n/a"
  echo "- **Snoozed**: n/a"
fi

echo
echo "## Channel status (this session)"
echo

# Walk parent process tree, looking for any ancestor with --channels in cmdline.
PID=$$
ENABLED=no
i=0
while [ $i -lt 8 ]; do
  i=$((i + 1))
  PPID_OF=$(sed -n 's/^PPid:[[:space:]]*//p' /proc/$PID/status 2>/dev/null)
  if [ -z "$PPID_OF" ] || [ "$PPID_OF" = "1" ]; then break; fi
  PID=$PPID_OF
  CMD=$(tr '\0' ' ' </proc/$PID/cmdline 2>/dev/null)
  if echo "$CMD" | grep -q -- "--channels"; then
    ENABLED=yes
    break
  fi
done

if [ "$ENABLED" = "yes" ]; then
  echo "**ENABLED** — proactive nudges from prune-watch will surface in this session when context crosses the threshold."
else
  echo "**NOT ENABLED** — the channel server is running, but Claude Code is dropping its notifications because \`--dangerously-load-development-channels plugin:prune-watch@prune-watch\` was not passed at launch. (Pruning still works on demand via \`/prune-watch:prune\`.)"
fi
