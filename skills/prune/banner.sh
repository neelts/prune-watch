#!/bin/sh
# Emits a one-line channel-enablement note for the /prune-watch:prune skill.
# Lives outside SKILL.md so awk/sed field references like $2 don't get
# mangled by Claude Code's `$ARGUMENTS[N]` substitution.

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
  echo "ENABLED — proactive nudges will fire when context crosses threshold"
else
  echo "NOT ENABLED — pruning works on demand, but you will not get proactive nudges. Add '--dangerously-load-development-channels plugin:prune-watch@prune-watch' to your claude launch (NOT --channels — that requires allowlist membership). Run /prune-watch:setup for guided setup."
fi
