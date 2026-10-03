#!/usr/bin/env bash
#
# test-prune-claude-sessions.sh — prove the constraints of
# plan://claude_desktop/prune_reference_authority and
# plan://claude_desktop/prune_pin_newest_write against a synthetic store.
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
#   - a session whose reference copies were written at the same time with
#     different titles is kept if any of them would keep it;
#   - a session is decided on every run however old its transcript is and
#     whatever earlier runs did, and no cache file is read or written;
#   - a transcript with no reference can never claim a number;
#   - every dropped row is printed with its reason.
#
# The exception is a retitle: a session is decided by its most recently written
# reference copy, so a '*' or a number removed or changed in one sidebar is not
# restored from an older copy in another workspace dir.
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

# touch_ref <cli> <iso-ts> [dir]
#
# Sets a reference's mtime: when that copy was last WRITTEN, which is what
# decides a session's pin.
touch_ref() {
	local cli="$1" ts="$2" dir="${3:-$WS}"
	TZ=UTC touch -t "$(touch_stamp "$ts")" "$dir/local_$cli.json"
}

# run() is invoked as $(run ...), so its body executes in a SUBSHELL and any
# variable it sets is lost on return. The status goes to a file instead.
#
# The script runs under /bin/bash, the stock macOS 3.2 it is written for, never
# whichever newer bash the shebang would find first on PATH.
run() { # args passed through; echoes combined output, records the exit status
	HOME="$TH" PATH="$TH/bin:$PATH" /bin/bash "$SCRIPT" "$@" >"$TH/run.out" 2>&1
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

# Every entry under the transcript store with its type, size and mtime, then a
# checksum of every file, so a file created, removed or rewritten anywhere in the
# store changes the snapshot.
store_snapshot() {
	(
		cd "$TH/.claude/projects" &&
			find . -print | sort | while IFS= read -r p; do stat -f '%N %HT %z %m' "$p"; done &&
			find . -type f -print | sort | xargs cksum
	)
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

t_fallback_title_is_tail_only() {
	# The fallback reads the transcript's tail and nothing more. With no .title on
	# the reference and the custom-title pushed 400KB past the window, a whole-file
	# read would find the title, so finding it means one was reintroduced.
	new_store
	mk_tx s-far 2026-09-16T04:00:00.000Z "9: buried past the window" 0 400
	mk_tx s-near 2026-09-16T03:00:00.000Z "1: visible" 0 0
	mk_ref s-far; mk_ref s-near
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_no_shim_violation
	assert_not_contains "$out" "9: buried past the window" \
		"a fallback title beyond the tail window is NOT found (no whole-file read)"
	assert_contains "$(kept)" "1: visible" "the in-window fallback title is still found"
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
	# A second project dir, so a write anywhere in the store shows, not only one
	# beside the transcripts the run reads.
	mkdir -p "$TH/.claude/projects/-proj-b"
	printf '{"type":"user","timestamp":"2026-09-01T00:00:00.000Z","text":"hello"}\n' \
		>"$TH/.claude/projects/-proj-b/s-other.jsonl"
	local before after
	before="$(store_snapshot)"
	local out; out="$(run)"
	assert_clean_run "$out"
	after="$(store_snapshot)"
	assert_eq "$after" "$before" "nothing under the transcript store was created, removed or changed"
	drop_store
}

t_relink_shares_one_inode() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep" 5; mk_ref s-drop "" 5
	# Both copies were written at the same time, so the higher lastActivityAt
	# wins: WS2's copy is the inode the app is treated as writing to and the one
	# every dir must end up pointing at.
	mk_ref s-keep "1: keep" 9 "$WS2"
	touch_ref s-keep 2026-09-16T01:00:00.000Z
	touch_ref s-keep 2026-09-16T01:00:00.000Z "$WS2"
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

t_order_is_last_entry_not_mtime() {
	new_store
	mk_tx s-old 2026-09-10T00:00:00.000Z "" 0 0
	mk_tx s-new 2026-09-16T00:00:00.000Z "" 0 0
	# Opening a session bumps its mtime without adding an entry.
	touch "$TH/.claude/projects/-proj-a/s-old.jsonl"
	mk_ref s-old "3: older entry, newer mtime"; mk_ref s-new "3: newer entry"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "3: newer entry" "the newer LAST ENTRY wins the number"
	assert_contains "$(dropped)" "3: older entry, newer mtime" "a newer mtime does not"
	drop_store
}

t_timestamp_beyond_window_reads_whole_file() {
	# One final line longer than the window: the tail holds no timestamp, so the
	# whole-file fallback is the only way to order this session by its entry.
	new_store
	printf '{"type":"user","timestamp":"2026-09-20T00:00:00.000Z","text":"%s"}\n' \
		"$("$REAL_PERL" -e 'print "x" x 300000')" >"$TH/.claude/projects/-proj-a/s-long.jsonl"
	mk_tx s-short 2026-09-16T00:00:00.000Z "" 0 0
	mk_ref s-long "6: final line longer than the window"; mk_ref s-short "6: short"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_no_shim_violation
	assert_contains "$(kept)" "6: final line longer than the window" \
		"the timestamp of a final line longer than the window is still read"
	assert_contains "$(dropped)" "6: short" "so the older #6 loses"
	drop_store
}

t_only_referenced_transcripts_are_read() {
	new_store
	mk_tx s-ref 2026-09-10T00:00:00.000Z "" 0 0
	mk_tx s-orphan 2026-09-20T00:00:00.000Z "" 0 0
	mk_ref s-ref "1: referenced"
	# A perl shim that records every path the tail reader is handed on stdin.
	printf '#!/bin/bash\ntee -a "%s" | "%s" "$@"\n' "$TH/perl-stdin" "$REAL_PERL" >"$TH/bin/perl"
	chmod +x "$TH/bin/perl"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(cat "$TH/perl-stdin")" "s-ref.jsonl" "the referenced transcript is read"
	assert_not_contains "$(cat "$TH/perl-stdin")" "s-orphan.jsonl" "a transcript with no reference is never read"
	drop_store
}

t_applied_run_lists_drops() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-drop "scratch session"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$(dropped)" "scratch session" "an applied run lists the row it drops"
	assert_eq "$(listing "$WS")" "local_s-keep.json " "and the listed row is the one unlinked"
	drop_store
}

t_reference_without_session_id_is_decided() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"
	"$REAL_JQ" -nc '{lastActivityAt:1,title:"7: no session id"}' >"$WS/local_nocli-a.json"
	"$REAL_JQ" -nc '{lastActivityAt:1,title:"scratch with no session id"}' >"$WS/local_nocli-b.json"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "7: no session id" "a numbered reference with no .cliSessionId is kept"
	assert_contains "$(dropped)" "scratch with no session id" \
		"an unnumbered reference with no .cliSessionId is listed as dropped"
	drop_store
}

t_unparseable_reference_aborts_before_unlinking() {
	new_store
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"
	printf '{not json' >"$WS/local_broken.json"
	run >/dev/null 2>&1

	assert_eq "$([ "$(run_rc)" = 0 ] && echo zero || echo nonzero)" "nonzero" \
		"a reference jq cannot parse fails the run"
	assert_eq "$(listing "$WS")" "local_broken.json local_s-keep.json " "and nothing is unlinked"
	drop_store
}

t_any_newest_copy_can_keep_a_session() {
	# Each session below has a reference in two workspace dirs as two inodes whose
	# titles differ but which were written at the same time, so neither is the
	# newer write. The session is kept if either would keep it, and every dir ends
	# up sharing that copy.
	new_store
	mk_tx s-newer 2026-09-16T05:00:00.000Z "" 0 0
	mk_ref s-newer "4: newer session"
	# Numbered in one sidebar, unnumbered in the copy with the higher .lastActivityAt.
	mk_tx s-num 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-num "17: numbered in one sidebar" 5
	mk_ref s-num "scratch in the other" 9 "$WS2"
	# Pinned in one sidebar, numbered in the copy with the higher .lastActivityAt.
	mk_tx s-pin 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-pin "* pinned in one sidebar" 5
	mk_ref s-pin "12: numbered in the other" 9 "$WS2"
	# The higher .lastActivityAt copy's number is held by a newer session; the
	# other copy's is free.
	mk_tx s-two 2026-09-16T02:00:00.000Z "" 0 0
	mk_ref s-two "8: free in one sidebar" 5
	mk_ref s-two "4: taken in the other" 9 "$WS2"
	local s
	for s in s-num s-pin s-two; do
		touch_ref "$s" 2026-09-16T01:00:00.000Z
		touch_ref "$s" 2026-09-16T01:00:00.000Z "$WS2"
	done
	local num_inode pin_inode two_inode
	num_inode="$(stat -f '%i' "$WS/local_s-num.json")"
	pin_inode="$(stat -f '%i' "$WS/local_s-pin.json")"
	two_inode="$(stat -f '%i' "$WS/local_s-two.json")"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "17: numbered in one sidebar" \
		"a numbered copy keeps the session over an unnumbered one written at the same time"
	assert_contains "$(kept)" "* pinned in one sidebar" \
		"a pinned copy keeps the session over a numbered one written at the same time"
	assert_contains "$(kept)" "8: free in one sidebar" \
		"a copy whose number is free keeps the session when the other's number is held"
	assert_eq "$(dropped)" "" "no session is dropped"
	assert_eq "$(stat -f '%i' "$WS2/local_s-num.json")" "$num_inode" \
		"every dir shares the numbered copy's inode"
	assert_eq "$(stat -f '%i' "$WS2/local_s-pin.json")" "$pin_inode" \
		"every dir shares the pinned copy's inode"
	assert_eq "$(stat -f '%i' "$WS2/local_s-two.json")" "$two_inode" \
		"every dir shares the inode of the copy whose number was free"
	drop_store
}

t_newest_write_decides_the_pin() {
	# Each session below has a reference in two workspace dirs as two inodes, and
	# the copy written last (by mtime) is the sidebar edit to honour. The older
	# copy carries the higher .lastActivityAt every time, so it is the write and
	# not the activity that decides the pin.
	new_store
	mk_tx s-newer 2026-09-16T05:00:00.000Z "" 0 0
	mk_ref s-newer "4: newer session"
	# The newest write removed the '*' and left no number.
	mk_tx s-unpin 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-unpin "* starred once" 9
	mk_ref s-unpin "starred once" 5 "$WS2"
	touch_ref s-unpin 2026-09-16T01:00:00.000Z
	touch_ref s-unpin 2026-09-16T02:00:00.000Z "$WS2"
	# The newest write swapped the '*' for a free number.
	mk_tx s-renum 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-renum "* starred, then numbered" 9
	mk_ref s-renum "7: starred, then numbered" 5 "$WS2"
	touch_ref s-renum 2026-09-16T01:00:00.000Z
	touch_ref s-renum 2026-09-16T02:00:00.000Z "$WS2"
	# The newest write added the '*'.
	mk_tx s-pin 2026-09-16T02:00:00.000Z "" 0 0
	mk_ref s-pin "not yet starred" 9
	mk_ref s-pin "* starred by the newest write" 5 "$WS2"
	touch_ref s-pin 2026-09-16T01:00:00.000Z
	touch_ref s-pin 2026-09-16T02:00:00.000Z "$WS2"
	local renum_inode pin_inode
	renum_inode="$(stat -f '%i' "$WS2/local_s-renum.json")"
	pin_inode="$(stat -f '%i' "$WS2/local_s-pin.json")"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_not_contains "$(kept)" "starred once" \
		"a session whose newest write removed the '*' is not kept on an older pinned copy"
	assert_contains "$(dropped)" "* starred once" "the older pinned copy is listed as dropped"
	assert_contains "$(dropped)" "(retitled by a newer write)" "as retitled by the newer write"
	assert_contains "$(kept)" "7: starred, then numbered" \
		"a session whose newest write swapped the '*' for a free number is kept on that number"
	assert_not_contains "$(kept)" "* starred, then numbered" "and not on its older pinned copy"
	assert_contains "$(kept)" "* starred by the newest write" \
		"a session whose newest write added the '*' is kept pinned"
	local want="local_s-newer.json local_s-pin.json local_s-renum.json "
	assert_eq "$(listing "$WS")" "$want" "the unpinned session is unlinked from the first dir"
	assert_eq "$(listing "$WS2")" "$want" "and from the second"
	assert_eq "$(stat -f '%i' "$WS/local_s-renum.json")" "$renum_inode" \
		"every dir shares the numbered copy's inode"
	assert_eq "$(stat -f '%i' "$WS/local_s-pin.json")" "$pin_inode" \
		"every dir shares the newest pinned copy's inode"
	drop_store
}

t_newest_write_decides_the_number() {
	# As t_newest_write_decides_the_pin, for the number: the copy written last
	# decides, and the older copy carries the higher .lastActivityAt every time.
	new_store
	mk_tx s-newer 2026-09-16T05:00:00.000Z "" 0 0
	mk_ref s-newer "4: newer session"
	# The newest write removed the number.
	mk_tx s-unnum 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-unnum "17: numbered once" 9
	mk_ref s-unnum "numbered once" 5 "$WS2"
	touch_ref s-unnum 2026-09-16T01:00:00.000Z
	touch_ref s-unnum 2026-09-16T02:00:00.000Z "$WS2"
	# The newest write changed a free number to one a newer session holds.
	mk_tx s-taken 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-taken "8: free before the edit" 9
	mk_ref s-taken "4: taken by the edit" 5 "$WS2"
	touch_ref s-taken 2026-09-16T01:00:00.000Z
	touch_ref s-taken 2026-09-16T02:00:00.000Z "$WS2"
	# The newest write numbered the session.
	mk_tx s-num 2026-09-16T02:00:00.000Z "" 0 0
	mk_ref s-num "not yet numbered" 9
	mk_ref s-num "12: numbered by the newest write" 5 "$WS2"
	touch_ref s-num 2026-09-16T01:00:00.000Z
	touch_ref s-num 2026-09-16T02:00:00.000Z "$WS2"
	local num_inode; num_inode="$(stat -f '%i' "$WS2/local_s-num.json")"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_not_contains "$(kept)" "numbered once" \
		"a session whose newest write removed the number is not kept on an older numbered copy"
	assert_contains "$(dropped)" "17: numbered once" "the older numbered copy is listed as dropped"
	assert_not_contains "$(kept)" "8: free before the edit" \
		"a session whose newest write took a held number is not kept on an older copy's free one"
	assert_contains "$(dropped)" "#4 is held by a newer session" "the newest write's number is the one that lost"
	assert_contains "$(dropped)" "(retitled by a newer write)" "and the older copies are listed as retitled"
	assert_contains "$(kept)" "12: numbered by the newest write" \
		"a session whose newest write numbered it is kept"
	local want="local_s-newer.json local_s-num.json "
	assert_eq "$(listing "$WS")" "$want" "the dropped sessions are unlinked from the first dir"
	assert_eq "$(listing "$WS2")" "$want" "and from the second"
	assert_eq "$(stat -f '%i' "$WS/local_s-num.json")" "$num_inode" \
		"every dir shares the newest numbered copy's inode"
	drop_store
}

t_mtime_is_read_with_usr_bin_stat() {
	# A stat earlier on PATH than /usr/bin — GNU coreutils' reads -f as
	# --file-system — must not be the one that reads a reference's mtime.
	new_store
	cat >"$TH/bin/stat" <<'SHIM'
#!/bin/bash
echo "stat: not the stat this script must call" >&2
exit 1
SHIM
	chmod +x "$TH/bin/stat"
	mk_tx s-newer 2026-09-16T05:00:00.000Z "" 0 0
	mk_ref s-newer "4: newer session"
	mk_tx s-unpin 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-unpin "* starred once" 9
	mk_ref s-unpin "starred once" 5 "$WS2"
	touch_ref s-unpin 2026-09-16T01:00:00.000Z
	touch_ref s-unpin 2026-09-16T02:00:00.000Z "$WS2"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(dropped)" "* starred once" \
		"the newest write still decides with another stat first on PATH"
	drop_store
}

t_nothing_kept_refuses_to_unlink() {
	# A store in which every session is dropped is refused before staging.
	new_store
	mk_tx s-a 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-a "scratch one"
	mk_ref s-a "scratch one" 1 "$WS2"
	local out; out="$(run)"

	assert_eq "$(run_rc)" "1" "a run that would keep nothing exits 1"
	assert_contains "$out" "nothing to keep" "and says why"
	assert_eq "$(listing "$WS")$(listing "$WS2")" "local_s-a.json local_s-a.json " \
		"and unlinks nothing"
	drop_store
}

t_keepers_are_copied_when_ln_fails() {
	# ln failing (a cross-device stash) falls back to cp -p for staging and, per
	# file, for the relink; every dir still holds the keeper and nothing else.
	new_store
	printf '#!/bin/bash\nexit 1\n' >"$TH/bin/ln"; chmod +x "$TH/bin/ln"
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_tx s-drop 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-keep "1: keep" 1 "$WS2"
	mk_ref s-drop "scratch"; mk_ref s-drop "scratch" 1 "$WS2"
	local out; out="$(run)"

	assert_clean_run "$out"
	assert_contains "$out" "cross-device, had to copy local_s-keep.json" "staging falls back to cp"
	assert_eq "$(listing "$WS")" "local_s-keep.json " "the first dir holds the keeper only"
	assert_eq "$(listing "$WS2")" "local_s-keep.json " "and so does the second"
	assert_eq "$("$REAL_JQ" -r .title "$WS2/local_s-keep.json")" "1: keep" "the copied keeper is intact"
	drop_store
}

t_no_keeper_staged_refuses_to_unlink() {
	# When neither ln nor cp can stage any keeper, nothing is unlinked.
	new_store
	printf '#!/bin/bash\nexit 1\n' >"$TH/bin/ln"; chmod +x "$TH/bin/ln"
	printf '#!/bin/bash\nexit 1\n' >"$TH/bin/cp"; chmod +x "$TH/bin/cp"
	mk_tx s-keep 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-keep "1: keep"; mk_ref s-keep "1: keep" 1 "$WS2"
	local out; out="$(run)"

	assert_eq "$(run_rc)" "1" "a run that staged no keeper exits 1"
	assert_contains "$out" "no keeper could be staged" "and says why"
	assert_eq "$(listing "$WS")$(listing "$WS2")" "local_s-keep.json local_s-keep.json " \
		"and unlinks nothing"
	drop_store
}

t_fallback_title_without_timestamp() {
	# A transcript holding a custom-title and no timestamp anywhere, behind a
	# reference with no .title. The title still reaches the reference, and the
	# session is ordered by the reference's .lastActivityAt: 1789862400000 is
	# 2026-09-20T00:00:00Z in milliseconds, newer than the other #2's last entry.
	new_store
	"$REAL_JQ" -nc '{type:"custom-title",customTitle:"2: titled, never stamped"}' \
		>"$TH/.claude/projects/-proj-a/s-nostamp.jsonl"
	mk_ref s-nostamp "" 1789862400000
	mk_tx s-old2 2026-09-10T00:00:00.000Z "" 0 0
	mk_ref s-old2 "2: older"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_no_shim_violation
	assert_contains "$(kept)" "2: titled, never stamped" \
		"a transcript with no timestamp still supplies the fallback title"
	assert_contains "$(dropped)" "2: older" "and its session is ordered by .lastActivityAt"
	drop_store
}

t_dropped_session_lists_every_title() {
	# A session no copy keeps loses a sidebar row in every workspace dir, so each
	# distinct title its copies carry is listed: the newest write's with its
	# reason, an older copy's as retitled. Copies sharing a title share one line,
	# whichever write they came from.
	new_store
	mk_tx s-newer 2026-09-16T05:00:00.000Z "" 0 0
	mk_ref s-newer "4: newer session"
	mk_tx s-split 2026-09-16T04:00:00.000Z "" 0 0
	mk_ref s-split "4: held in one sidebar" 9
	mk_ref s-split "scratch in the other" 5 "$WS2"
	touch_ref s-split 2026-09-16T02:00:00.000Z
	touch_ref s-split 2026-09-16T01:00:00.000Z "$WS2"
	mk_tx s-same 2026-09-16T03:00:00.000Z "" 0 0
	mk_ref s-same "same scratch everywhere" 5
	mk_ref s-same "same scratch everywhere" 9 "$WS2"
	touch_ref s-same 2026-09-16T02:00:00.000Z
	touch_ref s-same 2026-09-16T01:00:00.000Z "$WS2"
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(dropped)" "4: held in one sidebar" "the newest copy's title is listed"
	assert_contains "$(dropped)" "#4 is held by a newer session" "with its reason"
	assert_contains "$(dropped)" "scratch in the other" "the older copy's title is listed too"
	assert_contains "$(dropped)" "(retitled by a newer write)" "as retitled by the newer write"
	assert_eq "$(dropped | grep -c 'same scratch everywhere')" "1" \
		"an older copy sharing the newest copy's title is listed once"
	assert_contains "$out" "dropping: 2   (sessions)" "the count is of sessions"
	drop_store
}

t_transcripts_are_opened_read_only() {
	# With every transcript stripped of write permission, an open for writing
	# fails, so the run still reading their titles and timestamps shows each one
	# was opened for reading only.
	new_store
	mk_tx s-a 2026-09-16T04:00:00.000Z "1: titled in the transcript" 0 0
	mk_tx s-b 2026-09-10T00:00:00.000Z "" 0 0
	mk_ref s-a; mk_ref s-b "1: older"
	chmod a-w "$TH/.claude/projects/-proj-a/"*.jsonl
	local out; out="$(run --dry-run)"

	assert_clean_run "$out"
	assert_contains "$(kept)" "1: titled in the transcript" "a read-only transcript's title is read"
	assert_contains "$(dropped)" "1: older" "and its last entry orders the session"
	drop_store
}

t_stock_bash_constructs_only() {
	# Every other test runs the script under /bin/bash 3.2, which rejects an
	# associative array or mapfile when it reaches one but runs process
	# substitution, so the source is read for all three.
	local hits; hits="$("$REAL_GREP" -nE '<\(|>\(|declare -A|mapfile|readarray' "$SCRIPT")"
	assert_eq "$hits" "" "no associative array, mapfile or process substitution in the script"
}

# ---------------------------------------------------------------- runner

TESTS="
t_tail_only_reads
t_fallback_title_is_tail_only
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
t_order_is_last_entry_not_mtime
t_timestamp_beyond_window_reads_whole_file
t_only_referenced_transcripts_are_read
t_applied_run_lists_drops
t_reference_without_session_id_is_decided
t_unparseable_reference_aborts_before_unlinking
t_any_newest_copy_can_keep_a_session
t_fallback_title_without_timestamp
t_stock_bash_constructs_only
t_dropped_session_lists_every_title
t_transcripts_are_opened_read_only
t_newest_write_decides_the_pin
t_newest_write_decides_the_number
t_mtime_is_read_with_usr_bin_stat
t_nothing_kept_refuses_to_unlink
t_keepers_are_copied_when_ln_fails
t_no_keeper_staged_refuses_to_unlink
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
