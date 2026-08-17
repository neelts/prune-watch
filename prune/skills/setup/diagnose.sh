#!/bin/sh
# Emits the optional-channel-watcher diagnostic block for /prune:setup.
# Lives outside SKILL.md so awk/sed/cut field references like $2 don't get
# mangled by Claude Code's `$ARGUMENTS[N]` substitution.
#
# Argument: $1 = current session id (passed via ${CLAUDE_SESSION_ID} from skill).

SID="$1"
STATE_DIR="$HOME/.claude/channels/prune-watch"

echo "**Watcher plugin (\`prune-watch\`):**"
echo

if [ -z "$SID" ]; then
  echo "- **State**: NO SESSION ID PASSED to diagnose.sh"
  echo "- **Why**: The skill should call \`bash \\\${CLAUDE_SKILL_DIR}/diagnose.sh \\\${CLAUDE_SESSION_ID}\` and let Claude Code substitute the id. If you're seeing this, the model invoked the script via a side Bash call and the session id wasn't available — re-run \`/prune:setup\` so the skill's own preprocessing handles it."
else
  STATE="$STATE_DIR/state-$SID.json"
  if [ -f "$STATE" ]; then
    WHEN=$(stat -c %y "$STATE" 2>/dev/null | cut -d. -f1)
    echo "- **Watcher state file**: \`$STATE\` (last updated $WHEN) — the channel server is running for this session."
    TRANSCRIPT=$(sed -n 's/.*"transcript": *"\([^"]*\)".*/\1/p' "$STATE" | head -1)
    TOKENS=$(sed -n 's/.*"tokens": *\([0-9]*\).*/\1/p' "$STATE" | head -1)
    PCT=$(sed -n 's/.*"pct": *\([0-9]*\).*/\1/p' "$STATE" | head -1)
    SNOOZED=$(sed -n 's/.*"snoozed": *\([a-z]*\).*/\1/p' "$STATE" | head -1)
    echo "- **Watching transcript**: ${TRANSCRIPT:-n/a}"
    echo "- **Last token estimate** (server-side, may lag the live statusline): ${TOKENS:-0} tokens (~${PCT:-0}% of 1M context window)"
    echo "- **Snoozed**: ${SNOOZED:-n/a}"
  else
    echo "- **Watcher state file**: not found (\`$STATE\` does not exist)"
    echo "- **Likely cause**: the optional \`prune-watch\` plugin is not installed in this session — most users don't need it; the statusline above is enough. If you DID install \`prune-watch\` and still see this, the MCP server probably didn't get the launch flag (\`--dangerously-load-development-channels plugin:prune-watch@prune-watch\`)."
  fi
fi

echo
echo "**Channel status (this session):**"
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
  echo "**ENABLED** — if the \`prune-watch\` watcher plugin is installed, its proactive nudges will surface in this session when context crosses the threshold."
else
  echo "**NOT ENABLED** — Claude Code wasn't launched with a \`--channels\` flag, so even if the \`prune-watch\` plugin is installed its notifications would be dropped. (The statusline indicator works regardless of this flag — wire it up via the \`statusLine\` snippet above, and channel watcher remains optional.)"
fi

echo
echo "**Auto-resume (handover → /clear → /prune:resume, unattended):**"
echo

AR="$(dirname "$0")/../../scripts/auto-resume.sh"
if [ ! -f "$AR" ]; then
  echo "- **Script**: NOT FOUND at \`$AR\` — the prune plugin install looks incomplete."
elif [ "${PRUNE_AUTO_RESUME:-1}" = "0" ]; then
  echo "- **State**: DISABLED by \`PRUNE_AUTO_RESUME=0\` in this session's environment. \`/prune:handover\` will write the brief and leave \`/clear\` to you."
else
  PANEINFO=$(bash "$AR" check 2>/dev/null)
  if [ -n "$PANEINFO" ]; then
    echo "- **State**: AVAILABLE — this session runs in tmux pane \`$(echo "$PANEINFO" | cut -f1)\` (socket \`$(echo "$PANEINFO" | cut -f2)\`, access: $(echo "$PANEINFO" | cut -f3))."
    echo "- **Effect**: \`/prune:handover\` and \`/prune:distill\` arm a detached watcher that waits for the turn to end, sends \`/clear\`, then sends \`/prune:resume\`. Abort with \`kill <pid>\` (the pid is printed in the hand-off message) or by typing into the input box."
    echo "- **Log**: \`${TMPDIR:-/tmp}/prune-auto-resume.log\`"
  else
    echo "- **State**: NOT AVAILABLE — this session isn't in a tmux pane the script can reach, so \`/prune:handover\` falls back to telling you to run \`/clear\` and \`/prune:resume\` yourself."
    echo "- **Note**: if claude DOES run under tmux but the tmux server belongs to another user (root running sessions as an unprivileged user), the script needs passwordless \`sudo tmux\` to reach that server's socket."
  fi
fi

echo
echo "**Plugin version (staleness check):**"
echo

DISK_VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(dirname "$0")/../../.claude-plugin/plugin.json" 2>/dev/null | head -1)
echo "- **On disk**: ${DISK_VER:-unknown}"
echo "- **Loaded by this session**: whatever was on disk when claude started — plugin skills are read at session start, so edits to a locally-installed plugin do NOT reach a session that is already running."
echo "- **If they differ**: restart claude (the session resumes with \`--resume\` under tmux) to pick up the newer skills. \`/prune:handover\` and \`/prune:distill\` print their own baked-in version for exactly this comparison."
