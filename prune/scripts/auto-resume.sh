#!/usr/bin/env bash
# prune auto-resume — close the handover loop without the operator typing anything.
#
# /prune:handover ends with "now run /clear, then /prune:resume". Two manual
# steps, both of which have to happen in the right order, and the second one is
# exactly the moment the operator is least able to type (phone, remote client,
# walked away). When claude runs inside a tmux pane we can just do it for them:
# wait for the turn that wrote the brief to finish, send `/clear`, wait, send
# `/prune:resume`. The session comes back up carrying the brief and keeps going.
#
# Everything is driven from OUTSIDE the claude process, through the tmux server,
# because a session cannot clear itself: /clear is a client-side command and the
# model has no way to type into its own input box.
#
# Modes:
#   check                    detect the pane; print PANE<TAB>SOCKET<TAB>VIA, exit 3 if not in tmux
#   arm --brief PATH [opts]  fork a detached watcher that runs the cycle; print status line
#   abort                    kill an armed watcher for this pane
#   --watch ...              internal (the detached child)
#
# arm options:
#   --brief PATH   brief that must exist on disk before we dare /clear (required)
#   --hint TEXT    appended to /prune:resume as its focus hint
#   --dry-run      do everything except send keys (logs what it would send)
#
# Env knobs:
#   PRUNE_AUTO_RESUME=0            disable entirely (arm becomes a no-op)
#   PRUNE_AUTO_RESUME_IDLE_TIMEOUT max seconds to wait for the turn to end (default 300)
#   PRUNE_AUTO_RESUME_SETTLE       consecutive idle seconds before acting (default 5)
#   PRUNE_AUTO_RESUME_GAP          seconds between /clear and /prune:resume (default 6)
#   PRUNE_AUTO_RESUME_BOX_WAIT     seconds to wait for a dirty input box to clear (default 30)
#
# Output (arm): one tab-separated line
#   armed<TAB>PID<TAB>PANE<TAB>LOGFILE
#   skipped<TAB>REASON
set -uo pipefail

TMPD="${TMPDIR:-/tmp}"; TMPD="${TMPD%/}"
IDLE_TIMEOUT="${PRUNE_AUTO_RESUME_IDLE_TIMEOUT:-300}"
SETTLE="${PRUNE_AUTO_RESUME_SETTLE:-5}"
GAP="${PRUNE_AUTO_RESUME_GAP:-6}"
BOX_WAIT="${PRUNE_AUTO_RESUME_BOX_WAIT:-30}"
LAST_TYPED=""
LOG="$TMPD/prune-auto-resume.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

# ---------------------------------------------------------------- pane lookup

# All pids from this shell up to init. A tmux pane's pane_pid is the process it
# launched, so claude — and therefore this script — is always a descendant of it.
ancestry() {
	local p="$$" ppid n=0
	while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$n" -lt 40 ]; do
		printf '%s\n' "$p"
		if [ -r "/proc/$p/status" ]; then
			ppid=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
		else
			ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
		fi
		p="$ppid"; n=$((n + 1))
	done
}

# tmux against the detected socket, escalating only if that is how we found it.
tmx() {
	if [ "$VIA" = sudo ]; then
		sudo -n tmux -S "$SOCK" "$@"
	else
		tmux -S "$SOCK" "$@"
	fi
}

# Try one socket both ways; echo "direct" or "sudo" if list-panes works.
socket_access() {
	local sock="$1"
	[ -S "$sock" ] || [ -e "$sock" ] || { sudo -n test -S "$sock" 2>/dev/null || return 1; }
	if tmux -S "$sock" list-panes -a -F '#{pane_id}' >/dev/null 2>&1; then
		echo direct; return 0
	fi
	if command -v sudo >/dev/null 2>&1 &&
		sudo -n tmux -S "$sock" list-panes -a -F '#{pane_id}' >/dev/null 2>&1; then
		echo sudo; return 0
	fi
	return 1
}

candidate_sockets() {
	# The session's own server, when claude inherited TMUX (same-user case).
	[ -n "${TMUX:-}" ] && printf '%s\n' "${TMUX%%,*}"
	local d
	for d in "${TMUX_TMPDIR:-}" "/tmp/tmux-$(id -u)"; do
		[ -n "$d" ] && [ -d "$d" ] || continue
		for f in "$d"/*; do [ -e "$f" ] && printf '%s\n' "$f"; done
	done
	# Servers owned by another user — the claude-nest shape, where root's tmux
	# runs sessions as an unprivileged user. Needs passwordless sudo; if there
	# is none, socket_access just fails and we fall through to "not in tmux".
	command -v sudo >/dev/null 2>&1 || return 0
	for d in /tmp/tmux-*; do
		[ -d "$d" ] && [ ! -r "$d" ] || continue
		sudo -n ls -1 "$d" 2>/dev/null | while read -r f; do printf '%s/%s\n' "$d" "$f"; done
	done
}

# Sets PANE / SOCK / VIA. Returns 1 when this process is not inside a tmux pane.
detect_pane() {
	local pids sock access line pid
	pids=$(ancestry)
	while read -r sock; do
		[ -n "$sock" ] || continue
		access=$(socket_access "$sock") || continue
		SOCK="$sock"; VIA="$access"
		# TMUX_PANE is authoritative when we have it; verify it still exists.
		if [ -n "${TMUX_PANE:-}" ] && tmx display-message -p -t "$TMUX_PANE" '#{pane_id}' >/dev/null 2>&1; then
			PANE="$TMUX_PANE"; return 0
		fi
		while read -r line; do
			pid="${line#* }"
			if printf '%s\n' "$pids" | grep -qx "$pid"; then
				PANE="${line%% *}"; return 0
			fi
		done < <(tmx list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null)
	done < <(candidate_sockets)
	return 1
}

# ------------------------------------------------------------- pane inspection

tail_lines() { tmx capture-pane -p -t "$PANE" 2>/dev/null | tail -n "${1:-10}"; }

# Claude Code renders a spinner line — "✳ Synthesizing… (3m 58s · ↓ 8.4k tokens)"
# — while a turn is running, and drops it when idle. Only the bottom of the pane
# is inspected so the same text scrolling past in transcript output can't fake it.
pane_busy() {
	tail_lines 12 | grep -qE '\([0-9]+m [0-9]+s ·|\([0-9]+s ·|esc to interrupt'
}

# How much of the screen is in use — the /clear verification signal. A working
# session fills the pane (42 of 50 rows in the session this was built in); a
# cleared one collapses to the banner, the tip line and an empty input box.
pane_nonblank() {
	tmx capture-pane -p -t "$PANE" 2>/dev/null | grep -c '[^[:space:]]'
}

# Anything the OPERATOR has typed into the input box. Sending keys on top of it
# would submit their half-written message glued to ours, so we bail instead.
#
# "Empty" is not an empty line, in two ways:
#
#  - the box is padded with a non-breaking space, which no [[:space:]] class in
#    the C locale strips — hence the explicit glyph list, applied as quoted
#    (literal, locale-independent) substitutions;
#  - newer Claude Code builds park ghost text in the box — "<no suggestion>", an
#    inline completion — which is not input at all. That cost a real handover on
#    2026-08-25: the cycle armed, waited, and aborted on a box the operator had
#    never touched.
#
# Ghost text is rendered faint (SGR 2) and typed text is not, so capture with -e
# and drop the dim spans before reading what is left. The literal blocklist below
# is the belt to that braces, for the day a build stops using SGR 2.
input_content() {
	local esc raw line nbsp g
	esc=$(printf '\033')
	printf -v nbsp '\302\240'
	raw=$(tmx capture-pane -p -e -t "$PANE" 2>/dev/null | tail -8 |
		sed "s/${esc}\[2m[^${esc}]*${esc}\[[0-9;]*m//g; s/${esc}\[[0-9;]*m//g")
	# Prefer the real prompt glyph; a bare '>' also matches transcript blockquotes.
	line=$(printf '%s\n' "$raw" | grep -F '❯' | tail -1)
	[ -n "$line" ] || line=$(printf '%s\n' "$raw" | grep -E '^[[:space:]]*>' | tail -1)
	case "$line" in
		*"❯"*) line="${line#*"❯"}" ;;
		*">"*) line="${line#*">"}" ;;
	esac
	for g in "$nbsp" "▌" "█" "▏" "│"; do line="${line//"$g"/}"; done
	line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	case "$line" in
		"<no suggestion>"|"Try \""*|"Ask anything"*) line="" ;;
	esac
	printf '%s' "$line"
}

# A dirty box is often just mid-word. Give the operator a moment to finish or
# clear it before abandoning the cycle; only a box that STAYS dirty is an abort.
box_clear_within() {
	local limit="${1:-30}" waited=0
	while :; do
		LAST_TYPED=$(input_content)
		[ -z "$LAST_TYPED" ] && return 0
		[ "$waited" -ge "$limit" ] && return 1
		sleep 2; waited=$((waited + 2))
	done
}

# The watcher lives outside the session, so an abort was previously silent — the
# operator saw a handover that simply never continued, and the broken guard went
# unnoticed for a week (2026-08-25). tmux's own status line can say it without
# typing anything into the pane. Lands only if a client is attached; the log and
# the `arm` output carry it either way.
notify() {
	[ -n "$PANE" ] || return 0
	tmx display-message -d 8000 -t "$PANE" "prune auto-resume: $1" 2>/dev/null ||
		tmx display-message -t "$PANE" "prune auto-resume: $1" 2>/dev/null
	return 0
}

send_line() {
	local text="$1"
	if [ "$DRY" = 1 ]; then log "DRY-RUN would send: $text"; return 0; fi
	tmx send-keys -t "$PANE" -l "$text" || return 1
	sleep 1
	tmx send-keys -t "$PANE" Enter || return 1
	log "sent: $text"
}

pidfile_for() { printf '%s/prune-auto-resume-%s.pid' "$TMPD" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; }

# ------------------------------------------------------------------- the cycle

watch_cycle() {
	local waited=0 idle=0 quiet=0
	log "watcher $$ armed for pane $PANE (socket $SOCK, via $VIA, brief $BRIEF)"

	# 1. Wait for the turn that wrote the brief to finish. If the pane goes busy
	#    again *after* it has gone quiet, the operator has started a new turn —
	#    clearing then would throw away work the brief never saw, so bail out and
	#    let them handle it manually.
	while [ "$waited" -lt "$IDLE_TIMEOUT" ]; do
		if pane_busy; then
			if [ "$quiet" = 1 ]; then
				log "ABORT: new turn started after the session went idle — operator is driving"
				notify "aborted — you started a new turn"
				return 1
			fi
			idle=0
		else
			idle=$((idle + 1))
			[ "$idle" -ge 2 ] && quiet=1
		fi
		[ "$idle" -ge "$SETTLE" ] && break
		sleep 1; waited=$((waited + 1))
	done
	if [ "$idle" -lt "$SETTLE" ]; then
		log "ABORT: pane still busy after ${IDLE_TIMEOUT}s"
		notify "aborted — turn still running after ${IDLE_TIMEOUT}s"
		return 1
	fi

	# 2. Never clear a session whose brief did not actually land on disk.
	if [ ! -s "$BRIEF" ]; then
		log "ABORT: brief missing or empty: $BRIEF"
		notify "aborted — brief missing on disk"
		return 1
	fi

	# 3. Never clear over something the operator is typing.
	if ! box_clear_within "$BOX_WAIT"; then
		log "ABORT: input box still holds operator text after ${BOX_WAIT}s: $LAST_TYPED"
		notify "aborted — text in the input box"
		return 1
	fi
	if pane_busy; then
		log "ABORT: new turn started while waiting on the input box"
		notify "aborted — you started a new turn"
		return 1
	fi

	local before after
	before=$(pane_nonblank)
	send_line '/clear' || { log "ABORT: send-keys /clear failed"; notify "aborted — send-keys failed"; return 1; }
	sleep "$GAP"

	# Did the /clear actually land? Typing it opens the slash-command menu and
	# Enter takes the highlighted entry — normally /clear, but a plugin command
	# that also matches "clear" could steal it, and then the pane is sitting in
	# some other command's UI. A cleared session's screen collapses to a banner
	# and an empty box; a working one fills the pane. Refuse to type the second
	# command into a screen that did not collapse.
	after=$(pane_nonblank)
	if [ "$DRY" = 1 ]; then
		log "DRY-RUN skipping clear verification (nonblank ${before} -> ${after})"
	elif [ "$after" -le 15 ] || [ "$after" -lt $((before / 2)) ]; then
		log "clear confirmed (nonblank ${before} -> ${after})"
	else
		log "ABORT: /clear did not take (nonblank ${before} -> ${after}); leaving pane alone"
		notify "aborted — /clear did not take"
		return 1
	fi

	if ! box_clear_within 10; then
		log "ABORT: input box not empty after /clear: $LAST_TYPED"
		notify "aborted — text in the input box after /clear"
		return 1
	fi

	send_line "/prune:resume${HINT:+ $HINT}" || { log "ABORT: send-keys /prune:resume failed"; notify "aborted — send-keys failed"; return 1; }
	log "cycle complete"
}

# ------------------------------------------------------------------ entrypoint

MODE="${1:-check}"; shift 2>/dev/null || true
BRIEF=""; HINT=""; DRY=0
PANE=""; SOCK=""; VIA=""

while [ $# -gt 0 ]; do
	case "$1" in
		--brief) BRIEF="${2:-}"; shift 2 ;;
		--hint) HINT="${2:-}"; shift 2 ;;
		--dry-run) DRY=1; shift ;;
		--pane) PANE="${2:-}"; shift 2 ;;
		--socket) SOCK="${2:-}"; shift 2 ;;
		--via) VIA="${2:-}"; shift 2 ;;
		*) shift ;;
	esac
done

case "$MODE" in
check)
	if detect_pane; then
		printf '%s\t%s\t%s\n' "$PANE" "$SOCK" "$VIA"
	else
		echo "not running inside a tmux pane (or no access to its server socket)" >&2
		exit 3
	fi
	;;

arm)
	if [ "${PRUNE_AUTO_RESUME:-1}" = 0 ]; then
		printf 'skipped\tdisabled by PRUNE_AUTO_RESUME=0\n'; exit 0
	fi
	if [ -z "$BRIEF" ]; then
		printf 'skipped\tno --brief given\n'; exit 0
	fi
	case "$BRIEF" in /*) ;; *) BRIEF="$PWD/$BRIEF" ;; esac
	if ! detect_pane; then
		printf 'skipped\tnot in a tmux pane\n'; exit 0
	fi
	pf=$(pidfile_for "$PANE")
	if [ -f "$pf" ]; then
		old=$(cat "$pf" 2>/dev/null)
		if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
			kill "$old" 2>/dev/null; log "re-arm: killed stale watcher $old"
		fi
	fi
	# Absolute path: the detached child outlives the shell that invoked us, and a
	# relative $0 would break the moment anything changes directory.
	self="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
	[ -f "$self" ] || self="$0"
	cmd=(bash "$self" --watch --brief "$BRIEF" --hint "$HINT" --pane "$PANE" --socket "$SOCK" --via "$VIA")
	[ "$DRY" = 1 ] && cmd+=(--dry-run)
	if command -v setsid >/dev/null 2>&1; then
		setsid "${cmd[@]}" </dev/null >>"$LOG" 2>&1 &
	else
		nohup "${cmd[@]}" </dev/null >>"$LOG" 2>&1 &
	fi
	child=$!
	disown "$child" 2>/dev/null || true
	printf '%s' "$child" >"$pf"
	printf 'armed\t%s\t%s\t%s\n' "$child" "$PANE" "$LOG"
	;;

abort)
	detect_pane || { echo "not in a tmux pane" >&2; exit 3; }
	pf=$(pidfile_for "$PANE")
	old=$(cat "$pf" 2>/dev/null)
	if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
		kill "$old" 2>/dev/null; rm -f "$pf"
		printf 'aborted\t%s\n' "$old"
	else
		rm -f "$pf"
		printf 'nothing armed\n'
	fi
	;;

--watch)
	[ -n "$PANE" ] && [ -n "$SOCK" ] || { log "watcher: missing pane/socket"; exit 1; }
	trap 'log "watcher $$ killed"; rm -f "$(pidfile_for "$PANE")"; exit 0' TERM INT
	watch_cycle; rc=$?
	rm -f "$(pidfile_for "$PANE")"
	exit "$rc"
	;;

*)
	echo "usage: auto-resume.sh {check|arm --brief PATH [--hint TEXT] [--dry-run]|abort}" >&2
	exit 64
	;;
esac
