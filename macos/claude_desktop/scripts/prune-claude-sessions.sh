#!/usr/bin/env bash
#
# prune-claude-sessions.sh — collapse the Claude Desktop sidebar to the most recent
# batch of NUMBERED sessions plus every PINNED one.
#
# THE TRANSCRIPT IS THE AUTHORITY
#   A session IS its transcript:
#     ~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl
#   The current title is the LAST "custom-title" line in it, and how recent the
#   session is comes from the LAST "timestamp" in it. Transcripts are READ ONLY —
#   this script never writes one, ever.
#
#   The sidebar entries are local_*.json under
#     claude-code-sessions/<account>/<workspace>/
#   They are ~630-byte REFERENCES to a transcript, joined by .cliSessionId. They
#   are derived artifacts: this script unlinks and re-links them freely, and
#   deleting one removes a sidebar row without touching the conversation.
#
#   Reading recency from the references was the first bug. A reference is a
#   per-account copy: the same session can exist in two workspace dirs as two
#   inodes whose .title and .lastActivityAt have drifted apart, so "most recent"
#   computed from them is whichever copy you happened to look at.
#
# WHY NOT FILE MTIME
#   mtime is when the file was last WRITTEN, which includes the app merely
#   opening a session to display it. Opening the app to check the sidebar after
#   a run therefore bumped old sessions above new ones, and the next run handed
#   their numbers back to the previous batch — verifying the output corrupted
#   the input. Measured: an old "1: Hermeneutic lens set" carried an mtime newer
#   than every session in the live batch while its last entry was six hours old.
#
#   The last entry's own timestamp cannot move except by a new entry. That is
#   the ordering key. mtime survives only as the PREFILTER (see THE WATERMARK).
#
# NEVER READ A WHOLE TRANSCRIPT
#   Both fields this script needs — the last timestamp and the last custom-title
#   — live at the END of the file, and ONE 256K tail read per transcript gets
#   both out of the same buffer. Transcripts run to 16MB; the store is 9.5GB.
#
#   Measured 2026-09-16 over a 400-transcript sample: 258 carry a custom-title
#   and the last one sits at most 32.0KB from EOF (p50 12.1KB, p99 31.6KB); 142
#   carry none anywhere, so no window size would find one. 256K is 8x the
#   observed worst case. If Claude ever starts writing a custom-title and then
#   appending more than 256K without rewriting it, re-measure and widen this.
#
#   An earlier version read every candidate WHOLE, with a grep+tail+jq fork per
#   session, to reach a title that was never more than 32KB from the end: 33ms
#   per session against 0.35ms for the tail read, 94x, and it dominated the run.
#
# NEVER READ ALL THE SESSIONS — THE WATERMARK
#   The cache's floor is a WATERMARK: the newest last-entry timestamp this run
#   saw. The next run prefilters to transcripts with mtime >= that, which is
#   exactly what has been written or touched since. Everything older is already
#   settled and is carried forward from the cache rather than re-derived.
#
#   The floor is NOT the oldest kept session. That was the second bug: pins are
#   deliberately old and pins are keepers, so the floor sank to the oldest pin
#   and every run re-walked from there to now — 3660 sessions and two minutes,
#   every time, to discover a handful of new ones. A floor that chases the
#   bottom of the keep set can never advance.
#
#   mtime is an UPPER BOUND on real activity: writing an entry sets it, and any
#   later touch only raises it. So "mtime >= watermark" over-includes and can
#   never under-include — sound as a prefilter, and a prefilter is all it is.
#   Over-inclusion is why a RETITLE still lands: retitling writes the file, so
#   the session reappears in the candidate set however old its last entry is.
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
#   Every candidate, newest-first BY LAST ENTRY. The prefilter already bounds the
#   set to what has changed, so the walk does not stop early — there is nothing
#   below it to stop before.
#
#     - a leading '*'  -> keep, and record as a pin
#     - a number seen for the FIRST time -> keep
#     - a number already seen -> an older batch's reuse of it, drop
#     - anything else -> drop
#
#   Numbering restarts per batch and the walk is newest-first, so first-seen wins
#   and the older batch's #3 loses to the current #3 without any extra machinery.
#
#   With no cache (first run, or a deleted one) every transcript is a candidate,
#   so --limit bounds the walk: it stops once that many distinct numbers are kept.
#
#   CARRY-FORWARD. The keep set is the merge of this run's keepers with the
#   cached ones. A cached keeper is dropped only when this run has something
#   better: its number was re-claimed by a newer session, or its own transcript
#   was re-read this run and no longer earns a slot (retitled, unstarred).
#
#   PINS ARE RE-CHECKED, NOT RE-WALKED. A pin whose transcript did not change is
#   not a candidate, so the cache carries the pin list forward and every cached
#   pin is re-read from its tail each run: still '*' -> kept, retitled -> dropped.
#   That check is the ONLY thing this script looks at below the watermark.
#
# THE RELINK
#   One inode per session, hardlinked into every workspace dir. That is the whole
#   point of the layout: the app writes a reference in place, and one write is
#   then visible in every account.
#
#   So keepers are staged with ln, NEVER cp. Staging with cp mints a fresh inode
#   and silently orphans the one the app is writing to — which is how the store
#   ended up holding two divergent copies of twelve sessions under one basename.
#   If a keeper exists in several dirs as several inodes, the copy with the
#   greatest .lastActivityAt wins and becomes the single inode for all of them.
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
CACHE="$HOME/.claude-prune-cache.tsv"
CACHE_VERSION=2
LIMIT=20
APPLY=1
DIR=""

# One tail read per transcript serves both the timestamp and the title. See
# NEVER READ A WHOLE TRANSCRIPT for the measurement behind the size.
TAIL_WINDOW=262144

usage() {
	cat <<'EOF'
prune-claude-sessions.sh — keep the newest numbered batch plus every pin.

Usage:
  prune-claude-sessions.sh                  prune and relink
  prune-claude-sessions.sh --dry-run        show the plan, write nothing

Options:
  -n, --limit N    cap on how many distinct numbers may be kept (default 20).
                   Only bounds the walk when there is no cached watermark.
      --dir PATH   explicit <account>/<workspace> dir. The store root is
                   PATH/../.., and the relink covers every dir under it.
      --dry-run    print the plan and write nothing
  -h, --help       show this text

A session's number is the LEADING RUN OF DIGITS of its title, whatever follows:
"7:", "7-1:" and "7*:" are all session 7. A leading '*' pins a session, which
keeps it regardless of number or how far back it sits.

Order comes from the last entry INSIDE each transcript, never from file mtime —
opening a session in the app bumps its mtime and would otherwise hand its number
back to an older batch. Transcripts under ~/.claude/projects/ are never written,
and only their last 256K is ever read.

Each run records a watermark: the newest last-entry it saw. The next run looks
only at transcripts written since, plus a re-read of every cached pin to catch a
star that was removed. Dropped sidebar references are deleted, not backed up —
they are pointers, and the conversation they point at is untouched.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-n | --limit)
		[ $# -ge 2 ] || { echo "error: $1 needs a number" >&2; exit 2; }
		LIMIT="$2"
		shift 2
		;;
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

case "$LIMIT" in
'' | *[!0-9]*) echo "error: --limit must be a non-negative integer, got '$LIMIT'" >&2; exit 2 ;;
esac

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
# cliSessionId \t lastActivityAt \t path, for every reference in every dir under
# the store. A session present in several dirs yields several rows; the highest
# lastActivityAt wins, and that inode becomes the one shared by all dirs.

refs=()
for ws in "$STORE"/*/*/; do
	ws="${ws%/}"
	for f in "$ws"/local_*.json; do refs[${#refs[@]}]="$f"; done
done
[ ${#refs[@]} -gt 0 ] || { echo "error: no local_*.json anywhere under $STORE" >&2; exit 1; }

printf '%s\0' "${refs[@]}" |
	xargs -0 jq -r '[ (.cliSessionId // ""), (.lastActivityAt // 0), input_filename ] | @tsv' \
		>"$TMP/refs.all"

sort -t"$TAB" -k1,1 -k2,2nr "$TMP/refs.all" |
	awk -F'\t' '$1 != "" && $1 != prev { print; prev = $1 }' >"$TMP/refs.best"

n_refs=${#refs[@]}
n_sessions=$(wc -l <"$TMP/refs.best" | tr -d ' ')

# ------------------------------------------------------------ read the cache
#
#   version <TAB> 2
#   floor   <TAB> <epoch-seconds> <TAB> <iso8601-utc, trailing Z>
#   pin     <TAB> <cliSessionId>
#   keep    <TAB> <number> <TAB> <cliSessionId> <TAB> <iso8601> <TAB> <title>
#
# The version row gates the whole file. A v1 cache recorded a floor meaning
# "oldest kept session" and carried no keep set, so its floor is not commensurable
# with this one and there is nothing to carry forward: it is ignored wholesale and
# this run rebuilds from a full scan.

FLOOR_EPOCH=0
FLOOR_ISO=""
: >"$TMP/pins.cached"
: >"$TMP/keep.cached"
if [ -f "$CACHE" ]; then
	cache_version=$(awk -F'\t' '$1 == "version" { print $2; exit }' "$CACHE")
	if [ "${cache_version:-0}" = "$CACHE_VERSION" ]; then
		FLOOR_EPOCH=$(awk -F'\t' '$1 == "floor" { print $2; exit }' "$CACHE")
		FLOOR_ISO=$(awk -F'\t' '$1 == "floor" { print $3; exit }' "$CACHE")
		case "$FLOOR_EPOCH" in '' | *[!0-9]*) FLOOR_EPOCH=0 ;; esac
		case "$FLOOR_ISO" in *Z) ;; *) FLOOR_EPOCH=0; FLOOR_ISO="" ;; esac
		awk -F'\t' '$1 == "pin" && $2 != "" { print $2 }' "$CACHE" | sort -u >"$TMP/pins.cached"
		awk -F'\t' -v OFS='\t' '$1 == "keep" && $3 != "" { print $2, $3, $4, $5 }' "$CACHE" \
			>"$TMP/keep.cached"
	fi
fi
n_pins_cached=$(wc -l <"$TMP/pins.cached" | tr -d ' ')

# ------------------------------------------ the tail reader: timestamp + title
#
# stamp_titles <path-list-file> <out-file>
#
# Emits "<iso-timestamp> \t <path> \t <title>" per input path, skipping any
# transcript with no timestamp at all. ONE seek-and-read of the last TAIL_WINDOW
# bytes per file serves both fields, and ONE jq for the whole batch turns the raw
# custom-title lines into their .customTitle values — never a process per session,
# never a byte before the window.
#
# The timestamp keeps a whole-file fallback: a transcript whose final entry is a
# single line longer than the window has no timestamp inside it, and that is the
# one case the tail genuinely cannot answer. The title has no such fallback by
# design — a session with no custom-title anywhere is the common case (142 of 400
# sampled), and falling back would read every one of those entirely to find
# nothing.

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
			next if $t eq "";
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

# ---------------------------------------- phase 1: candidates by the watermark

transcripts=("$PROJECTS"/*/*.jsonl)
[ ${#transcripts[@]} -gt 0 ] || { echo "error: no transcripts under $PROJECTS" >&2; exit 1; }

printf '%s\0' "${transcripts[@]}" | xargs -0 stat -f "%m${TAB}%N" >"$TMP/tx.bymtime"

if [ "$FLOOR_EPOCH" -gt 0 ]; then
	awk -F'\t' -v f="$FLOOR_EPOCH" '$1 >= f { print $2 }' "$TMP/tx.bymtime" >"$TMP/candidates"
else
	cut -f2 "$TMP/tx.bymtime" >"$TMP/candidates"
fi
n_cand=$(wc -l <"$TMP/candidates" | tr -d ' ')

# --------------------------------- phase 2: the real last-entry time and title

stamp_titles "$TMP/candidates" "$TMP/tx.stamped"

# ISO-8601 sorts lexicographically exactly as it sorts chronologically.
sort -r "$TMP/tx.stamped" >"$TMP/tx.sorted"
n_stamped=$(wc -l <"$TMP/tx.sorted" | tr -d ' ')
n_nostamp=$((n_cand - n_stamped))

# The new watermark is the newest last-entry seen, which is the first row. It
# never moves backwards: a run that saw nothing keeps the one it inherited.
WATERMARK_ISO="$FLOOR_ISO"
if [ "$n_stamped" -gt 0 ]; then
	top_iso=$(head -1 "$TMP/tx.sorted" | cut -f1)
	if [ -z "$WATERMARK_ISO" ] || [[ "$top_iso" > "$WATERMARK_ISO" ]]; then
		WATERMARK_ISO="$top_iso"
	fi
fi

# ------------------------------------------------------------------ the walk
#
# keep rows: number-or-* \t cliSessionId \t iso \t title

: >"$TMP/keep"
: >"$TMP/pins.fresh"
: >"$TMP/seen.cli"

seen=" "
nseen=0
walked=0
reason="walked every candidate"

while IFS="$TAB" read -r ts path title; do
	[ -n "$path" ] || continue

	if [ -z "$FLOOR_ISO" ] && [ "$nseen" -ge "$LIMIT" ]; then
		reason="no cached watermark; stopped at the --limit of $LIMIT distinct number(s)"
		break
	fi

	walked=$((walked + 1))

	cli="${path##*/}"
	cli="${cli%.jsonl}"
	printf '%s\n' "$cli" >>"$TMP/seen.cli"

	# Strip leading whitespace without forking: chop the run of blanks that
	# precedes the first non-blank.
	trimmed="${title#"${title%%[![:space:]]*}"}"

	case "$trimmed" in
	\**)
		printf '%s\t%s\t%s\t%s\n' "*" "$cli" "$ts" "$title" >>"$TMP/keep"
		printf '%s\n' "$cli" >>"$TMP/pins.fresh"
		continue
		;;
	esac

	cand="${trimmed%%[!0-9]*}"
	[ -n "$cand" ] || continue
	num=$((10#$cand))

	case "$seen" in
	*" $num "*) continue ;;
	esac
	seen="$seen$num "
	nseen=$((nseen + 1))
	printf '%s\t%s\t%s\t%s\n' "$num" "$cli" "$ts" "$title" >>"$TMP/keep"
done <"$TMP/tx.sorted"

sort -u "$TMP/seen.cli" >"$TMP/seen.cli.u"

# -------------------------------------------------- carry the cached keep set
#
# A cached numbered keeper survives unless this run has something better for it:
# its number was re-claimed by a newer session, or its own transcript was re-read
# this run — in which case the walk above has already ruled on it, and that ruling
# is the answer, not the stale cache row.

: >"$TMP/keep.carried"
if [ -s "$TMP/keep.cached" ]; then
	cut -f1 "$TMP/keep" | sort -u >"$TMP/keep.nums"
	awk -F'\t' '
		FILENAME == ARGV[1] { seencli[$0] = 1; next }
		FILENAME == ARGV[2] { claimed[$0] = 1; next }
		$1 == "*"       { next }
		($2 in seencli) { next }
		($1 in claimed) { next }
		{ print }
	' "$TMP/seen.cli.u" "$TMP/keep.nums" "$TMP/keep.cached" >"$TMP/keep.carried"
	cat "$TMP/keep.carried" >>"$TMP/keep"
fi
n_carried=$(wc -l <"$TMP/keep.carried" | tr -d ' ')

# -------------------------------------------------- re-check the cached pins
#
# The only thing this script reads below the watermark. A pin whose transcript was
# rewritten is already a candidate and the walk has ruled on it; the rest are
# re-read here, from their tails, purely to notice a star that was taken away.

n_pin_kept=0
n_pin_released=0
if [ "$n_pins_cached" -gt 0 ]; then
	# cliSessionId -> transcript path, built once from the paths already in hand,
	# so a pin never costs a glob across every project directory.
	awk -F'\t' -v OFS='\t' '{
		p = $2; n = split(p, seg, "/"); b = seg[n]; sub(/\.jsonl$/, "", b); print b, p
	}' "$TMP/tx.bymtime" | sort -u -t"$TAB" -k1,1 >"$TMP/cli2path"

	: >"$TMP/pins.recheck"
	: >"$TMP/pins.gone"
	awk -F'\t' -v RECHECK="$TMP/pins.recheck" -v GONE="$TMP/pins.gone" '
		FILENAME == ARGV[1] { seencli[$0] = 1; next }
		FILENAME == ARGV[2] { path[$1] = $2; next }
		($0 in seencli) { next }
		($0 in path)    { print path[$0] > RECHECK; next }
		{ print > GONE }
	' "$TMP/seen.cli.u" "$TMP/cli2path" "$TMP/pins.cached"

	n_pin_released=$(wc -l <"$TMP/pins.gone" | tr -d ' ')

	if [ -s "$TMP/pins.recheck" ]; then
		stamp_titles "$TMP/pins.recheck" "$TMP/pins.stamped"
		while IFS="$TAB" read -r ts path title; do
			[ -n "$path" ] || continue
			cli="${path##*/}"
			cli="${cli%.jsonl}"
			trimmed="${title#"${title%%[![:space:]]*}"}"
			case "$trimmed" in
			\**)
				printf '%s\t%s\t%s\t%s\n' "*" "$cli" "$ts" "$title" >>"$TMP/keep"
				printf '%s\n' "$cli" >>"$TMP/pins.fresh"
				n_pin_kept=$((n_pin_kept + 1))
				;;
			*) n_pin_released=$((n_pin_released + 1)) ;;
			esac
		done <"$TMP/pins.stamped"
	fi
fi

# Newest first, so the report reads the way the walk ran.
sort -t"$TAB" -k3,3r "$TMP/keep" >"$TMP/keep.sorted"
mv "$TMP/keep.sorted" "$TMP/keep"

# ------------------------------------------- resolve keepers to reference files
#
# A transcript outlives its reference, so the keep set can name a session with no
# sidebar row left to link. One pass over both files — refs.best is already one
# row per session, keyed by cliSessionId.

: >"$TMP/stage"
: >"$TMP/orphans"
# STAGE/ORPHANS go through -v, never as `VAR=value` operands: an operand
# assignment occupies an ARGV slot, which would shift every file one place and
# make `FILENAME == ARGV[1]` match nothing.
awk -F'\t' -v OFS='\t' -v STAGE="$TMP/stage" -v ORPHANS="$TMP/orphans" '
	FILENAME == ARGV[1] { if (!($1 in ref)) ref[$1] = $3; next }
	($2 in ref) { print ref[$2], $1, $4 > STAGE; next }
	{ print $2, $1, $4 > ORPHANS }
' "$TMP/refs.best" "$TMP/keep"

n_keep=$(wc -l <"$TMP/stage" | tr -d ' ')
n_orphan=$(wc -l <"$TMP/orphans" | tr -d ' ')
n_drop=$((n_sessions - n_keep))

targets=()
for ws in "$STORE"/*/*/; do
	ws="${ws%/}"
	case "$ws" in "$STORE"/*/*) targets[${#targets[@]}]="$ws" ;; esac
done

echo "store:      $STORE"
echo "sessions:   $n_sessions distinct   ($n_refs reference file(s) across ${#targets[@]} dir(s))"
if [ -n "$FLOOR_ISO" ]; then
	echo "watermark:  $FLOOR_ISO   (only transcripts written since are candidates)"
else
	echo "watermark:  none — full scan bounded by --limit $LIMIT"
fi
echo "candidates: $n_cand by mtime, $n_stamped stamped, walked $walked   ($reason)"
[ "$n_nostamp" -eq 0 ] || echo "            ($n_nostamp transcript(s) carried no timestamp and were skipped)"
[ "$n_carried" -eq 0 ] || echo "carried:    $n_carried numbered keeper(s) forward from the cache unchanged"
if [ "$n_pins_cached" -gt 0 ]; then
	echo "pins:       $n_pin_kept re-checked and still starred, $n_pin_released released"
fi
echo "keeping:    $n_keep   dropping: $n_drop"
echo

echo "keeping:"
while IFS="$TAB" read -r path num title; do
	printf '  #%-4s %s\n' "$num" "${title:0:66}"
done <"$TMP/stage"
echo

if [ "$n_orphan" -gt 0 ]; then
	echo "no sidebar reference exists for $n_orphan kept session(s):"
	while IFS="$TAB" read -r cli num title; do
		printf '  #%-4s %s  (%s)\n' "$num" "${title:0:50}" "$cli"
	done <"$TMP/orphans"
	echo "  (the transcript is intact; only the sidebar row is missing)"
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

# ------------------------------------------------------------- write the cache

WATERMARK_EPOCH=0
if [ -n "$WATERMARK_ISO" ]; then
	WATERMARK_EPOCH=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "${WATERMARK_ISO%.*}" '+%s' 2>/dev/null || echo 0)
fi

if [ "$WATERMARK_EPOCH" -gt 0 ]; then
	{
		printf 'version\t%s\n' "$CACHE_VERSION"
		printf 'floor\t%s\t%s\n' "$WATERMARK_EPOCH" "$WATERMARK_ISO"
		sort -u "$TMP/pins.fresh" | while IFS= read -r c; do
			[ -n "$c" ] && printf 'pin\t%s\n' "$c"
		done
		awk -F'\t' -v OFS='\t' '$1 != "*" { print "keep", $1, $2, $3, $4 }' "$TMP/keep"
	} >"$CACHE.tmp.$$" && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
	n_pins_now=$(sort -u "$TMP/pins.fresh" | grep -c . || true)
	n_keep_rows=$(awk -F'\t' '$1 != "*"' "$TMP/keep" | grep -c . || true)
	echo "Cache: watermark $WATERMARK_ISO, $n_pins_now pin(s), $n_keep_rows numbered keeper(s)   ($CACHE)"
else
	echo "warn: could not derive a watermark timestamp; cache left unchanged" >&2
fi

echo "Restart the Claude app if the sidebar doesn't refresh."
