#!/bin/bash
#
# claude-account-sync.sh
#
# Merges Claude Desktop session indexes from multiple accounts into one,
# then symlinks so all accounts share the same session list.
#
# Account discovery uses two sources (either can be stale/missing):
#   1. ~/.claude/accounts.json — written by Claude Desktop, may lag after remove/re-add
#   2. Disk scan of session directories — finds all lowercase-UUID account/org pairs
#
# Structure before:
#   claude-code-sessions/{acct1}/{org1}/  (28 sessions)
#   claude-code-sessions/{acct2}/{org2}/  (4 sessions)
#
# Structure after:
#   claude-code-sessions/{acct1}/{org1}/  (32 sessions, real dir)
#   claude-code-sessions/{acct2}/{org2}   → symlink to {acct1}/{org1}/
#
# Usage:
#   ./claude-account-sync.sh             # Merge + symlink
#   ./claude-account-sync.sh --status    # Show current state
#   ./claude-account-sync.sh --unlink    # Undo symlinks, restore separate dirs

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
CLAUDE_APP_DIR="$HOME/Library/Application Support/Claude"
SESSIONS_DIR="$CLAUDE_APP_DIR/claude-code-sessions"
AGENT_DIR="$CLAUDE_APP_DIR/local-agent-mode-sessions"
BACKUP_DIR="$CLAUDE_APP_DIR/.account-sync-backups"
ACCOUNTS_JSON="$HOME/.claude/accounts.json"
PLIST_LABEL="com.claude.account-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOCK_FILE="$CLAUDE_APP_DIR/.account-sync.lock"

# --- Concurrency guard ---
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "Another instance is running (pid $lock_pid). Exiting."
            exit 0
        fi
        # Stale lock file — previous run crashed
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# --- Discover account/org pairs ---
# Two-source discovery: reads accounts.json AND scans session directories on disk.
# accounts.json may be stale (e.g. after account remove/re-add), so disk scanning
# ensures we never miss accounts that actually exist.
# Only returns lowercase-UUID pairs (skips uppercase Desktop agent-mode UUIDs).
discover_accounts() {
    if [[ ! -d "$SESSIONS_DIR" ]]; then
        return
    fi

    # Collect all pairs, then deduplicate at the end.
    # Two sources: accounts.json (may be stale) and disk scan.
    local all_discovered=""

    # Source 1: accounts.json (may be stale, but still useful)
    if [[ -f "$ACCOUNTS_JSON" ]]; then
        local pairs
        pairs=$(python3 -c "
import json, sys
with open('$ACCOUNTS_JSON') as f:
    for a in json.load(f):
        print(a['accountUuid'] + '/' + a['organizationUuid'])
" 2>/dev/null) || true

        while IFS= read -r pair; do
            [[ -z "$pair" ]] && continue
            local acct_uuid="${pair%%/*}"
            local org_uuid="${pair##*/}"
            local org_path="$SESSIONS_DIR/$acct_uuid/$org_uuid"
            if [[ -d "$org_path" || -L "$org_path" ]]; then
                all_discovered="${all_discovered}${pair}"$'\n'
            fi
        done <<< "$pairs"
    fi

    # Source 2: scan session directories on disk for any pairs not in accounts.json.
    # Only match lowercase UUID patterns (8-4-4-4-12) to skip Desktop agent UUIDs.
    local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    for acct_dir in "$SESSIONS_DIR"/*/; do
        [[ -d "$acct_dir" ]] || continue
        local acct_uuid
        acct_uuid=$(basename "$acct_dir")
        [[ "$acct_uuid" =~ $uuid_re ]] || continue

        for org_dir in "$acct_dir"*/; do
            [[ -d "$org_dir" || -L "$org_dir" ]] || continue
            local org_uuid
            org_uuid=$(basename "$org_dir")
            [[ "$org_uuid" =~ $uuid_re ]] || continue

            all_discovered="${all_discovered}${acct_uuid}/${org_uuid}"$'\n'
        done
    done

    # Deduplicate and output
    echo "$all_discovered" | sort -u | grep -v '^$'
}

count_sessions() {
    local dir="$SESSIONS_DIR/$1"
    # Follow symlinks
    if [[ -d "$dir" ]]; then
        find -L "$dir" -maxdepth 1 -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

is_symlink() {
    [[ -L "$SESSIONS_DIR/$1" ]]
}

# --- Status ---
cmd_status() {
    echo "Claude Desktop Account Sync"
    echo "==========================="
    echo ""

    local accounts=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && accounts+=("$line")
    done < <(discover_accounts)

    if [[ ${#accounts[@]} -eq 0 ]]; then
        echo "No accounts found in $SESSIONS_DIR"
        return 1
    fi

    for acct in "${accounts[@]}"; do
        local count
        count=$(count_sessions "$acct")
        local org_path="$SESSIONS_DIR/$acct"

        if [[ -L "$org_path" ]]; then
            local target
            target=$(readlink "$org_path")
            echo "  $acct  ($count sessions) -> SYMLINK to $target"
        else
            echo "  $acct  ($count sessions)"
        fi
    done
    echo ""

    # Check agent dir too
    if [[ -d "$AGENT_DIR" ]]; then
        echo "Agent mode sessions:"
        for acct_dir in "$AGENT_DIR"/*/; do
            [[ -d "$acct_dir" || -L "$acct_dir" ]] || continue
            local acct_uuid
            acct_uuid=$(basename "$acct_dir")
            for org_dir in "$acct_dir"*/; do
                [[ -d "$org_dir" || -L "$org_dir" ]] || continue
                local org_uuid
                org_uuid=$(basename "$org_dir")
                if [[ -L "$org_dir" ]]; then
                    echo "  $acct_uuid/$org_uuid -> SYMLINK to $(readlink "$org_dir")"
                else
                    echo "  $acct_uuid/$org_uuid (real dir)"
                fi
            done
        done
    fi
}

# --- Find new org dir that Claude Desktop created for an account ---
# When Claude Desktop reinitializes, it creates a new org UUID dir under the
# same account dir. This function finds it.
find_new_org_dir() {
    local acct_uuid="$1"
    local old_org_uuid="$2"
    local acct_dir="$SESSIONS_DIR/$acct_uuid"

    [[ -d "$acct_dir" ]] || return 1

    for org_dir in "$acct_dir"/*/; do
        [[ -d "$org_dir" ]] || continue
        local org_uuid
        org_uuid=$(basename "$org_dir")
        # Skip the old org UUID (which is a broken symlink, not a dir)
        [[ "$org_uuid" == "$old_org_uuid" ]] && continue
        # Found a new real directory — this is what Claude Desktop created
        echo "$org_uuid"
        return 0
    done
    return 1
}

# --- Check integrity of symlinks ---
# Detects broken symlinks (target dir was removed/recreated by Claude Desktop).
# When a symlink breaks, Claude Desktop has created a new directory with a new
# UUID for the same account. We find that new dir, adopt its sessions, and
# update accounts.json to reflect the new UUID.
# Returns 0 if all OK, 1 if broken links were found and repaired.
check_integrity() {
    local -a accounts
    accounts=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && accounts+=("$line")
    done < <(discover_accounts)

    if [[ ${#accounts[@]} -eq 0 ]]; then
        return 0
    fi

    local broken=0
    for acct in "${accounts[@]}"; do
        local org_path="$SESSIONS_DIR/$acct"
        # Broken symlink: is a symlink but target doesn't exist
        if [[ -L "$org_path" ]] && [[ ! -e "$org_path" ]]; then
            local target
            target=$(readlink "$org_path")
            local acct_uuid="${acct%%/*}"
            local old_org_uuid="${acct##*/}"

            echo "BROKEN SYMLINK: $acct -> $target (target missing)"
            echo "  Claude Desktop reinitialized this account with a new directory."

            # Look for the new org directory Claude Desktop created
            local new_org_uuid
            if new_org_uuid=$(find_new_org_dir "$acct_uuid" "$old_org_uuid"); then
                echo "  Found new org directory: $acct_uuid/$new_org_uuid"
                local new_org_path="$SESSIONS_DIR/$acct_uuid/$new_org_uuid"
                local new_count
                new_count=$(find "$new_org_path" -maxdepth 1 -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' ')
                echo "  New directory has $new_count session(s)."

                # Remove the broken symlink
                rm "$org_path"

                # Merge any sessions from the new dir into a restored/fresh dir at the old path,
                # then remove the new dir so we don't have duplicates
                if [[ -d "$BACKUP_DIR/$acct" ]]; then
                    # Restore backup to old org path
                    mv "$BACKUP_DIR/$acct" "$org_path"
                    echo "  Restored backup: $(count_sessions "$acct") sessions"
                else
                    mkdir -p "$org_path"
                fi

                # Copy sessions from new dir into restored dir
                local adopted=0
                for f in "$new_org_path"/local_*.json; do
                    [[ -f "$f" ]] || continue
                    local fname
                    fname=$(basename "$f")
                    if [[ ! -f "$org_path/$fname" ]]; then
                        cp "$f" "$org_path/$fname"
                        adopted=$((adopted + 1))
                    fi
                done
                echo "  Adopted $adopted session(s) from new directory."

                # Remove the new dir (its sessions are now in the canonical path)
                rm -rf "$new_org_path"
                echo "  Removed transient directory: $acct_uuid/$new_org_uuid"
            else
                echo "  ERROR: No new org directory found for account $acct_uuid." >&2
                echo "  Cannot repair this symlink — manual intervention required." >&2
                echo "  Run: $0 --status" >&2
                return 2
            fi

            broken=$((broken + 1))
        fi
    done

    if [[ $broken -gt 0 ]]; then
        echo ""
        echo "Repaired $broken broken symlink(s). Re-merging..."
        return 1
    fi
    return 0
}

# --- Reconcile accounts.json with disk state ---
# When accounts are removed/re-added, accounts.json may not be updated.
# This function ensures accounts.json reflects what's actually on disk.
update_accounts_json() {
    [[ -d "$SESSIONS_DIR" ]] || return

    # Get all lowercase-UUID pairs from disk
    local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    local disk_pairs=""
    for acct_dir in "$SESSIONS_DIR"/*/; do
        [[ -d "$acct_dir" ]] || continue
        local acct_uuid
        acct_uuid=$(basename "$acct_dir")
        [[ "$acct_uuid" =~ $uuid_re ]] || continue
        for org_dir in "$acct_dir"*/; do
            [[ -d "$org_dir" || -L "$org_dir" ]] || continue
            local org_uuid
            org_uuid=$(basename "$org_dir")
            [[ "$org_uuid" =~ $uuid_re ]] || continue
            disk_pairs="${disk_pairs}${acct_uuid}/${org_uuid}"$'\n'
        done
    done
    disk_pairs=$(echo "$disk_pairs" | sort -u | grep -v '^$')

    python3 -c "
import json, os, sys

accounts_path = '$ACCOUNTS_JSON'
disk_lines = '''$disk_pairs'''.strip().split('\n')
disk_pairs = set()
for line in disk_lines:
    line = line.strip()
    if '/' in line:
        disk_pairs.add(line)

if not disk_pairs:
    sys.exit(0)

# Load existing accounts.json or start fresh
accounts = []
if os.path.isfile(accounts_path):
    try:
        with open(accounts_path) as f:
            accounts = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass

# Index existing entries by accountUuid/organizationUuid
existing = {}
by_acct = {}
for a in accounts:
    key = a.get('accountUuid','') + '/' + a.get('organizationUuid','')
    existing[key] = a
    by_acct.setdefault(a.get('accountUuid',''), []).append(a)

changed = False
for pair in sorted(disk_pairs):
    if pair in existing:
        continue
    acct_uuid, org_uuid = pair.split('/')
    # Check if this account UUID already has an entry with a different org
    if acct_uuid in by_acct:
        # Account exists but org changed — update the org UUID
        entry = by_acct[acct_uuid][0]
        old_org = entry.get('organizationUuid','')
        if old_org != org_uuid:
            print(f'  Updating {entry.get(\"emailAddress\",acct_uuid)}: org {old_org} -> {org_uuid}')
            entry['organizationUuid'] = org_uuid
            changed = True
    else:
        # Completely new account UUID on disk — add minimal entry
        print(f'  Adding new account from disk: {pair}')
        accounts.append({
            'accountUuid': acct_uuid,
            'organizationUuid': org_uuid,
            'isEnabled': True,
        })
        changed = True

if changed:
    os.makedirs(os.path.dirname(accounts_path), exist_ok=True)
    with open(accounts_path, 'w') as f:
        json.dump(accounts, f, indent=2)
        f.write('\n')
    print('  accounts.json updated.')
" 2>&1
}

# --- Merge and link ---
cmd_link() {
    # Pre-flight: reconcile accounts.json with disk state
    update_accounts_json

    # Pre-flight: repair any broken symlinks before merging
    local integrity_rc=0
    check_integrity || integrity_rc=$?

    if [[ $integrity_rc -eq 2 ]]; then
        # Unrecoverable: no new directory found for a broken symlink
        exit 1
    fi

    if [[ $integrity_rc -eq 1 ]]; then
        # Repaired broken links. Verify repair succeeded before continuing.
        local still_broken=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local org_path="$SESSIONS_DIR/$line"
            if [[ -L "$org_path" ]] && [[ ! -e "$org_path" ]]; then
                still_broken=$((still_broken + 1))
            fi
        done < <(discover_accounts)

        if [[ $still_broken -gt 0 ]]; then
            echo "ERROR: $still_broken symlink(s) still broken after repair. Cannot proceed." >&2
            echo "Manual intervention required. Run: $0 --status" >&2
            exit 1
        fi
        echo ""
    fi

    local -a accounts
    accounts=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && accounts+=("$line")
    done < <(discover_accounts)

    local acct_count=${#accounts[@]}
    if [[ $acct_count -lt 2 ]]; then
        echo "Need at least 2 accounts. Found $acct_count."
        exit 1
    fi

    # Find the primary account (most sessions, and not already a symlink)
    local primary=""
    local primary_count=0
    for acct in "${accounts[@]}"; do
        local org_path="$SESSIONS_DIR/$acct"
        if [[ -L "$org_path" ]]; then
            echo "  $acct is already a symlink, skipping."
            continue
        fi
        local count
        count=$(count_sessions "$acct")
        if [[ "$count" -gt "$primary_count" ]]; then
            primary="$acct"
            primary_count="$count"
        fi
    done

    if [[ -z "$primary" ]]; then
        echo "All accounts are already symlinked. Nothing to do."
        echo "Use --unlink to undo first if you want to re-merge."
        exit 0
    fi

    local primary_dir="$SESSIONS_DIR/$primary"
    echo "Primary account: $primary ($primary_count sessions)"
    echo ""

    # Merge other discovered accounts into primary, then symlink
    for acct in "${accounts[@]}"; do
        [[ "$acct" == "$primary" ]] && continue

        local org_path="$SESSIONS_DIR/$acct"
        if [[ -L "$org_path" ]]; then
            echo "  $acct: already a symlink, skipping."
            continue
        fi

        local count
        count=$(count_sessions "$acct")
        echo "  $acct: merging $count sessions into primary..."

        # Copy unique sessions into primary
        local merged=0
        for f in "$org_path"/local_*.json; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            if [[ ! -f "$primary_dir/$fname" ]]; then
                cp "$f" "$primary_dir/$fname"
                merged=$((merged + 1))
            fi
        done
        echo "    Copied $merged new session(s)."

        # Backup the original directory
        local backup_path="$BACKUP_DIR/$acct"
        mkdir -p "$(dirname "$backup_path")"
        echo "    Backing up to $backup_path"
        mv "$org_path" "$backup_path"

        # Create symlink: {acct2}/{org2} -> absolute path to primary dir
        ln -s "$primary_dir" "$org_path"
        echo "    Linked $acct -> $primary_dir"
    done

    # Proactively create symlinks for accounts in accounts.json that don't have
    # directories yet. This handles the window between account add and first session.
    if [[ -f "$ACCOUNTS_JSON" ]]; then
        local all_pairs
        all_pairs=$(python3 -c "
import json, sys
with open('$ACCOUNTS_JSON') as f:
    for a in json.load(f):
        print(a['accountUuid'] + '/' + a['organizationUuid'])
" 2>/dev/null) || true

        while IFS= read -r pair; do
            [[ -z "$pair" ]] && continue
            [[ "$pair" == "$primary" ]] && continue
            local acct_uuid="${pair%%/*}"
            local org_uuid="${pair##*/}"
            local org_path="$SESSIONS_DIR/$acct_uuid/$org_uuid"
            # Skip if already exists (real dir or symlink)
            [[ -d "$org_path" || -L "$org_path" ]] && continue
            # Create account dir and symlink org to primary
            mkdir -p "$SESSIONS_DIR/$acct_uuid"
            ln -s "$primary_dir" "$org_path"
            echo "  $pair: pre-linked (no dir existed yet) -> $primary_dir"
        done <<< "$all_pairs"
    fi

    # Do the same for local-agent-mode-sessions
    if [[ -d "$AGENT_DIR" ]]; then
        echo ""
        echo "Linking agent mode sessions..."
        local primary_acct="${primary%%/*}"
        local primary_org="${primary##*/}"
        local primary_agent_org="$AGENT_DIR/$primary"

        # Scan local-agent-mode-sessions DIRECTLY instead of reusing the
        # claude-code-sessions account list — Desktop can create an agent-mode org
        # dir whose UUID never appears in claude-code-sessions (a transient org from
        # an account switch). The old loop only iterated discover_accounts pairs, so
        # such a dir was never linked and never re-checked, leaving it a real,
        # unlinked dir forever. Scanning here every run catches a dir that appeared
        # after a too-early run.
        local agent_uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        for agent_acct_dir in "$AGENT_DIR"/*/; do
            [[ -d "$agent_acct_dir" ]] || continue
            local a_acct; a_acct=$(basename "$agent_acct_dir")
            [[ "$a_acct" =~ $agent_uuid_re ]] || continue
            [[ "$a_acct" == "$primary_acct" ]] && continue

            for a_org_dir in "$agent_acct_dir"*/; do
                [[ -d "$a_org_dir" || -L "$a_org_dir" ]] || continue
                local a_org; a_org=$(basename "$a_org_dir")
                [[ "$a_org" =~ $agent_uuid_re ]] || continue

                local a_pair="$a_acct/$a_org"
                local agent_org="$AGENT_DIR/$a_pair"

                if [[ -L "$agent_org" ]]; then
                    echo "  $a_pair: already a symlink, skipping."
                    continue
                fi
                if [[ ! -d "$primary_agent_org" ]]; then
                    echo "  Primary agent dir doesn't exist, skipping $a_pair."
                    continue
                fi

                local agent_backup="$BACKUP_DIR/agent-mode/$a_pair"
                mkdir -p "$(dirname "$agent_backup")"
                mv "$agent_org" "$agent_backup"
                echo "  Backed up agent config to $agent_backup"
                ln -s "$primary_agent_org" "$agent_org"
                echo "  Linked $a_pair -> $primary_agent_org"
            done
        done

        # Proactively create agent-mode symlinks for accounts without directories
        if [[ -d "$primary_agent_org" ]] && [[ -f "$ACCOUNTS_JSON" ]]; then
            local agent_all_pairs
            agent_all_pairs=$(python3 -c "
import json, sys
with open('$ACCOUNTS_JSON') as f:
    for a in json.load(f):
        print(a['accountUuid'] + '/' + a['organizationUuid'])
" 2>/dev/null) || true

            while IFS= read -r pair; do
                [[ -z "$pair" ]] && continue
                [[ "$pair" == "$primary" ]] && continue
                local agent_org="$AGENT_DIR/$pair"
                [[ -d "$agent_org" || -L "$agent_org" ]] && continue
                mkdir -p "$AGENT_DIR/${pair%%/*}"
                ln -s "$primary_agent_org" "$agent_org"
                echo "  $pair: pre-linked (no dir existed yet) -> $primary_agent_org"
            done <<< "$agent_all_pairs"
        fi
    fi

    echo ""
    echo "Done. Total sessions in primary: $(count_sessions "$primary")"
    echo "Restart Claude Desktop to see changes."
}

# --- Unlink: restore separate dirs ---
cmd_unlink() {
    local accounts=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && accounts+=("$line")
    done < <(discover_accounts)

    local restored=0

    for acct in "${accounts[@]}"; do
        local org_path="$SESSIONS_DIR/$acct"

        if [[ -L "$org_path" ]]; then
            local backup_path="$BACKUP_DIR/$acct"
            rm "$org_path"

            if [[ -d "$backup_path" ]]; then
                mv "$backup_path" "$org_path"
                echo "Restored $acct from backup."
            else
                mkdir -p "$org_path"
                echo "Restored $acct as empty dir (no backup found)."
            fi
            restored=$((restored + 1))
        fi

        # Also restore agent mode
        local agent_org="$AGENT_DIR/$acct"
        if [[ -L "$agent_org" ]]; then
            local agent_backup="$BACKUP_DIR/agent-mode/$acct"
            rm "$agent_org"
            if [[ -d "$agent_backup" ]]; then
                mv "$agent_backup" "$agent_org"
                echo "Restored agent-mode $acct from backup."
            else
                mkdir -p "$agent_org"
                echo "Restored agent-mode $acct as empty dir."
            fi
        fi
    done

    if [[ $restored -eq 0 ]]; then
        echo "No symlinks found. Nothing to restore."
    else
        echo ""
        echo "Restored $restored account(s). Restart Claude Desktop to see changes."
    fi
}

# --- Install launchd agent ---
cmd_install() {
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        echo "Launchd agent already installed. Updating..."
        launchctl unload "$PLIST_PATH" 2>/dev/null
    fi

    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$PLIST_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$SCRIPT_PATH</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>$SESSIONS_DIR</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>/tmp/claude-account-sync.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/claude-account-sync.log</string>
	<key>ThrottleInterval</key>
	<integer>5</integer>
</dict>
</plist>
PLIST

    launchctl load "$PLIST_PATH"
    echo "Installed and loaded launchd agent."
    echo "Will auto-sync when accounts change in: $SESSIONS_DIR"
    echo "Logs: /tmp/claude-account-sync.log"
}

# --- Uninstall launchd agent ---
cmd_uninstall() {
    if [[ ! -f "$PLIST_PATH" ]]; then
        echo "Launchd agent not installed."
        return 1
    fi

    launchctl unload "$PLIST_PATH" 2>/dev/null
    rm "$PLIST_PATH"
    echo "Uninstalled launchd agent."
}

# --- Main ---
case "${1:-}" in
    --status|-s)
        cmd_status
        ;;
    --unlink|-u)
        cmd_unlink
        ;;
    --install|-i)
        cmd_install
        ;;
    --uninstall)
        cmd_uninstall
        ;;
    --help|-h)
        echo "Usage: $0 [--status|--unlink|--install|--uninstall|--help]"
        echo ""
        echo "Merges Claude Desktop session indexes and symlinks accounts together."
        echo ""
        echo "Commands:"
        echo "  (default)     Merge sessions into primary account, symlink others"
        echo "  --status      Show accounts, session counts, and link state"
        echo "  --unlink      Undo symlinks, restore separate dirs from backup"
        echo "  --install     Install launchd agent for auto-sync on directory changes"
        echo "  --uninstall   Remove launchd agent"
        echo "  --help        Show this help"
        ;;
    *)
        acquire_lock
        cmd_link
        ;;
esac
