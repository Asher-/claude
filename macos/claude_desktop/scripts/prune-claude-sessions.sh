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
#   the ordering key. mtime survives only as a PREFILTER (see below).
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
#   Sessions newest-first BY LAST ENTRY, from the most recent down to the FLOOR —
#   the oldest session the previous run KEPT, recorded in the cache. Within that
#   window:
#
#     - a leading '*'  -> keep, and record as a pin
#     - a number seen for the FIRST time -> keep
#     - a number already seen -> an older batch's reuse of it, drop
#     - anything else -> drop
#
#   Numbering restarts per batch and the walk is newest-first, so first-seen wins
#   and the older batch's #3 loses to the current #3 without any extra machinery.
#
#   The floor is the oldest KEPT session, not the oldest one looked at. Anchoring
#   it to the walk instead would drag it to the bottom of the store on any run
#   that scanned deep, and every later run would then rescan everything.
#
#   PINS ESCAPE THE FLOOR. A pinned session older than the floor would never be
#   reached by the walk, so the cache carries the pin list forward and every
#   cached pin is re-read each run: still '*' -> kept, retitled -> dropped.
#
#   With no cache (first run, or a deleted one) there is no floor, so --limit
#   bounds the walk: it stops once that many distinct numbers have been kept.
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
LIMIT=20
APPLY=1
NOBACKUP=0
DIR=""

usage() {
	cat <<'EOF'
prune-claude-sessions.sh — keep the newest numbered batch plus every pin.

Usage:
  prune-claude-sessions.sh                  prune and relink
  prune-claude-sessions.sh --dry-run        show the plan, write nothing

Options:
  -n, --limit N    cap on how many distinct numbers may be kept (default 20).
                   Only bounds the walk when there is no cached floor.
      --dir PATH   explicit <account>/<workspace> dir. The store root is
                   PATH/../.., and the relink covers every dir under it.
      --no-backup  skip copying dropped references to
                   ~/claude-deleted-session-refs-<timestamp>/ first
      --dry-run    print the plan and write nothing
  -h, --help       show this text

A session's number is the LEADING RUN OF DIGITS of its title, whatever follows:
"7:", "7-1:" and "7*:" are all session 7. A leading '*' pins a session, which
keeps it regardless of number or how far back it sits.

Order comes from the last entry INSIDE each transcript, never from file mtime —
opening a session in the app bumps its mtime and would otherwise hand its number
back to an older batch. Transcripts under ~/.claude/projects/ are never written.
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
	--no-backup) NOBACKUP=1; shift ;;
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
#   floor <TAB> <epoch-seconds> <TAB> <iso8601-utc, trailing Z>
#   pin   <TAB> <cliSessionId>
#
# The Z is a format marker as well as a timezone: a floor written by the old
# mtime-based version has no Z, and is ignored rather than compared against a
# transcript timestamp it is not commensurable with.

FLOOR_EPOCH=0
FLOOR_ISO=""
: >"$TMP/pins.cached"
if [ -f "$CACHE" ]; then
	FLOOR_EPOCH=$(awk -F'\t' '$1 == "floor" { print $2; exit }' "$CACHE")
	FLOOR_ISO=$(awk -F'\t' '$1 == "floor" { print $3; exit }' "$CACHE")
	case "$FLOOR_EPOCH" in '' | *[!0-9]*) FLOOR_EPOCH=0 ;; esac
	case "$FLOOR_ISO" in *Z) ;; *) FLOOR_EPOCH=0; FLOOR_ISO="" ;; esac
	awk -F'\t' '$1 == "pin" && $2 != "" { print $2 }' "$CACHE" | sort -u >"$TMP/pins.cached"
fi
n_pins_cached=$(wc -l <"$TMP/pins.cached" | tr -d ' ')

# ---------------------------------------------- phase 1: candidates by mtime
#
# mtime is an UPPER BOUND on real activity: writing an entry sets it, and any
# later touch only raises it. So "mtime >= floor" over-includes and can never
# under-include — sound as a prefilter, and a prefilter is all it is.

transcripts=("$PROJECTS"/*/*.jsonl)
[ ${#transcripts[@]} -gt 0 ] || { echo "error: no transcripts under $PROJECTS" >&2; exit 1; }

printf '%s\0' "${transcripts[@]}" | xargs -0 stat -f "%m${TAB}%N" >"$TMP/tx.bymtime"

if [ "$FLOOR_EPOCH" -gt 0 ]; then
	awk -F'\t' -v f="$FLOOR_EPOCH" '$1 >= f { print $2 }' "$TMP/tx.bymtime" >"$TMP/candidates"
else
	cut -f2 "$TMP/tx.bymtime" >"$TMP/candidates"
fi
n_cand=$(wc -l <"$TMP/candidates" | tr -d ' ')

# ------------------------------------------- phase 2: the real last-entry time
#
# One process, seeking to the last 64K of each candidate rather than reading it
# whole — the entire store runs in about a third of a second. Falls back to a
# full read when the tail window holds no timestamp (one enormous final line).

perl -e '
	while (my $f = <STDIN>) {
		chomp $f;
		open(my $fh, "<", $f) or next;
		my $sz = -s $f;
		my $off = $sz > 65536 ? $sz - 65536 : 0;
		seek($fh, $off, 0);
		local $/;
		my $d = <$fh>;
		my $t = "";
		while ($d =~ /"timestamp":"([^"]+)"/g) { $t = $1 }
		if ($t eq "" && $off) {
			seek($fh, 0, 0);
			$d = <$fh>;
			while ($d =~ /"timestamp":"([^"]+)"/g) { $t = $1 }
		}
		close($fh);
		print "$t\t$f\n" if $t ne "";
	}' <"$TMP/candidates" >"$TMP/tx.stamped"

# ISO-8601 sorts lexicographically exactly as it sorts chronologically.
sort -r "$TMP/tx.stamped" >"$TMP/tx.sorted"
n_stamped=$(wc -l <"$TMP/tx.sorted" | tr -d ' ')
n_nostamp=$((n_cand - n_stamped))

# The current title of a session: the LAST custom-title line of its transcript.
# grep first so jq only ever parses one line — transcripts run to megabytes.
title_of() { # $1=transcript path
	local line
	line="$(grep '"type":"custom-title"' "$1" 2>/dev/null | tail -1)" || true
	[ -n "$line" ] || return 0
	printf '%s' "$line" | jq -r '.customTitle // ""' 2>/dev/null || true
}

ltrim() { # $1=string
	local s="$1"
	while :; do
		case "$s" in
		[[:space:]]*) s="${s#?}" ;;
		*) break ;;
		esac
	done
	printf '%s' "$s"
}

# keep rows: cliSessionId \t num-or-* \t title
: >"$TMP/keep"
: >"$TMP/pins.fresh"

seen=" "
nseen=0
walked=0
NEWFLOOR_ISO=""
reason="reached the end of the transcripts"

while IFS="$TAB" read -r ts path; do
	[ -n "$path" ] || continue

	# Stop below the previous run's floor. The floor row itself is re-walked, so a
	# retitle of the oldest kept session still takes effect.
	if [ -n "$FLOOR_ISO" ] && [[ "$ts" < "$FLOOR_ISO" ]]; then
		reason="reached the cached floor at $FLOOR_ISO"
		break
	fi
	if [ -z "$FLOOR_ISO" ] && [ "$nseen" -ge "$LIMIT" ]; then
		reason="no cached floor; stopped at the --limit of $LIMIT distinct number(s)"
		break
	fi

	walked=$((walked + 1))

	cli="${path##*/}"
	cli="${cli%.jsonl}"

	title="$(title_of "$path")"
	trimmed="$(ltrim "$title")"

	case "$trimmed" in
	\**)
		printf '%s\t%s\t%s\n' "$cli" "*" "$title" >>"$TMP/keep"
		printf '%s\n' "$cli" >>"$TMP/pins.fresh"
		NEWFLOOR_ISO="$ts"
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
	printf '%s\t%s\t%s\n' "$cli" "$num" "$title" >>"$TMP/keep"
	NEWFLOOR_ISO="$ts"
done <"$TMP/tx.sorted"

# ------------------------------------------------- pins below the floor

n_pin_kept=0
n_pin_released=0
if [ "$n_pins_cached" -gt 0 ]; then
	cut -f1 "$TMP/keep" | sort -u >"$TMP/keep.cli"
	while IFS= read -r cli; do
		[ -n "$cli" ] || continue
		grep -qxF "$cli" "$TMP/keep.cli" && continue

		tx=("$PROJECTS"/*/"$cli".jsonl)
		if [ ${#tx[@]} -eq 0 ]; then
			n_pin_released=$((n_pin_released + 1))
			continue
		fi

		title="$(title_of "${tx[0]}")"
		trimmed="$(ltrim "$title")"

		case "$trimmed" in
		\**)
			printf '%s\t%s\t%s\n' "$cli" "*" "$title" >>"$TMP/keep"
			printf '%s\n' "$cli" >>"$TMP/pins.fresh"
			n_pin_kept=$((n_pin_kept + 1))
			;;
		*) n_pin_released=$((n_pin_released + 1)) ;;
		esac
	done <"$TMP/pins.cached"
fi

# ------------------------------------------- resolve keepers to reference files
#
# A transcript outlives its reference, so the walk can select a session that has
# no sidebar row left to link. Look for it in this script's own backup dirs
# before giving up — an earlier run is the most likely reason it is missing.

: >"$TMP/stage"
: >"$TMP/orphans"
: >"$TMP/recovered"
while IFS="$TAB" read -r cli num title; do
	[ -n "$cli" ] || continue
	row="$(awk -F'\t' -v c="$cli" '$1 == c { print $3; exit }' "$TMP/refs.best")"
	if [ -n "$row" ]; then
		printf '%s\t%s\t%s\n' "$row" "$num" "$title" >>"$TMP/stage"
		continue
	fi
	found=""
	for b in "$HOME"/claude-deleted-session-refs-*/local_*.json; do
		[ -e "$b" ] || continue
		if [ "$(jq -r '.cliSessionId // ""' "$b" 2>/dev/null)" = "$cli" ]; then found="$b"; fi
	done
	if [ -n "$found" ]; then
		printf '%s\t%s\t%s\n' "$found" "$num" "$title" >>"$TMP/stage"
		printf '%s\t%s\n' "$num" "$found" >>"$TMP/recovered"
	else
		printf '%s\t%s\t%s\n' "$cli" "$num" "$title" >>"$TMP/orphans"
	fi
done <"$TMP/keep"

n_keep=$(wc -l <"$TMP/stage" | tr -d ' ')
n_orphan=$(wc -l <"$TMP/orphans" | tr -d ' ')
n_recovered=$(wc -l <"$TMP/recovered" | tr -d ' ')
n_drop=$((n_sessions - (n_keep - n_recovered)))

targets=()
for ws in "$STORE"/*/*/; do
	ws="${ws%/}"
	case "$ws" in "$STORE"/*/*) targets[${#targets[@]}]="$ws" ;; esac
done

echo "store:      $STORE"
echo "sessions:   $n_sessions distinct   ($n_refs reference file(s) across ${#targets[@]} dir(s))"
echo "candidates: $n_cand by mtime, $n_stamped stamped, walked $walked"
[ "$n_nostamp" -eq 0 ] || echo "            ($n_nostamp transcript(s) carried no timestamp and were skipped)"
echo "order:      last entry in the transcript   ($reason)"
if [ "$n_pins_cached" -gt 0 ]; then
	echo "pins:       $n_pin_kept carried from cache, $n_pin_released released"
fi
echo "keeping:    $n_keep   dropping: $n_drop"
echo

echo "keeping:"
while IFS="$TAB" read -r path num title; do
	printf '  #%-4s %s\n' "$num" "${title:0:66}"
done <"$TMP/stage"
echo

if [ "$n_recovered" -gt 0 ]; then
	echo "recovered $n_recovered reference(s) from an earlier run's backup:"
	while IFS="$TAB" read -r num p; do
		printf '  #%-4s %s\n' "$num" "$p"
	done <"$TMP/recovered"
	echo
fi

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
	if [ "$NOBACKUP" -eq 1 ]; then
		echo "          --no-backup is set: dropped references would not be copied."
	else
		echo "          Dropped references are copied to ~/claude-deleted-session-refs-<ts>/ first."
	fi
	echo "          Transcripts under $PROJECTS are not touched."
	echo "          Drop --dry-run to do it."
	exit 0
fi

# ---------------------------------------------------------------- backup

BACKUP=""
if [ "$NOBACKUP" -ne 1 ]; then
	BACKUP="$HOME/claude-deleted-session-refs-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$BACKUP"
	cut -f1 "$TMP/stage" | sort -u >"$TMP/stage.paths"
	copied=0
	while IFS="$TAB" read -r cli act path; do
		grep -qxF "$path" "$TMP/stage.paths" && continue
		b="${path##*/}"
		[ -e "$BACKUP/$b" ] && continue
		cp -p "$path" "$BACKUP/$b" && copied=$((copied + 1))
	done <"$TMP/refs.best"
	echo "Backed up $copied dropped reference(s) to $BACKUP"
fi

# ----------------------------------------------------------------- stage
#
# ln, never cp. The staged link holds the winning inode alive while every
# directory entry pointing at it is removed, so the relink below re-points all
# dirs at the SAME inode the app has been writing to. A reference recovered from
# a backup dir is copied instead — that inode is a frozen snapshot, not the live
# one, and hardlinking it would make the backup mutate with the sidebar.

stash="$TMP/keepers"
mkdir -p "$stash"
nk=0
while IFS="$TAB" read -r path num title; do
	[ -e "$path" ] || continue
	b="${path##*/}"
	[ -e "$stash/$b" ] && continue
	case "$path" in
	"$HOME"/claude-deleted-session-refs-*) cp -p "$path" "$stash/$b" && nk=$((nk + 1)) ;;
	*)
		if ln "$path" "$stash/$b" 2>/dev/null; then
			nk=$((nk + 1))
		elif cp -p "$path" "$stash/$b"; then
			echo "  warn: cross-device, had to copy $b" >&2
			nk=$((nk + 1))
		fi
		;;
	esac
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

rebuilt=0
for ws in "${targets[@]}"; do
	for f in "$ws"/local_*.json; do rm -f "$f"; done
	for f in "$stash"/local_*.json; do
		ln "$f" "$ws/${f##*/}" 2>/dev/null || cp -p "$f" "$ws/${f##*/}"
	done
	rebuilt=$((rebuilt + 1))
done

echo "Relinked $rebuilt dir(s) to $nk keeper(s) each, one inode per session."

# ------------------------------------------------------------- write the cache

NEWFLOOR_EPOCH=0
if [ -n "$NEWFLOOR_ISO" ]; then
	NEWFLOOR_EPOCH=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "${NEWFLOOR_ISO%.*}" '+%s' 2>/dev/null || echo 0)
fi

if [ "$NEWFLOOR_EPOCH" -gt 0 ]; then
	{
		printf 'floor\t%s\t%s\n' "$NEWFLOOR_EPOCH" "$NEWFLOOR_ISO"
		sort -u "$TMP/pins.fresh" | while IFS= read -r c; do
			[ -n "$c" ] && printf 'pin\t%s\n' "$c"
		done
	} >"$CACHE.tmp.$$" && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
	n_pins_now=$(sort -u "$TMP/pins.fresh" | grep -c . || true)
	echo "Cache: floor $NEWFLOOR_ISO, $n_pins_now pin(s)   ($CACHE)"
else
	echo "warn: could not derive a floor timestamp; cache left unchanged" >&2
fi

if [ -n "$BACKUP" ]; then
	echo "To restore a dropped sidebar entry:  cp \"$BACKUP\"/local_<id>.json \"$DIR\"/"
fi
echo "Restart the Claude app if the sidebar doesn't refresh."
