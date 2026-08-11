#!/usr/bin/env bash
# prune find-handover — locate the most recent handover brief for /prune:resume.
#
# Exists because the `@.handover-<sid>.md` re-injection flow needs a file picker,
# and the file picker is unreliable on the mobile/remote clients — where a
# `/clear` is exactly when you least want to be typing a filename from memory.
# This finds the newest brief on disk instead, so resuming takes no arguments.
#
# Searches, newest mtime wins:
#   <cwd>/.handover-*.md              — /prune:handover, not yet absorbed
#   <cwd>/.prune-handover-*.md        — /prune:distill, not yet absorbed
#   $TMPDIR/handover-*.md             — already absorbed once, still resumable
#   $TMPDIR/prune-handover-*.md
#
# Output: one tab-separated line — PATH<TAB>AGE_MINUTES<TAB>BYTES<TAB>LOCATION
# where LOCATION is "workspace" (should be moved out after reading) or "temp".
# Exit 1 with a message on stderr when nothing is found.
#
# Usage:  bash find-handover.sh [search-dir]
set -uo pipefail

dir="${1:-$PWD}"
tmp="${TMPDIR:-/tmp}"
tmp="${tmp%/}"

newest=""
newest_mtime=0
newest_where=""

consider() {
	local f="$1" where="$2" m
	[ -f "$f" ] || return 0
	# %Y is GNU/busybox stat; BSD stat needs -f %m.
	m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 0
	[ -n "$m" ] || return 0
	if [ "$m" -gt "$newest_mtime" ]; then
		newest_mtime="$m"
		newest="$f"
		newest_where="$where"
	fi
}

shopt -s nullglob
for f in "$dir"/.handover-*.md "$dir"/.prune-handover-*.md; do
	consider "$f" workspace
done
for f in "$tmp"/handover-*.md "$tmp"/prune-handover-*.md; do
	consider "$f" temp
done
shopt -u nullglob

if [ -z "$newest" ]; then
	echo "no handover brief found in $dir or $tmp" >&2
	exit 1
fi

now=$(date +%s)
age=$(( (now - newest_mtime) / 60 ))
bytes=$(wc -c < "$newest" | tr -d ' ')
printf '%s\t%s\t%s\t%s\n' "$newest" "$age" "$bytes" "$newest_where"
