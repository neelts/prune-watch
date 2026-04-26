#!/bin/sh
# Emits the diagnostic block for /prune-watch:setup.
# Lives outside SKILL.md so awk/sed/cut field references like $2 don't get
# mangled by Claude Code's `$ARGUMENTS[N]` substitution.
#
# Argument: $1 = current session id (passed via ${CLAUDE_SESSION_ID} from skill).

SID="$1"
STATE_DIR="$HOME/.claude/channels/prune-watch"

echo "## Plugin process status"
echo
if [ -z "$SID" ]; then
  # No session id passed. This means the skill body's `${CLAUDE_SESSION_ID}`
  # substitution wasn't honoured (e.g. the model invoked diagnose.sh directly
  # via Bash with `${CLAUDE_SESSION_ID:-}` shell expansion against an env var
  # that doesn't exist). Bail loudly rather than reading a sibling state file
  # that has nothing to do with this session.
  echo "- **Channel server state file**: NO SESSION ID PASSED to diagnose.sh"
  echo "- **Why**: The skill should call \`bash \\\${CLAUDE_SKILL_DIR}/diagnose.sh \\\${CLAUDE_SESSION_ID}\` and let Claude Code substitute the id. If you're seeing this, the model invoked the script via a side Bash call and the session id wasn't available — re-run \`/prune-watch:setup\` so the skill's own preprocessing handles it."
  echo "- **Watching transcript**: unknown until session id is provided"
  echo "- **Current token estimate**: unknown until session id is provided"
  echo "- **Snoozed**: unknown until session id is provided"
else
  STATE="$STATE_DIR/state-$SID.json"
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
    echo "- **Channel server state file**: NO STATE FOR THIS SESSION (\`$STATE\` does not exist)"
    echo "- **Why**: The channel server hasn't run for this session id yet. Either the plugin's MCP server didn't spawn (check \`/mcp\`), or it spawned but couldn't pin this session via /proc walk. Almost always means the launcher didn't pass \`--dangerously-load-development-channels\` (see Channel status below)."
    echo "- **Watching transcript**: n/a — server not active"
    echo "- **Current token estimate**: n/a — server not active"
    echo "- **Snoozed**: n/a — server not active"
  fi
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
  # Channels can be enabled via either flag — they're alternatives. The dev
  # flag does NOT contain '--channels' as a substring (single hyphen before
  # 'channels'), so check both literally.
  if echo "$CMD" | grep -qE -- '(^| )(--channels|--dangerously-load-development-channels)( |$)'; then
    ENABLED=yes
    break
  fi
done

if [ "$ENABLED" = "yes" ]; then
  echo "**ENABLED** — proactive nudges from prune-watch will surface in this session when context crosses the threshold."
else
  echo "**NOT ENABLED** — the channel server is running, but Claude Code is dropping its notifications because \`--dangerously-load-development-channels plugin:prune-watch@prune-watch\` was not passed at launch. (Pruning still works on demand via \`/prune-watch:prune\`.)"
fi
