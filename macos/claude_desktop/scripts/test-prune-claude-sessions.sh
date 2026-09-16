#!/usr/bin/env bash
#
# test-prune-claude-sessions.sh — prove the constraints of
# plan://claude_desktop/prune_read_bounding against a synthetic store.
#
# Every test builds a throwaway HOME and points the script at it, so nothing here
# can touch the real transcript store, the real session store or the real cache.
#
# The two constraints that matter most are checked from BOTH sides:
#
#   "never read a whole transcript"
#       - a PATH shim records a violation if grep, tail or jq is ever handed a
#         .jsonl path (the positive check: those forks are gone), AND
#       - a transcript whose only custom-title sits BEYOND the tail window must
#         come back untitled (the negative check: a whole-file read would find
#         it, so finding it means one was reintroduced).
#
#   "never read all the sessions"
#       - the watermark must equal the NEWEST last-entry observed, and a pinned
#         session far below it must not drag it down, AND
#       - the second run's candidate count must cover only what changed.
#
# Usage:  scripts/test-prune-claude-sessions.sh          run all
#         scripts/test-prune-claude-sessions.sh t_pins   run matching tests

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/prune-claude-sessions.sh"
[ -x "$SCRIPT" ] || { echo "not executable: $SCRIPT" >&2; exit 1; }

FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_NAMES=""

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

# ---------------------------------------------------------------- assertions

fail_ctx=""

ok()  { printf '    %sok%s   %s\n' "$GREEN" "$OFF" "$1"; }
bad() {
	printf '    %sFAIL%s %s\n' "$RED" "$OFF" "$1"
	fail_ctx="$fail_ctx|$1"
	# The last run's own summary is almost always the explanation, so show it
	# rather than making the reader re-derive the fixture by hand.
	if [ -n "${TH:-}" ] && [ -f "$TH/run.out" ]; then
		sed -n '1,8p' "$TH/run.out" | sed 's/^/         > /'
	fi
}

assert_eq() { # $1=actual $2=expected $3=what
	if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: expected [$2], got [$1]"; fi
}
assert_contains() { # $1=haystack $2=needle $3=what
	case "$1" in *"$2"*) ok "$3" ;; *) bad "$3: output does not contain [$2]" ;; esac
}
assert_not_contains() { # $1=haystack $2=needle $3=what
	case "$1" in *"$2"*) bad "$3: output unexpectedly contains [$2]" ;; *) ok "$3" ;; esac
}

# ---------------------------------------------------------------- fixtures

# Resolve the real tools once so the shims can exec them.
REAL_GREP="$(command -v grep)"
REAL_TAIL="$(command -v tail)"
REAL_JQ="$(command -v jq)"
REAL_PERL="$(command -v perl)"
for t in "$REAL_GREP" "$REAL_TAIL" "$REAL_JQ" "$REAL_PERL"; do
	[ -n "$t" ] || { echo "missing a required tool (grep/tail/jq/perl)" >&2; exit 1; }
done

TH=""        # throwaway HOME for the current test
WS=""        # the primary workspace dir inside it
WS2=""       # a second account's workspace dir
SHIMLOG=""

new_store() {
	TH="$(mktemp -d "${TMPDIR:-/tmp}/prune-test-home.XXXXXX")"
	mkdir -p "$TH/.claude/projects/-proj-a"
	WS="$TH/Library/Application Support/Claude/claude-code-sessions/acct-1/ws-1"
	WS2="$TH/Library/Application Support/Claude/claude-code-sessions/acct-2/ws-1"
	mkdir -p "$WS" "$WS2"

	# PATH shims: any of these handed a transcript is a constraint violation.
	SHIMLOG="$TH/shim-violations"
	: >"$SHIMLOG"
	mkdir -p "$TH/bin"
	for pair in "grep:$REAL_GREP" "tail:$REAL_TAIL" "jq:$REAL_JQ"; do
		name="${pair%%:*}"
		real="${pair#*:}"
		cat >"$TH/bin/$name" <<SHIM
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
  *.jsonl) echo "VIOLATION: $name invoked on a transcript: \$a" >>"$SHIMLOG" ;;
  esac
done
exec "$real" "\$@"
SHIM
		chmod +x "$TH/bin/$name"
	done
}

drop_store() { [ -n "$TH" ] && rm -rf "$TH"; TH=""; }

# iso8601 (…Z) -> touch -t stamp.
#
# ALWAYS apply it as `TZ=UTC touch -t`. touch parses -t in LOCAL time, while the
# script derives the watermark epoch from the transcript's UTC timestamp, so a
# bare touch offsets every fixture mtime by the local UTC offset and the mtime
# prefilter admits transcripts it should have excluded.
touch_stamp() { # $1=2026-09-16T04:05:06.000Z
	local s="${1%%.*}"
	s="${s//-/}"; s="${s//:/}"; s="${s/T/}"
	printf '%s.%s' "${s:0:12}" "${s:12:2}"
}

filler_lines() { # $1=kb
	"$REAL_PERL" -e '
		my $kb = shift @ARGV;
		my $filler = "x" x 900;
		for my $i (1 .. $kb) {
			print "{\"type\":\"assistant\",\"timestamp\":\"2026-01-01T00:00:02.000Z\",\"text\":\"$filler\"}\n";
		}' "$1"
}

# mk_tx <cli> <iso-ts> [title] [pad_before_kb] [pad_after_kb]
#
# Writes a transcript whose LAST timestamp is <iso-ts> and whose LAST
# custom-title is <title>.
#
#   pad_before — filler BEFORE the title. Makes a large file whose title still
#                sits near the end. A correct tail reader finds it.
#   pad_after  — filler AFTER the title, pushing it out of the tail window.
#                A correct tail reader must NOT find it.
mk_tx() {
	local cli="$1" ts="$2" title="${3:-}" before="${4:-0}" after="${5:-0}"
	local f="$TH/.claude/projects/-proj-a/$cli.jsonl"
	{
		printf '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","text":"hello"}\n'
		[ "$before" -gt 0 ] && filler_lines "$before"
		if [ -n "$title" ]; then
			"$REAL_JQ" -nc --arg t "$title" \
				'{type:"custom-title",customTitle:$t,timestamp:"2026-01-01T00:00:01.000Z"}'
		fi
		[ "$after" -gt 0 ] && filler_lines "$after"
		printf '{"type":"assistant","timestamp":"%s","text":"bye"}\n' "$ts"
	} >"$f"
	TZ=UTC touch -t "$(touch_stamp "$ts")" "$f"
}

# mk_ref <cli> [lastActivityAt] [dir]
mk_ref() {
	local cli="$1" la="${2:-1}" dir="${3:-$WS}"
	"$REAL_JQ" -nc --arg c "$cli" --argjson l "$la" \
		'{cliSessionId:$c,lastActivityAt:$l,title:"ignored"}' >"$dir/local_$cli.json"
}

# retitle_quietly <cli> <new-title> <keep-this-mtime-iso>
#
# Rewrites the title and RESTORES the old mtime, so the session stays below the
# watermark. This is the only way to exercise the pin re-check: an ordinary
# retitle bumps mtime, and then the walk would pick it up instead.
retitle_quietly() {
	local cli="$1" title="$2" ts="$3"
	local f="$TH/.claude/projects/-proj-a/$cli.jsonl"
	{
		printf '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","text":"hello"}\n'
		"$REAL_JQ" -nc --arg t "$title" \
			'{type:"custom-title",customTitle:$t,timestamp:"2026-01-01T00:00:01.000Z"}'
		printf '{"type":"assistant","timestamp":"%s","text":"bye"}\n' "$ts"
	} >"$f.rewrite"
	mv "$f.rewrite" "$f"
	TZ=UTC touch -t "$(touch_stamp "$ts")" "$f"
}

# run() is invoked as $(run ...), so its body executes in a SUBSHELL and any
# variable it sets is lost on return — an earlier version leaked one test's
# exit status into every later test. The status goes to a file instead.
run() { # args passed through; echoes combined output, records the exit status
	HOME="$TH" PATH="$TH/bin:$PATH" "$SCRIPT" "$@" >"$TH/run.out" 2>&1
	echo $? >"$TH/run.rc"
	cat "$TH/run.out"
}

run_rc() { cat "$TH/run.rc" 2>/dev/null || echo "?"; }

cache_field() { # $1=row-type $2=column
	[ -f "$TH/.claude-prune-cache.tsv" ] || { printf '<no cache file>'; return; }
	awk -F'\t' -v k="$1" -v c="$2" '$1 == k { print $c; exit }' "$TH/.claude-prune-cache.tsv"
}

assert_clean_run() { # $1=output
	local rc; rc="$(run_rc)"
	if [ "$rc" != "0" ]; then
		bad "the run exited $rc: $(printf '%s' "$1" | tail -2 | tr '\n' ' ')"
	else
		ok "the run exited 0"
	fi
}

assert_no_shim_violation() {
	if [ -s "$SHIMLOG" ]; then
		bad "no grep/tail/jq touched a transcript: $(head -3 "$SHIMLOG" | tr '\n' ';')"
	else
		ok "no grep/tail/jq touched a transcript"
	fi
}

# ---------------------------------------------------------------- the tests

t_tail_only_reads() {
	new_store
	mk_tx s-new 2026-09-16T04:00:00.000Z "1: current" 0 0
	# 400KB of filler BEFORE the title: a large transcript, title near the end.
	mk_tx s-big 2026-09-16T03:00:00.000Z "2: big, titled near the end" 400 0
	mk_ref s-new; mk_ref s-big
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_no_shim_violation
	assert_contains "$out" "1: current" "a normal title is read"
	assert_contains "$out" "2: big, titled near the end" \
		"a title inside the window is read even in a 400KB transcript"
	drop_store
}

t_title_beyond_window_is_not_found() {
	# 400KB of filler AFTER the title pushes it past the 256K window. A whole-file
	# read would still find it, so finding it here means one was reintroduced.
	new_store
	mk_tx s-far 2026-09-16T04:00:00.000Z "9: buried past the window" 0 400
	mk_tx s-near 2026-09-16T03:00:00.000Z "1: visible" 0 0
	mk_ref s-far; mk_ref s-near
	local out; out="$(run --dry-run)"

	assert_no_shim_violation
	assert_not_contains "$out" "9: buried past the window" \
		"a title beyond the tail window is NOT found (no whole-file fallback)"
	assert_contains "$out" "1: visible" "the in-window title is still found"
	drop_store
}

t_watermark_is_the_newest_entry() {
	new_store
	mk_tx s-a 2026-09-10T00:00:00.000Z "1: older" 0 0
	mk_tx s-b 2026-09-16T04:00:00.000Z "2: newest" 0 0
	mk_ref s-a; mk_ref s-b
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_eq "$(cache_field floor 3)" "2026-09-16T04:00:00.000Z" \
		"watermark equals the NEWEST last-entry, not the oldest keeper"
	assert_eq "$(cache_field version 2)" "2" "cache carries a version row"
	drop_store
}

t_old_pin_does_not_drag_the_watermark() {
	# The exact defect this plan exists for: pins are keepers and pins are old, so
	# a floor taken from the keep set sinks to the oldest pin and never climbs.
	new_store
	mk_tx s-pin 2026-01-05T00:00:00.000Z "* ancient pin" 0 0
	mk_tx s-now 2026-09-16T04:00:00.000Z "1: today" 0 0
	mk_ref s-pin; mk_ref s-now
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "* ancient pin" "the ancient pin is kept"
	assert_eq "$(cache_field floor 3)" "2026-09-16T04:00:00.000Z" \
		"an ancient PIN does not lower the watermark"
	drop_store
}

t_retitled_old_session_is_rescued() {
	# The documented way to pull an old session back into the batch by hand, and
	# the reason the mtime prefilter is allowed to OVER-include. A retitle writes
	# the file, so mtime jumps above the watermark while the last entry stays old.
	# Anything that terminates the walk on a timestamp comparison against the
	# watermark throws this session away again.
	new_store
	mk_tx s-ancient 2026-02-01T00:00:00.000Z "" 0 0
	mk_tx s-recent 2026-09-16T04:00:00.000Z "1: today" 0 0
	mk_ref s-ancient; mk_ref s-recent
	run >/dev/null
	assert_eq "$(cache_field floor 3)" "2026-09-16T04:00:00.000Z" "run 1 sets the watermark"

	# Retitle it for real: content changes, mtime jumps to now, last entry stays old.
	retitle_quietly s-ancient "5: rescued by hand" 2026-02-01T00:00:00.000Z
	touch "$TH/.claude/projects/-proj-a/s-ancient.jsonl"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "5: rescued by hand" \
		"a retitled session below the watermark is still kept (walk does not stop at the floor)"
	drop_store
}

t_watermark_never_moves_backwards() {
	# The watermark is the high-water mark of what has been SEEN, so it must never
	# regress. A run whose newest candidate is older than the inherited watermark
	# — here because the session that set it is gone and an ancient one was merely
	# touched — must keep the inherited value, or the next run rescans the gap.
	new_store
	mk_tx s-old 2026-03-01T00:00:00.000Z "1: ancient" 0 0
	mk_tx s-new 2026-09-16T04:00:00.000Z "2: recent" 0 0
	mk_ref s-old; mk_ref s-new
	run >/dev/null
	assert_eq "$(cache_field floor 3)" "2026-09-16T04:00:00.000Z" "run 1 sets the high-water mark"

	# The session that set it disappears; the ancient one is merely touched.
	rm -f "$TH/.claude/projects/-proj-a/s-new.jsonl" "$WS/local_s-new.json"
	touch "$TH/.claude/projects/-proj-a/s-old.jsonl"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_eq "$(cache_field floor 3)" "2026-09-16T04:00:00.000Z" \
		"the watermark does NOT regress to an older last-entry"
	drop_store
}

t_second_run_only_sees_what_changed() {
	new_store
	local i
	for i in 1 2 3 4 5 6 7 8; do
		mk_tx "s-old-$i" "2026-09-0${i}T00:00:00.000Z" "$i: batch" 0 0
		mk_ref "s-old-$i"
	done
	local out1; out1="$(run)"
	assert_clean_run "$out1"
	local floor1; floor1="$(cache_field floor 3)"
	assert_eq "$floor1" "2026-09-08T00:00:00.000Z" "run 1 records the newest entry"

	# One new session lands; the other eight are untouched.
	mk_tx s-fresh 2026-09-20T00:00:00.000Z "1: brand new" 0 0
	mk_ref s-fresh
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "watermark:  $floor1" "run 2 consults the watermark"
	# Two, not one: the prefilter is mtime >= watermark, so the session that SET
	# the watermark is admitted again alongside the new one. Over-inclusion is the
	# design — it is what makes a retitle of an old session land — and two out of
	# nine is the point.
	assert_contains "$out" "candidates: 2 by mtime" \
		"run 2 admits only the new transcript plus the watermark boundary one"
	assert_contains "$out" "walked 2" "run 2 walks two sessions, not the store"
	assert_no_shim_violation
	drop_store
}

t_keepers_carry_forward() {
	new_store
	mk_tx s-1 2026-09-10T01:00:00.000Z "1: alpha" 0 0
	mk_tx s-2 2026-09-10T02:00:00.000Z "2: bravo" 0 0
	mk_tx s-3 2026-09-10T03:00:00.000Z "3: charlie" 0 0
	# s-4 is the newest and so sets the watermark; the mtime >= boundary re-admits
	# it on run 2, which leaves #2 and #3 as the ones that must CARRY.
	mk_tx s-4 2026-09-10T04:00:00.000Z "4: delta" 0 0
	mk_ref s-1; mk_ref s-2; mk_ref s-3; mk_ref s-4
	run >/dev/null

	# A newer #1 arrives; #2 and #3 are untouched and below the watermark.
	mk_tx s-1b 2026-09-20T00:00:00.000Z "1: echo" 0 0
	mk_ref s-1b
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "carried:    2" "the two untouched numbered keepers carry forward"
	assert_contains "$out" "1: echo" "the newer #1 wins its number"
	assert_not_contains "$out" "1: alpha" "the older #1 loses its number"
	assert_contains "$out" "2: bravo" "#2 survives without being re-read"
	assert_contains "$out" "3: charlie" "#3 survives without being re-read"
	drop_store
}

t_pin_released_when_star_removed() {
	new_store
	mk_tx s-pin 2026-01-05T00:00:00.000Z "* keep me" 0 0
	mk_tx s-now 2026-09-16T04:00:00.000Z "1: today" 0 0
	mk_ref s-pin; mk_ref s-now
	run >/dev/null
	assert_contains "$(cat "$TH/.claude-prune-cache.tsv" 2>/dev/null)" "pin	s-pin" \
		"the pin is cached"

	# Unstar it WITHOUT bumping mtime, so only the pin re-check can notice.
	retitle_quietly s-pin "keep me" 2026-01-05T00:00:00.000Z
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "1 released" "an unstarred pin below the watermark is released"
	assert_not_contains "$out" "keep me" "the released session is dropped from the keep set"
	drop_store
}

t_pin_kept_when_star_remains() {
	new_store
	mk_tx s-pin 2026-01-05T00:00:00.000Z "* keep me" 0 0
	mk_tx s-now 2026-09-16T04:00:00.000Z "1: today" 0 0
	mk_ref s-pin; mk_ref s-now
	run >/dev/null
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "1 re-checked and still starred" \
		"a starred pin below the watermark is re-checked and kept"
	assert_contains "$out" "* keep me" "the pin stays in the keep set"
	assert_no_shim_violation
	drop_store
}

t_no_backups() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "1: keep" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep; mk_ref s-drop

	local dry; dry="$(run --dry-run)"
	assert_contains "$dry" "deleted outright" "the plan says dropped references are deleted"

	local out; out="$(run)"
	assert_clean_run "$out"
	local found; found="$(ls -d "$TH"/claude-deleted-session-refs-* 2>/dev/null | wc -l | tr -d ' ')"
	assert_eq "$found" "0" "no backup directory is created"

	run --no-backup >/dev/null 2>&1
	assert_eq "$(run_rc)" "2" "--no-backup is gone and is rejected as an unknown option"
	drop_store
}

t_v1_cache_is_ignored() {
	new_store
	mk_tx s-a 2026-09-16T04:00:00.000Z "1: a" 0 0
	mk_ref s-a
	# A v1 cache: a floor meaning "oldest kept", no version row, no keep rows.
	printf 'floor\t1786503878\t2026-08-12T03:04:38.664Z\npin\ts-gone\n' \
		>"$TH/.claude-prune-cache.tsv"
	local out; out="$(run --dry-run)"

	assert_contains "$out" "watermark:  none" "a cache with no current version row is ignored"
	drop_store
}

t_transcripts_are_never_written() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "1: keep" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep; mk_ref s-drop
	local before after
	before="$(cd "$TH/.claude/projects/-proj-a" && stat -f '%N %m %z' ./*.jsonl && cksum ./*.jsonl)"
	local out; out="$(run)"
	assert_clean_run "$out"
	after="$(cd "$TH/.claude/projects/-proj-a" && stat -f '%N %m %z' ./*.jsonl && cksum ./*.jsonl)"
	assert_eq "$after" "$before" "no transcript changed content, size or mtime"
	drop_store
}

t_relink_shares_one_inode() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "1: keep" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep 5; mk_ref s-drop 5
	# The higher lastActivityAt wins, so WS2's copy is the inode the app is
	# treated as writing to and the one every dir must end up pointing at.
	mk_ref s-keep 9 "$WS2"
	local winner; winner="$(stat -f '%i' "$WS2/local_s-keep.json")"

	local out; out="$(run)"
	assert_clean_run "$out"

	assert_eq "$(ls "$WS" | sort | tr '\n' ' ')" "local_s-keep.json " \
		"the first dir holds exactly the keeper"
	assert_eq "$(ls "$WS2" | sort | tr '\n' ' ')" "local_s-keep.json " \
		"the second dir holds exactly the keeper"
	assert_eq "$(stat -f '%i' "$WS/local_s-keep.json")" \
		"$(stat -f '%i' "$WS2/local_s-keep.json")" "both dirs point at ONE inode"
	# Agreeing with each other is not enough: staging with cp mints a FRESH inode
	# that both dirs would agree on just as happily, while orphaning the one the
	# app holds open. The surviving inode must be the ORIGINAL.
	assert_eq "$(stat -f '%i' "$WS2/local_s-keep.json")" "$winner" \
		"the surviving inode is the ORIGINAL winner, not a fresh copy"
	drop_store
}

t_numbering_first_seen_wins() {
	new_store
	mk_tx s-old3 2026-09-10T00:00:00.000Z "3: older three" 0 0
	mk_tx s-new3 2026-09-16T00:00:00.000Z "3-1: newer three" 0 0
	mk_tx s-star 2026-09-15T00:00:00.000Z "  * leading space pin" 0 0
	mk_tx s-plain 2026-09-14T00:00:00.000Z "no number here" 0 0
	mk_ref s-old3; mk_ref s-new3; mk_ref s-star; mk_ref s-plain
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$out" "3-1: newer three" "the newest holder of a number wins"
	assert_not_contains "$out" "3: older three" "the older reuse of that number is dropped"
	assert_contains "$out" "* leading space pin" "a pin survives leading whitespace"
	assert_not_contains "$out" "no number here" "an unnumbered session is dropped"
	drop_store
}

# ---------------------------------------------------------------- runner

TESTS="
t_tail_only_reads
t_title_beyond_window_is_not_found
t_watermark_is_the_newest_entry
t_old_pin_does_not_drag_the_watermark
t_watermark_never_moves_backwards
t_retitled_old_session_is_rescued
t_second_run_only_sees_what_changed
t_keepers_carry_forward
t_pin_released_when_star_removed
t_pin_kept_when_star_remains
t_no_backups
t_v1_cache_is_ignored
t_transcripts_are_never_written
t_relink_shares_one_inode
t_numbering_first_seen_wins
"

for t in $TESTS; do
	if [ -n "$FILTER" ]; then
		case "$t" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	printf '%s%s%s\n' "$DIM" "$t" "$OFF"
	fail_ctx=""
	"$t"
	if [ -n "$fail_ctx" ]; then
		FAIL=$((FAIL + 1))
		FAILED_NAMES="$FAILED_NAMES $t"
	else
		PASS=$((PASS + 1))
	fi
done

echo
if [ "$FAIL" -eq 0 ]; then
	printf '%s%d passed, 0 failed%s\n' "$GREEN" "$PASS" "$OFF"
	exit 0
fi
printf '%s%d passed, %d failed:%s%s\n' "$RED" "$PASS" "$FAIL" "$FAILED_NAMES" "$OFF"
exit 1
