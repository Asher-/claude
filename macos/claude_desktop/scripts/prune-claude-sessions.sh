#!/usr/bin/env bash
#
# prune-claude-sessions.sh — collapse the Claude Desktop sidebar to the most recent
# batch of NUMBERED sessions plus every PINNED one.
#
# EVERY SIDEBAR ROW IS DECIDED, EVERY RUN
#   The sidebar entries are local_*.json under
#     claude-code-sessions/<account>/<workspace>/
#   They are ~630-byte REFERENCES to a transcript, joined by .cliSessionId:
#     ~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl
#   They are derived artifacts: this script unlinks and re-links them freely, and
#   deleting one removes a sidebar row without touching the conversation.
#   Transcripts are READ ONLY — this script never writes one, ever.
#
#   Each run reads every reference and rules on each one from scratch. Nothing
#   is carried between runs, so there is no saved state for a session to fall
#   out of. The references are a few dozen small files and each costs one tail
#   read of its transcript, so there is nothing to save by skipping any.
#
#   Skipping them is how a session was lost. A version that walked the transcript
#   store kept a watermark and a cached keep set so it could ignore transcripts
#   older than its last run, and read each title from the transcript's tail. On
#   2026-10-02 it dropped a session the sidebar showed as "17: ...". The cause was
#   never established — that session's custom-title was later measured 984 bytes
#   from the end of its transcript, well inside the window — so this version takes
#   neither input: it keeps no state between runs and reads the title from the
#   reference.
#
# THE TITLE IS THE REFERENCE'S .title
#   That is the title the sidebar shows and the one you edit, so the number and
#   pin are read from it, whole. Only a reference with no .title falls back to
#   the last custom-title in its transcript's tail.
#
#   A session whose copies in different workspace dirs carry different titles
#   shows a different title in each sidebar, so no one copy speaks for it. Every
#   copy is read, and the session is kept if any copy would keep it: a pinned
#   copy, or a numbered copy whose number no newer session holds.
#
# ORDER IS THE TRANSCRIPT'S LAST ENTRY, NEVER FILE MTIME
#   mtime is when the file was last WRITTEN, which includes the app merely
#   opening a session to display it. Opening the app to check the sidebar after
#   a run therefore bumped old sessions above new ones, and the next run handed
#   their numbers back to the previous batch — verifying the output corrupted
#   the input. Measured: an old "1: Hermeneutic lens set" carried an mtime newer
#   than every session in the live batch while its last entry was six hours old.
#
#   The last entry's own timestamp cannot move except by a new entry. That is
#   the ordering key. A session whose transcript has no timestamp falls back to
#   its reference's .lastActivityAt.
#
#   Reading recency from the references alone was the first bug. A reference is
#   a per-account copy: the same session can exist in two workspace dirs as two
#   inodes whose .title and .lastActivityAt have drifted apart, so "most recent"
#   computed from them was whichever copy you happened to look at.
#
# NEVER READ A WHOLE TRANSCRIPT
#   The last timestamp lives at the END of the file, and ONE 256K tail read per
#   transcript gets it, together with the fallback title, out of the same buffer.
#   Transcripts run to 16MB; the store is 9.5GB.
#
#   The window is also why the title is not read from the transcript first: a
#   custom-title is written when the session is renamed, and anything the
#   session writes afterwards pushes it back toward and past the window's edge.
#
#   An earlier version read every candidate WHOLE, with a grep+tail+jq fork per
#   session: 33ms per session against 0.35ms for the tail read, 94x, and it
#   dominated the run.
#
# HOW A SESSION NUMBER IS READ
#   The LEADING RUN OF DIGITS of the title, whatever follows it. Not "N:" — just
#   \d+. So all of these are session 7:
#
#     "7: Go call folds"      "7-1: Go call folds"      "7*: Go call folds"
#
#   Retitling a session "7-1: ..." is how you pull it into the current batch by
#   hand. A leading '*' PINS a session: kept regardless of number or depth.
#   Anything else is unnumbered and is never kept.
#
# THE WALK
#   Every session that has a reference, newest-first BY LAST ENTRY, trying its
#   copies pinned first, then numbered, newest copy first within each, until one
#   keeps it:
#
#     - a leading '*'  -> keep
#     - a number seen for the FIRST time -> keep
#     - a number already seen -> an older batch's reuse of it, try the next copy
#     - anything else -> try the next copy
#
#   A session no copy keeps is dropped.
#
#   Numbering restarts per batch and the walk is newest-first, so first-seen wins
#   and the older batch's #3 loses to the current #3 without any extra machinery.
#
#   Every dropped row is printed with its reason before anything is unlinked, and
#   --dry-run stops there.
#
# THE RELINK
#   One inode per session, hardlinked into every workspace dir. That is the whole
#   point of the layout: the app writes a reference in place, and one write is
#   then visible in every account.
#
#   So keepers are staged with ln, NEVER cp. Staging with cp mints a fresh inode
#   and silently orphans the one the app is writing to — which is how the store
#   ended up holding two divergent copies of twelve sessions under one basename.
#   If a keeper exists in several dirs as several inodes, the copy that kept it
#   becomes the single inode for all of them. Among copies whose titles keep it
#   alike, that is the one with the greatest .lastActivityAt. Where the copies'
#   titles differ, it is the pinned or numbered copy, so the relink never puts an
#   unnumbered title into a sidebar that showed the session numbered or pinned.
#
#   DROPPED REFERENCES ARE NOT BACKED UP. They are ~630-byte pointers and the
#   transcript they point at is untouched, so a dropped row costs a sidebar entry
#   and nothing else. The backups were their own problem: a dated directory per
#   run that nothing ever reaped, which a per-file jq scan then swept on every
#   later run — all of it, past every match — looking for rows to resurrect.
#
# RUN IT FROM A NORMAL TERMINAL, NOT INSIDE CLAUDE CODE.
#   Writes to ~/Library/Application Support/Claude are blocked from within Claude
#   Code by the non-approvable block-claude-app-config-edits hook.
#
#   Leaving the Claude app open is fine. Restart it if the sidebar doesn't refresh.
#
# Written for stock macOS /bin/bash (3.2), /usr/bin/jq and /usr/bin/perl.

set -euo pipefail
shopt -s nullglob

APP="$HOME/Library/Application Support/Claude/claude-code-sessions"
PROJECTS="$HOME/.claude/projects"
APPLY=1
DIR=""

# One tail read per transcript serves both the timestamp and the fallback title.
# See NEVER READ A WHOLE TRANSCRIPT.
TAIL_WINDOW=262144

usage() {
	cat <<'EOF'
prune-claude-sessions.sh — keep the newest numbered batch plus every pin.

Usage:
  prune-claude-sessions.sh                  prune and relink
  prune-claude-sessions.sh --dry-run        show the plan, write nothing

Options:
      --dir PATH   explicit <account>/<workspace> dir. The store root is
                   PATH/../.., and the relink covers every dir under it.
      --dry-run    print the plan and write nothing
  -h, --help       show this text

A session's number is the LEADING RUN OF DIGITS of its sidebar title, whatever
follows: "7:", "7-1:" and "7*:" are all session 7. A leading '*' pins a session,
which keeps it regardless of number or how far back it sits.

Every sidebar row is decided on every run; nothing is cached between runs.
Order comes from the last entry INSIDE each transcript, never from file mtime —
opening a session in the app bumps its mtime and would otherwise hand its number
back to an older batch. Transcripts under ~/.claude/projects/ are never written,
and only their last 256K is ever read.

Every dropped row is listed with its reason. Dropped sidebar references are
deleted, not backed up — they are pointers, and the conversation they point at
is untouched.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dir)
		[ $# -ge 2 ] || { echo "error: $1 needs a path" >&2; exit 2; }
		DIR="${2%/}"
		shift 2
		;;
	--dry-run) APPLY=0; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "error: perl not found" >&2; exit 1; }
[ -d "$PROJECTS" ] || { echo "error: transcript store not found at $PROJECTS" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prune-claude-sessions.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

TAB="$(printf '\t')"

# ------------------------------------------------------- locate the store

if [ -z "$DIR" ]; then
	[ -d "$APP" ] || { echo "error: session store not found at $APP" >&2; exit 1; }
	for ws in "$APP"/*/*/; do
		ws="${ws%/}"
		entries=("$ws"/local_*.json)
		[ ${#entries[@]} -gt 0 ] || continue
		DIR="$ws"
		break
	done
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "error: no populated session dir found" >&2; exit 1; }

# Two levels up from an <account>/<workspace> dir. Derived from DIR rather than
# assumed to be $APP so a run pointed at a test store never sweeps the real one.
STORE="$(cd "$DIR/../.." && pwd)"

# ------------------------------------------------- index the references
#
# cliSessionId \t lastActivityAt \t path \t title \t lastActivityAt as ISO-8601,
# for every reference in every dir under the store. A session present in several
# dirs yields several rows, and every one of them goes to the walk. refs.best is
# the newest row per session: it counts the sessions, names the transcripts to
# read, and gives the ordering fallback for a session whose transcript has no
# timestamp. A numeric .lastActivityAt above 1e11 is read as milliseconds.
#
# A reference with no .cliSessionId is keyed by its own path instead, so it is
# still decided by its .title and still listed if dropped. Keying it as "" would
# filter it out here and the relink would delete it without a word.
#
# A reference jq cannot parse fails the pipeline, and set -e stops the run
# before anything is unlinked.

refs=()
for ws in "$STORE"/*/*/; do
	ws="${ws%/}"
	for f in "$ws"/local_*.json; do refs[${#refs[@]}]="$f"; done
done
[ ${#refs[@]} -gt 0 ] || { echo "error: no local_*.json anywhere under $STORE" >&2; exit 1; }

printf '%s\0' "${refs[@]}" |
	xargs -0 jq -r '
		(.lastActivityAt // 0) as $l
		| (.cliSessionId // "") as $c
		| [ (if $c == "" then "ref:" + input_filename else $c end), $l, input_filename, (.title // ""),
		    (if ($l | type) == "number"
		     then (if $l > 100000000000 then $l / 1000 else $l end | floor | todate)
		     else ($l | tostring) end) ]
		| @tsv' >"$TMP/refs.all"

sort -t"$TAB" -k1,1 -k2,2nr "$TMP/refs.all" |
	awk -F'\t' '$1 != "" && $1 != prev { print; prev = $1 }' >"$TMP/refs.best"

n_refs=${#refs[@]}
n_sessions=$(wc -l <"$TMP/refs.best" | tr -d ' ')

# ------------------------------------------ the tail reader: timestamp + title
#
# stamp_titles <path-list-file> <out-file>
#
# Emits "<iso-timestamp> \t <path> \t <title>" per input path. A transcript with
# no timestamp at all gets an empty first column rather than no row, so its title
# still reaches a reference with no .title. ONE seek-and-read of the last TAIL_WINDOW
# bytes per file serves both fields, and ONE jq for the whole batch turns the raw
# custom-title lines into their .customTitle values — never a process per session,
# never a byte before the window.
#
# The timestamp keeps a whole-file fallback: a transcript whose final entry is a
# single line longer than the window has no timestamp inside it, and that is the
# one case the tail genuinely cannot answer. The title has no such fallback by
# design — it is only the fallback for a reference with no .title of its own.

stamp_titles() { # $1=path-list file  $2=output file
	perl -e '
		my $win = shift @ARGV;
		while (my $f = <STDIN>) {
			chomp $f;
			next if $f eq "";
			my $sz = -s $f;
			next unless defined $sz;
			open(my $fh, "<", $f) or next;
			my $off = $sz > $win ? $sz - $win : 0;
			seek($fh, $off, 0);
			my $d = do { local $/; <$fh> };
			$d = "" unless defined $d;
			my @lines = split(/\n/, $d, -1);
			# A window that does not start at 0 opens mid-line; that fragment is
			# not a record, and parsing it would yield truncated JSON.
			shift @lines if $off > 0 && @lines;
			my ($t, $raw) = ("", "");
			for my $ln (@lines) {
				while ($ln =~ /"timestamp":"([^"]+)"/g) { $t = $1 }
				$raw = $ln if index($ln, "\"type\":\"custom-title\"") >= 0;
			}
			if ($t eq "" && $off) {
				seek($fh, 0, 0);
				my $all = do { local $/; <$fh> };
				$all = "" unless defined $all;
				for my $ln (split(/\n/, $all, -1)) {
					while ($ln =~ /"timestamp":"([^"]+)"/g) { $t = $1 }
					$raw = $ln if index($ln, "\"type\":\"custom-title\"") >= 0;
				}
			}
			close($fh);
			# Keep the TSV sound. A tab inside a JSON string is escaped as \t, so
			# a literal one here is insignificant whitespace between tokens.
			$raw =~ s/\t/ /g;
			print "$t\t$f\t$raw\n";
		}' "$TAIL_WINDOW" <"$1" |
		jq -R -r '
			split("\t") as $a
			| (if ($a[2] // "") == "" then ""
			   else (try ((($a[2] | fromjson).customTitle) // "") catch "") end) as $title
			| [ $a[0], $a[1], $title ] | @tsv
		' >"$2"
}

# ---------------------------------------- each referenced session's last entry
#
# One glob of the transcript store maps cliSessionId -> path; only the
# transcripts of sessions that have a reference are then read.

transcripts=("$PROJECTS"/*/*.jsonl)
[ ${#transcripts[@]} -gt 0 ] || { echo "error: no transcripts under $PROJECTS" >&2; exit 1; }

printf '%s\n' "${transcripts[@]}" |
	awk -F'\t' -v OFS='\t' '{ n = split($0, seg, "/"); b = seg[n]; sub(/\.jsonl$/, "", b); print b, $0 }' |
	sort -u -t"$TAB" -k1,1 >"$TMP/cli2path"

awk -F'\t' 'FILENAME == ARGV[1] { path[$1] = $2; next } ($1 in path) { print path[$1] }' \
	"$TMP/cli2path" "$TMP/refs.best" >"$TMP/tx.list"

stamp_titles "$TMP/tx.list" "$TMP/tx.stamped"

# ------------------------------------------------------------ the session rows
#
# One row per reference COPY:
#
#   order-key \t cliSessionId \t rank \t lastActivityAt \t reference path \t title
#
# The key is the session's, shared by all its copies: the transcript's last
# entry, else the newest copy's .lastActivityAt. The title is the copy's own
# .title, else the transcript's last custom-title. Rank is 0 for a pinned title,
# 1 for a numbered one and 2 for anything else. Sessions run newest first, and
# each session's copies pinned first, then numbered, then the rest, the newest of
# each kind first. ISO-8601 sorts lexicographically exactly as it sorts
# chronologically.

awk -F'\t' -v OFS='\t' '
	FILENAME == ARGV[1] {
		n = split($2, seg, "/"); b = seg[n]; sub(/\.jsonl$/, "", b)
		if ($1 != "") ts[b] = $1
		tt[b] = $3
		next
	}
	FILENAME == ARGV[2] { key[$1] = ($1 in ts) ? ts[$1] : $5; next }
	{
		title = ($4 != "") ? $4 : (($1 in tt) ? tt[$1] : "")
		t = title; sub(/^[[:space:]]+/, "", t)
		rank = (t ~ /^\*/) ? 0 : ((t ~ /^[0-9]/) ? 1 : 2)
		print key[$1], $1, rank, $2 + 0, $3, title
	}
' "$TMP/tx.stamped" "$TMP/refs.best" "$TMP/refs.all" |
	sort -t"$TAB" -k1,1r -k2,2 -k3,3n -k4,4nr >"$TMP/sessions"

# ------------------------------------------------------------------ the walk
#
# A session's copies are tried in order until one keeps it, and the copy that
# keeps it is the one staged. A session no copy keeps is listed once, under its
# first copy's title and reason.
#
# stage rows:   reference path \t number-or-* \t title
# dropped rows: reason \t title

: >"$TMP/stage"
: >"$TMP/dropped"

seen=" "
cur=""
kept=0
why=""
why_title=""

settle() {
	if [ -n "$cur" ] && [ "$kept" -eq 0 ]; then
		printf '%s\t%s\n' "$why" "$why_title" >>"$TMP/dropped"
	fi
}

while IFS="$TAB" read -r key cli rank la path title; do
	[ -n "$path" ] || continue

	if [ "$cli" != "$cur" ]; then
		settle
		cur="$cli"
		kept=0
		why=""
		why_title=""
	fi
	[ "$kept" -eq 0 ] || continue

	# Strip leading whitespace without forking: chop the run of blanks that
	# precedes the first non-blank.
	trimmed="${title#"${title%%[![:space:]]*}"}"

	case "$trimmed" in
	\**)
		printf '%s\t%s\t%s\n' "$path" "*" "$title" >>"$TMP/stage"
		kept=1
		continue
		;;
	esac

	cand="${trimmed%%[!0-9]*}"
	if [ -z "$cand" ]; then
		if [ -z "$why" ]; then
			why="unnumbered"
			why_title="${title:-(untitled)}"
		fi
		continue
	fi
	num=$((10#$cand))

	case "$seen" in
	*" $num "*)
		if [ -z "$why" ]; then
			why="#$num is held by a newer session"
			why_title="$title"
		fi
		continue
		;;
	esac
	seen="$seen$num "
	printf '%s\t%s\t%s\n' "$path" "$num" "$title" >>"$TMP/stage"
	kept=1
done <"$TMP/sessions"
settle

n_keep=$(wc -l <"$TMP/stage" | tr -d ' ')
n_drop=$(wc -l <"$TMP/dropped" | tr -d ' ')

targets=()
for ws in "$STORE"/*/*/; do
	ws="${ws%/}"
	case "$ws" in "$STORE"/*/*) targets[${#targets[@]}]="$ws" ;; esac
done

echo "store:      $STORE"
echo "sessions:   $n_sessions distinct   ($n_refs reference file(s) across ${#targets[@]} dir(s))"
echo "keeping:    $n_keep   dropping: $n_drop"
echo

echo "keeping:"
while IFS="$TAB" read -r path num title; do
	printf '  #%-4s %s\n' "$num" "${title:0:66}"
done <"$TMP/stage"
echo

if [ "$n_drop" -gt 0 ]; then
	echo "dropping:"
	while IFS="$TAB" read -r why title; do
		printf '  %-66s  (%s)\n' "${title:0:66}" "$why"
	done <"$TMP/dropped"
	echo
fi

if [ "$n_keep" -eq 0 ]; then
	echo "error: nothing to keep — refusing to unlink anything" >&2
	exit 1
fi

if [ "$APPLY" -ne 1 ]; then
	echo "[dry run] would unlink $n_refs reference(s) from ${#targets[@]} dir(s),"
	echo "          then hardlink $n_keep keeper(s) into each."
	echo "          Dropped references are deleted outright, not backed up."
	echo "          Transcripts under $PROJECTS are not touched."
	echo "          Drop --dry-run to do it."
	exit 0
fi

# ----------------------------------------------------------------- stage
#
# ln, never cp. The staged link holds the winning inode alive while every
# directory entry pointing at it is removed, so the relink below re-points all
# dirs at the SAME inode the app has been writing to.

stash="$TMP/keepers"
mkdir -p "$stash"
nk=0
while IFS="$TAB" read -r path num title; do
	[ -e "$path" ] || continue
	b="${path##*/}"
	[ -e "$stash/$b" ] && continue
	if ln "$path" "$stash/$b" 2>/dev/null; then
		nk=$((nk + 1))
	elif cp -p "$path" "$stash/$b"; then
		echo "  warn: cross-device, had to copy $b" >&2
		nk=$((nk + 1))
	fi
done <"$TMP/stage"

if [ "$nk" -eq 0 ]; then
	echo "error: no keeper could be staged — refusing to unlink anything" >&2
	exit 1
fi

# ------------------------------------------------------------- relink
#
# Unlink in place, then link the stash in. No mv-aside and no background rm -rf:
# the old shape raced the app, which could write into a directory that had
# already been moved out from under it and was about to be deleted.

stashed=("$stash"/local_*.json)
rebuilt=0
for ws in "${targets[@]}"; do
	old=("$ws"/local_*.json)
	if [ ${#old[@]} -gt 0 ]; then
		rm -f "${old[@]}"
	fi
	if [ ${#stashed[@]} -gt 0 ]; then
		if ! ln "${stashed[@]}" "$ws/" 2>/dev/null; then
			for f in "${stashed[@]}"; do
				ln "$f" "$ws/${f##*/}" 2>/dev/null || cp -p "$f" "$ws/${f##*/}"
			done
		fi
	fi
	rebuilt=$((rebuilt + 1))
done

echo "Relinked $rebuilt dir(s) to $nk keeper(s) each, one inode per session."
echo "Restart the Claude app if the sidebar doesn't refresh."
