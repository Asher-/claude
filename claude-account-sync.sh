#!/bin/bash
#
# claude-account-sync.sh
#
# Merges Claude Desktop session indexes from multiple accounts into one,
# then symlinks so all accounts share the same session list.
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
PLIST_LABEL="com.claude.account-sync"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# --- Discover account/org pairs ---
# Returns lines of "accountUuid/orgUuid"
# Follows through symlinks to find the real target for status display
discover_accounts() {
    if [[ ! -d "$SESSIONS_DIR" ]]; then
        return
    fi
    for acct_dir in "$SESSIONS_DIR"/*/; do
        [[ -d "$acct_dir" ]] || continue
        local acct_uuid
        acct_uuid=$(basename "$acct_dir")
        for org_dir in "$acct_dir"*/; do
            [[ -d "$org_dir" || -L "$org_dir" ]] || continue
            local org_uuid
            org_uuid=$(basename "$org_dir")
            echo "$acct_uuid/$org_uuid"
        done
    done
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

# --- Merge and link ---
cmd_link() {
    local accounts=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && accounts+=("$line")
    done < <(discover_accounts)

    if [[ ${#accounts[@]} -lt 2 ]]; then
        echo "Need at least 2 accounts. Found ${#accounts[@]}."
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

    # Merge other accounts into primary, then symlink
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

    # Do the same for local-agent-mode-sessions
    if [[ -d "$AGENT_DIR" ]]; then
        echo ""
        echo "Linking agent mode sessions..."
        local primary_acct="${primary%%/*}"
        local primary_org="${primary##*/}"
        local primary_agent_org="$AGENT_DIR/$primary"

        for acct in "${accounts[@]}"; do
            [[ "$acct" == "$primary" ]] && continue
            local agent_org="$AGENT_DIR/$acct"
            local agent_acct_dir="$AGENT_DIR/${acct%%/*}"

            if [[ -L "$agent_org" ]]; then
                echo "  $acct: already a symlink, skipping."
                continue
            fi

            if [[ -d "$agent_org" ]]; then
                # Backup and link
                local agent_backup="$BACKUP_DIR/agent-mode/$acct"
                mkdir -p "$(dirname "$agent_backup")"
                mv "$agent_org" "$agent_backup"
                echo "  Backed up agent config to $agent_backup"
            fi

            mkdir -p "$agent_acct_dir"
            if [[ -d "$primary_agent_org" ]]; then
                ln -s "$primary_agent_org" "$agent_org"
                echo "  Linked $acct -> $primary_agent_org"
            else
                echo "  Primary agent dir doesn't exist, skipping."
            fi
        done
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
        cmd_link
        ;;
esac
