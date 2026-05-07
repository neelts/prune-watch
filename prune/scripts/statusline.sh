#!/usr/bin/env bash
# prune statusline — context-size indicator with prune/handover nudge.
#
# Wire into Claude Code via settings.json:
#
#   {
#     "statusLine": {
#       "type": "command",
#       "command": "bash ~/.claude/plugins/cache/<owner>/<marketplace>/prune/scripts/statusline.sh"
#     }
#   }
#
# Or, if you've cloned the marketplace locally:
#
#   "command": "bash /absolute/path/to/prune-watch/prune/scripts/statusline.sh"
#
# Run /prune:setup to get the exact path for your install.
#
# Env tunables (all optional):
#   PRUNE_THRESHOLD_TOKENS    — show red nudge above this (default 200000)
#   PRUNE_WARN_RATIO          — show yellow at this fraction of threshold (default 0.7)
#   PRUNE_CONTEXT_WINDOW      — total ctx for percentage display (default 1000000)
#   PRUNE_QUIET_BELOW_TOKENS  — print nothing at all under this many tokens (default 0)
#   PRUNE_NO_COLOR=1          — disable ANSI colors

set -u

threshold="${PRUNE_THRESHOLD_TOKENS:-200000}"
warn_ratio="${PRUNE_WARN_RATIO:-0.7}"
ctx_window="${PRUNE_CONTEXT_WINDOW:-1000000}"
quiet_below="${PRUNE_QUIET_BELOW_TOKENS:-0}"

# Read Claude Code's statusline JSON from stdin. Fields documented at
# code.claude.com/docs/en/statusline. We rely on session_id and transcript_path.
input="$(cat 2>/dev/null || true)"

extract() {
  # $1 = key, $2 = default. Pull a string field from $input. Prefer jq when
  # available; fall back to a tolerant grep that handles flat top-level fields.
  local key="$1" default="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '
      if type == "object" then
        (.. | objects | select(has($k)) | .[$k]) // empty
      else empty end
    ' <<<"$input" 2>/dev/null | head -1 | sed 's/^null$//' || echo "$default"
  else
    printf '%s' "$input" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' || echo "$default"
  fi
}

session_id="$(extract session_id)"
transcript_path="$(extract transcript_path)"

# If stdin gave us nothing, try the conventional env fallback. Useful when the
# script is run by hand for testing.
if [[ -z "${transcript_path}" && -n "${CLAUDE_SESSION_ID:-}" ]]; then
  proj_dir="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
  candidate="$proj_dir/${CLAUDE_SESSION_ID}.jsonl"
  [[ -f "$candidate" ]] && transcript_path="$candidate"
  session_id="${CLAUDE_SESSION_ID}"
fi

# Cache per-session for 2s — statusline can fire frequently and JSONL parses
# aren't free. Cache key incorporates transcript mtime so a stale cache after
# a quick session change can't lie.
sid_short="${session_id:0:8}"
cache_dir="${TMPDIR:-/tmp}"
cache_file="$cache_dir/prune-statusline-${sid_short:-anon}.cache"
mtime=0
size=0
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
  mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)
  size=$(stat -c %s "$transcript_path" 2>/dev/null || stat -f %z "$transcript_path" 2>/dev/null || echo 0)
fi
cache_key="${mtime}-${size}"
if [[ -f "$cache_file" ]]; then
  cached_key="$(head -1 "$cache_file" 2>/dev/null || true)"
  if [[ "$cached_key" == "$cache_key" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    if (( age < 2 )); then
      tail -n +2 "$cache_file"
      exit 0
    fi
  fi
fi

tokens=0
if [[ -n "$transcript_path" && -f "$transcript_path" && "$size" -gt 0 ]]; then
  # Mirror server.ts's estimateTokensFromUsage: scan the tail (256KB is enough
  # for one assistant entry), find the most recent line with role=assistant +
  # usage, sum input + cache_creation + cache_read.
  tail_bytes=262144
  if (( size <= tail_bytes )); then
    tail_data="$(cat "$transcript_path")"
  else
    tail_data="$(tail -c "$tail_bytes" "$transcript_path")"
  fi
  if command -v jq >/dev/null 2>&1; then
    # Reverse so we find the LAST matching line first. jq -e returns nonzero
    # if no match — silenced.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" != *'"role":"assistant"'* ]] && continue
      [[ "$line" != *'"usage"'* ]] && continue
      tokens=$(jq -r '
        (.message.usage // {}) as $u |
        (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0))
      ' <<<"$line" 2>/dev/null) || tokens=0
      if [[ -n "$tokens" && "$tokens" != "0" ]]; then break; fi
    done < <(printf '%s\n' "$tail_data" | tac 2>/dev/null || printf '%s\n' "$tail_data" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}')
  else
    # No jq — coarse fallback. Pull the last numeric values right after the
    # three keys we care about; this is best-effort but stays within the
    # statusline's <50ms budget.
    last_block="$(printf '%s' "$tail_data" | grep -o '"role":"assistant"[^]]*"usage":{[^}]*}' | tail -1)"
    in_t=$(printf '%s' "$last_block" | grep -o '"input_tokens":[0-9]*' | grep -o '[0-9]*$')
    cc_t=$(printf '%s' "$last_block" | grep -o '"cache_creation_input_tokens":[0-9]*' | grep -o '[0-9]*$')
    cr_t=$(printf '%s' "$last_block" | grep -o '"cache_read_input_tokens":[0-9]*' | grep -o '[0-9]*$')
    tokens=$(( ${in_t:-0} + ${cc_t:-0} + ${cr_t:-0} ))
  fi
fi

tokens="${tokens:-0}"
[[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

if (( tokens < quiet_below )); then
  printf '%s\n' "$cache_key" >"$cache_file"
  printf '' >>"$cache_file"
  exit 0
fi

# Format token count.
if (( tokens >= 1000 )); then
  tokens_label="$(( tokens / 1000 ))k"
else
  tokens_label="${tokens}"
fi

# Percentage of full window.
if (( ctx_window > 0 )); then
  pct=$(( tokens * 100 / ctx_window ))
else
  pct=0
fi

# Yellow threshold: warn_ratio is "0.7" — convert via shell arithmetic.
warn_threshold=$(awk -v t="$threshold" -v r="$warn_ratio" 'BEGIN { printf("%d", t*r) }')

color=""; reset=""
if [[ -z "${PRUNE_NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; }; then
  reset=$'\033[0m'
  if (( tokens >= threshold )); then
    color=$'\033[1;31m'   # bold red
  elif (( tokens >= warn_threshold )); then
    color=$'\033[33m'      # yellow
  else
    color=$'\033[2m'        # dim
  fi
fi

if (( tokens >= threshold )); then
  body="${color}📋 ctx ${tokens_label} (${pct}%)${reset} — /prune:distill or /prune:handover"
elif (( tokens > 0 )); then
  body="${color}ctx ${tokens_label} (${pct}%)${reset}"
else
  body="${color}ctx —${reset}"
fi

# Persist to cache then emit. First line is the cache key; remainder is body.
{ printf '%s\n' "$cache_key"; printf '%s' "$body"; } >"$cache_file"
printf '%s' "$body"
