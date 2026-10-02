#!/usr/bin/env bash
#
# test-prune-claude-sessions.sh — prove the constraints of
# plan://claude_desktop/prune_reference_authority against a synthetic store.
#
# Every test builds a throwaway HOME and points the script at it, so nothing here
# can touch the real transcript store or the real session store.
#
# The constraint that matters most is that a session the SIDEBAR shows as
# numbered or pinned is never dropped for want of something else. It is checked
# from every side a decision could leak through:
#
#   - the number comes from the reference's .title, even when the transcript
#     says otherwise or its custom-title sits beyond the tail window;
#   - a session is decided on every run however old its transcript is and
#     whatever earlier runs did, and no cache file is read or written;
#   - a transcript with no reference can never claim a number;
#   - every dropped row is printed with its reason.
#
# "Never read a whole transcript" is checked by a PATH shim that records a
# violation if grep, tail or jq is ever handed a .jsonl path.
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
	# The last run's own report is almost always the explanation, so show it
	# rather than making the reader re-derive the fixture by hand.
	if [ -n "${TH:-}" ] && [ -f "$TH/run.out" ]; then
		sed -n '1,20p' "$TH/run.out" | sed 's/^/         > /'
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
# fixture timestamps are UTC, so a bare touch offsets every fixture mtime by the
# local UTC offset.
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
# custom-title is <title>, with its mtime set to <iso-ts>.
#
#   pad_before — filler BEFORE the title. Makes a large file whose title still
#                sits near the end.
#   pad_after  — filler AFTER the title, pushing it out of the tail window.
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

# mk_ref <cli> [title] [lastActivityAt] [dir]
#
# The title is the reference's .title, the one the sidebar shows. An empty title
# is written as "", which sends the script to the transcript's custom-title.
mk_ref() {
	local cli="$1" title="${2:-}" la="${3:-1}" dir="${4:-$WS}"
	"$REAL_JQ" -nc --arg c "$cli" --arg t "$title" --argjson l "$la" \
		'{cliSessionId:$c,lastActivityAt:$l,title:$t}' >"$dir/local_$cli.json"
}

# run() is invoked as $(run ...), so its body executes in a SUBSHELL and any
# variable it sets is lost on return. The status goes to a file instead.
run() { # args passed through; echoes combined output, records the exit status
	HOME="$TH" PATH="$TH/bin:$PATH" "$SCRIPT" "$@" >"$TH/run.out" 2>&1
	echo $? >"$TH/run.rc"
	cat "$TH/run.out"
}

run_rc() { cat "$TH/run.rc" 2>/dev/null || echo "?"; }

# The report's "keeping:" and "dropping:" sections, one row per line. A dropped
# title is printed too, so "is it kept" must be asked of the right section,
# never of the whole output.
section() { # $1=header
	awk -v h="$1:" '$0 == h { f = 1; next } $0 == "" { f = 0 } f' "$TH/run.out"
}
kept()    { section keeping; }
dropped() { section dropping; }

listing() { # $1=dir — the reference files in it, sorted, space-joined
	ls "$1" | sort | tr '\n' ' '
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
	assert_contains "$(kept)" "1: current" \
		"a reference with no .title falls back to the transcript's custom-title"
	assert_contains "$(kept)" "2: big, titled near the end" \
		"the fallback title is read from the tail of a 400KB transcript"
	drop_store
}

t_reference_title_wins() {
	new_store
	mk_tx s-pin 2026-09-16T04:00:00.000Z "3: stale transcript title" 0 0
	mk_tx s-plain 2026-09-16T03:00:00.000Z "4: stale transcript title" 0 0
	mk_ref s-pin "* pinned in the sidebar"
	mk_ref s-plain "renamed in the sidebar"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "* pinned in the sidebar" \
		"the reference's pin wins over the transcript's number"
	assert_contains "$(dropped)" "renamed in the sidebar" \
		"the reference's unnumbered title wins over the transcript's number"
	assert_not_contains "$out" "stale transcript title" \
		"the transcript's title is not used when the reference has one"
	drop_store
}

t_title_beyond_window_is_kept() {
	# 400KB of filler AFTER the custom-title pushes it past the 256K window. The
	# sidebar still shows the number, so the session must be kept.
	new_store
	mk_tx s-far 2026-09-16T04:00:00.000Z "17: mux and serena" 0 400
	mk_tx s-near 2026-09-16T03:00:00.000Z "1: visible" 0 0
	mk_ref s-far "17: mux and serena"; mk_ref s-near "1: visible"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_no_shim_violation
	assert_contains "$(kept)" "17: mux and serena" \
		"a numbered row is kept though its transcript's custom-title is beyond the tail window"
	assert_contains "$(kept)" "1: visible" "the other numbered row is kept"
	drop_store
}

t_untouched_session_is_decided_every_run() {
	new_store
	mk_tx s-a 2026-09-10T00:00:00.000Z "" 0 0
	mk_tx s-b 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-a "1: alpha"; mk_ref s-b "2: bravo"
	run >/dev/null
	assert_eq "$(run_rc)" "0" "run 1 applies"

	# A sidebar row whose transcript was last written long before run 1, and which
	# no earlier run ever ruled on.
	mk_tx s-17 2026-03-01T00:00:00.000Z "" 0 0
	mk_ref s-17 "17: mux and serena"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "17: mux and serena" \
		"a numbered row with an old, untouched transcript is kept"
	assert_contains "$(kept)" "1: alpha" "#1 is kept again with its transcript untouched"
	assert_contains "$(kept)" "2: bravo" "#2 is kept again with its transcript untouched"
	assert_eq "$(listing "$WS")" "local_s-17.json local_s-a.json local_s-b.json " \
		"all three rows survive the second applied run"
	drop_store
}

t_no_cache_file() {
	new_store
	mk_tx s-old 2026-03-01T00:00:00.000Z "" 0 0
	mk_tx s-new 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-old "1: old transcript"; mk_ref s-new "2: new transcript"
	# A cache file with a floor above every transcript and a keep row for a
	# session that has no reference. Neither may affect the run.
	printf 'version\t2\nfloor\t4102444800\t2100-01-01T00:00:00.000Z\nkeep\t3\ts-gone\t2026-01-01T00:00:00.000Z\t3: gone\n' \
		>"$TH/.claude-prune-cache.tsv"
	local before; before="$(cksum <"$TH/.claude-prune-cache.tsv")"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "1: old transcript" "a cache floor above every transcript filters nothing"
	assert_contains "$(kept)" "2: new transcript" "the newer row is kept"
	assert_not_contains "$out" "3: gone" "a cached keep row is not carried"
	assert_eq "$(cksum <"$TH/.claude-prune-cache.tsv")" "$before" "the cache file is not written"

	rm -f "$TH/.claude-prune-cache.tsv"
	run >/dev/null
	assert_eq "$([ -e "$TH/.claude-prune-cache.tsv" ] && echo present || echo absent)" "absent" \
		"an applied run creates no cache file"
	drop_store
}

t_numbering_first_seen_wins() {
	new_store
	mk_tx s-old3 2026-09-10T00:00:00.000Z "" 0 0
	mk_tx s-new3 2026-09-16T00:00:00.000Z "" 0 0
	mk_tx s-star 2026-09-15T00:00:00.000Z "" 0 0
	mk_tx s-plain 2026-09-14T00:00:00.000Z "" 0 0
	mk_ref s-old3 "3: older three"
	mk_ref s-new3 "3-1: newer three"
	mk_ref s-star "  * leading space pin"
	mk_ref s-plain "no number here"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "3-1: newer three" "the newest holder of a number wins"
	assert_not_contains "$(kept)" "3: older three" "the older reuse of that number is not kept"
	assert_contains "$(dropped)" "3: older three" "the older reuse is listed as dropped"
	assert_contains "$(dropped)" "#3 is held by a newer session" "with the reason it lost"
	assert_contains "$(kept)" "* leading space pin" "a pin survives leading whitespace"
	assert_contains "$(dropped)" "no number here" "an unnumbered row is listed as dropped"
	assert_contains "$(dropped)" "(unnumbered)" "with the reason it was dropped"
	drop_store
}

t_order_falls_back_to_reference() {
	new_store
	mk_tx s-tx5 2026-09-10T00:00:00.000Z "" 0 0
	mk_ref s-tx5 "5: has a transcript"
	# No transcript at all; .lastActivityAt 1789862400000 is 2026-09-20T00:00:00Z
	# in milliseconds, which is newer than the other #5's last entry.
	mk_ref s-notx5 "5: no transcript yet" 1789862400000
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "5: no transcript yet" \
		"a row with no transcript is ordered by its reference's .lastActivityAt"
	assert_contains "$(dropped)" "5: has a transcript" "the older #5 is dropped"
	drop_store
}

t_unreferenced_transcripts_are_ignored() {
	new_store
	mk_tx s-orphan 2026-09-20T00:00:00.000Z "1: orphan transcript" 0 0
	mk_tx s-ref 2026-09-10T00:00:00.000Z "" 0 0
	mk_ref s-ref "1: referenced"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "1: referenced" "a transcript with no reference cannot claim a number"
	assert_not_contains "$out" "orphan transcript" "a transcript with no reference is never reported"
	drop_store
}

t_dry_run_lists_drops_and_unlinks_nothing() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-drop "scratch session"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(dropped)" "scratch session" "the dropped row is listed by title"
	assert_contains "$out" "[dry run]" "the run stops as a dry run"
	assert_eq "$(listing "$WS")" "local_s-drop.json local_s-keep.json " "--dry-run unlinks nothing"
	drop_store
}

t_no_backups() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-drop ""

	local dry; dry="$(run --dry-run)"
	assert_contains "$dry" "deleted outright" "the plan says dropped references are deleted"

	local out; out="$(run)"
	assert_clean_run "$out"
	local found; found="$(ls -d "$TH"/claude-deleted-session-refs-* 2>/dev/null | wc -l | tr -d ' ')"
	assert_eq "$found" "0" "no backup directory is created"
	assert_eq "$(listing "$WS")" "local_s-keep.json " "the dropped reference is gone"
	drop_store
}

t_removed_options_are_rejected() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"

	run --no-backup >/dev/null 2>&1
	assert_eq "$(run_rc)" "2" "--no-backup is rejected as an unknown option"
	run --limit 5 >/dev/null 2>&1
	assert_eq "$(run_rc)" "2" "--limit is rejected as an unknown option"
	drop_store
}

t_transcripts_are_never_written() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-drop ""
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
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep" 5; mk_ref s-drop "" 5
	# The higher lastActivityAt wins, so WS2's copy is the inode the app is
	# treated as writing to and the one every dir must end up pointing at.
	mk_ref s-keep "1: keep" 9 "$WS2"
	local winner; winner="$(stat -f '%i' "$WS2/local_s-keep.json")"

	local out; out="$(run)"
	assert_clean_run "$out"

	assert_eq "$(listing "$WS")" "local_s-keep.json " "the first dir holds exactly the keeper"
	assert_eq "$(listing "$WS2")" "local_s-keep.json " "the second dir holds exactly the keeper"
	assert_eq "$(stat -f '%i' "$WS/local_s-keep.json")" \
		"$(stat -f '%i' "$WS2/local_s-keep.json")" "both dirs point at ONE inode"
	# Agreeing with each other is not enough: staging with cp mints a FRESH inode
	# that both dirs would agree on just as happily, while orphaning the one the
	# app holds open. The surviving inode must be the ORIGINAL.
	assert_eq "$(stat -f '%i' "$WS2/local_s-keep.json")" "$winner" \
		"the surviving inode is the ORIGINAL winner, not a fresh copy"
	drop_store
}

# ---------------------------------------------------------------- runner

TESTS="
t_tail_only_reads
t_reference_title_wins
t_title_beyond_window_is_kept
t_untouched_session_is_decided_every_run
t_no_cache_file
t_numbering_first_seen_wins
t_order_falls_back_to_reference
t_unreferenced_transcripts_are_ignored
t_dry_run_lists_drops_and_unlinks_nothing
t_no_backups
t_removed_options_are_rejected
t_transcripts_are_never_written
t_relink_shares_one_inode
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
