#!/bin/bash
#
# Tests for claude-account-sync.sh
#
# Creates a temp directory structure mimicking Claude Desktop's session storage,
# then exercises the sync script's merge, integrity check, and repair logic.
#
# Usage: ./claude-account-sync-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/claude-account-sync.sh"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ${GREEN}PASS${RESET}: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ${RED}FAIL${RESET}: $1"
    echo "        $2"
}

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg" "expected '$expected', got '$actual'"
    fi
}

assert_file_exists() {
    if [[ -e "$1" ]]; then
        pass "$2"
    else
        fail "$2" "file does not exist: $1"
    fi
}

assert_is_symlink() {
    if [[ -L "$1" ]]; then
        pass "$2"
    else
        fail "$2" "not a symlink: $1"
    fi
}

assert_is_dir() {
    if [[ -d "$1" ]] && [[ ! -L "$1" ]]; then
        pass "$2"
    else
        fail "$2" "not a real directory: $1"
    fi
}

assert_symlink_valid() {
    if [[ -L "$1" ]] && [[ -e "$1" ]]; then
        pass "$2"
    else
        fail "$2" "symlink broken or not a symlink: $1"
    fi
}

assert_symlink_broken() {
    if [[ -L "$1" ]] && [[ ! -e "$1" ]]; then
        pass "$2"
    else
        fail "$2" "expected broken symlink: $1"
    fi
}

# --- Test fixture setup ---

TMPDIR_ROOT=""

setup() {
    TMPDIR_ROOT=$(mktemp -d)
    export HOME="$TMPDIR_ROOT/home"
    mkdir -p "$HOME"
    mkdir -p "$HOME/Library/Application Support/Claude/claude-code-sessions"
    mkdir -p "$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$HOME/.claude"
}

teardown() {
    [[ -n "$TMPDIR_ROOT" ]] && rm -rf "$TMPDIR_ROOT"
}

# Create accounts.json with given account/org pairs
# Usage: create_accounts "acct1/org1" "acct2/org2"
create_accounts() {
    local json="["
    local first=true
    for pair in "$@"; do
        local acct="${pair%%/*}"
        local org="${pair##*/}"
        $first || json+=","
        first=false
        json+='{
            "accountUuid": "'"$acct"'",
            "organizationUuid": "'"$org"'",
            "emailAddress": "test-'"$acct"'@example.com",
            "displayName": "Test",
            "isEnabled": true,
            "billingType": "stripe_subscription",
            "rateLimitTier": "default",
            "subscriptionType": "max"
        }'
    done
    json+="]"
    echo "$json" > "$HOME/.claude/accounts.json"
}

# Create a session dir with N local_*.json files
# Usage: create_session_dir "acct/org" 5
create_session_dir() {
    local pair="$1"
    local count="${2:-0}"
    local dir="$HOME/Library/Application Support/Claude/claude-code-sessions/$pair"
    mkdir -p "$dir"
    for i in $(seq 1 "$count"); do
        local uuid
        uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
        cat > "$dir/local_${uuid}.json" << EOF
{
    "sessionId": "local_${uuid}",
    "cliSessionId": "${uuid}",
    "cwd": "/tmp/test",
    "createdAt": "2026-03-20T00:00:00.000Z",
    "lastActivityAt": "2026-03-20T00:00:00.000Z",
    "model": "claude-opus-4-6",
    "isArchived": false,
    "title": "Test session $i",
    "permissionMode": "default"
}
EOF
    done
}

count_local_json() {
    find -L "$1" -maxdepth 1 -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' '
}

SESSIONS_DIR=""
sessions_dir() {
    echo "$HOME/Library/Application Support/Claude/claude-code-sessions"
}

# ===========================================================================

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "--- $1 ---"
}

# ===========================================================================
# TEST 1: Basic merge — two accounts, one becomes primary
# ===========================================================================
run_test "Basic merge: two accounts, primary elected by session count"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"
create_session_dir "acct-aaa/org-aaa" 10
create_session_dir "acct-bbb/org-bbb" 3

output=$(/bin/bash "$SYNC_SCRIPT" 2>&1)

SD=$(sessions_dir)
assert_is_dir "$SD/acct-aaa/org-aaa" "primary is a real directory"
assert_is_symlink "$SD/acct-bbb/org-bbb" "secondary is a symlink"
assert_symlink_valid "$SD/acct-bbb/org-bbb" "secondary symlink is valid"
assert_eq "13" "$(count_local_json "$SD/acct-aaa/org-aaa")" "primary has all 13 sessions"

teardown

# ===========================================================================
# TEST 2: Integrity check — broken symlink with new dir available
# ===========================================================================
run_test "Integrity: broken symlink repaired when new org dir exists"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"

SD=$(sessions_dir)
# Set up the broken state: acct-bbb/org-bbb is a symlink to a non-existent target
mkdir -p "$SD/acct-aaa/org-aaa"
create_session_dir "acct-aaa/org-aaa" 5

mkdir -p "$SD/acct-bbb"
# Create a broken symlink pointing to non-existent primary
ln -s "$SD/acct-GONE/org-GONE" "$SD/acct-bbb/org-bbb"

# Claude Desktop created a new org dir for acct-bbb
create_session_dir "acct-bbb/org-NEW" 3

assert_symlink_broken "$SD/acct-bbb/org-bbb" "pre-condition: symlink is broken"

output=$(/bin/bash "$SYNC_SCRIPT" 2>&1)

# The broken symlink should be repaired, new org dir adopted
assert_is_symlink "$SD/acct-bbb/org-bbb" "repaired path is now a valid symlink"
assert_symlink_valid "$SD/acct-bbb/org-bbb" "repaired symlink target exists"
# The new org dir should be gone (adopted into primary)
assert_eq "false" "$([[ -d "$SD/acct-bbb/org-NEW" ]] && echo true || echo false)" "transient dir removed"
# Primary should have all sessions
assert_eq "8" "$(count_local_json "$SD/acct-aaa/org-aaa")" "primary has 5+3=8 sessions"

teardown

# ===========================================================================
# TEST 3: Integrity check — broken symlink, no new dir → error
# ===========================================================================
run_test "Integrity: broken symlink with no new dir causes error exit"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"

SD=$(sessions_dir)
create_session_dir "acct-aaa/org-aaa" 5

mkdir -p "$SD/acct-bbb"
# Broken symlink with NO new org dir under acct-bbb
ln -s "$SD/acct-GONE/org-GONE" "$SD/acct-bbb/org-bbb"

rc=0
output=$(/bin/bash "$SYNC_SCRIPT" 2>&1) || rc=$?

assert_eq "1" "$rc" "script exits with error code 1"
echo "$output" | grep -q "ERROR" && pass "error message printed" || fail "error message printed" "no ERROR in output"

teardown

# ===========================================================================
# TEST 4: discover_accounts ignores non-account directories
# ===========================================================================
run_test "discover_accounts only returns accounts from accounts.json"

setup

create_accounts "acct-aaa/org-aaa"

SD=$(sessions_dir)
create_session_dir "acct-aaa/org-aaa" 2

# Create a spurious directory that looks like an account but isn't in accounts.json
create_session_dir "FAKE-UUID/FAKE-ORG" 10

output=$(/bin/bash "$SYNC_SCRIPT" --status 2>&1)

echo "$output" | grep -q "FAKE-UUID" && fail "spurious dir ignored" "FAKE-UUID appeared in output" || pass "spurious dir ignored"

teardown

# ===========================================================================
# TEST 5: Idempotent — running twice doesn't break anything
# ===========================================================================
run_test "Idempotent: running merge twice produces same result"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"
create_session_dir "acct-aaa/org-aaa" 5
create_session_dir "acct-bbb/org-bbb" 2

/bin/bash "$SYNC_SCRIPT" >/dev/null 2>&1

SD=$(sessions_dir)
count_after_first=$(count_local_json "$SD/acct-aaa/org-aaa")

/bin/bash "$SYNC_SCRIPT" >/dev/null 2>&1

count_after_second=$(count_local_json "$SD/acct-aaa/org-aaa")

assert_eq "$count_after_first" "$count_after_second" "session count unchanged after second run"
assert_symlink_valid "$SD/acct-bbb/org-bbb" "symlink still valid after second run"

teardown

# ===========================================================================
# TEST 6: Unlink restores from backup
# ===========================================================================
run_test "Unlink restores separate directories from backup"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"
create_session_dir "acct-aaa/org-aaa" 5
create_session_dir "acct-bbb/org-bbb" 3

/bin/bash "$SYNC_SCRIPT" >/dev/null 2>&1
/bin/bash "$SYNC_SCRIPT" --unlink >/dev/null 2>&1

SD=$(sessions_dir)
assert_is_dir "$SD/acct-bbb/org-bbb" "secondary restored as real dir"
# The restored dir should have the original sessions (from backup)
# It won't have the merged sessions — those stayed in primary
local_count=$(count_local_json "$SD/acct-bbb/org-bbb")
assert_eq "3" "$local_count" "restored dir has original 3 sessions"

teardown

# ===========================================================================
# TEST 7: Lock prevents concurrent execution
# ===========================================================================
run_test "Lock file prevents concurrent execution"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"
create_session_dir "acct-aaa/org-aaa" 2
create_session_dir "acct-bbb/org-bbb" 1

# Create a lock file with our own PID (simulating a running instance)
echo $$ > "$HOME/Library/Application Support/Claude/.account-sync.lock"

output=$(/bin/bash "$SYNC_SCRIPT" 2>&1) || true
echo "$output" | grep -q "Another instance" && pass "concurrent run blocked" || fail "concurrent run blocked" "no lock message in output"

# Clean up lock
rm "$HOME/Library/Application Support/Claude/.account-sync.lock"

teardown

# ===========================================================================
# TEST 8: Stale lock file is cleaned up
# ===========================================================================
run_test "Stale lock file from dead process is cleaned up"

setup

create_accounts "acct-aaa/org-aaa" "acct-bbb/org-bbb"
create_session_dir "acct-aaa/org-aaa" 2
create_session_dir "acct-bbb/org-bbb" 1

# Create a lock file with a non-existent PID
echo 99999 > "$HOME/Library/Application Support/Claude/.account-sync.lock"

output=$(/bin/bash "$SYNC_SCRIPT" 2>&1) || true
# Should proceed normally, not block
echo "$output" | grep -q "Primary account" && pass "stale lock bypassed" || fail "stale lock bypassed" "merge didn't run"

teardown

# ===========================================================================
# TEST 9: Missing accounts.json
# ===========================================================================
run_test "Missing accounts.json produces warning and exits gracefully"

setup
# Don't create accounts.json

SD=$(sessions_dir)
create_session_dir "acct-aaa/org-aaa" 2

rc=0
output=$(/bin/bash "$SYNC_SCRIPT" 2>&1) || rc=$?

# Should exit cleanly (not enough accounts found)
assert_eq "1" "$rc" "exits with error when no accounts discoverable"

teardown

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "==========================================="
echo "  Results: $TESTS_PASSED passed, $TESTS_FAILED failed (of $TESTS_RUN tests)"
echo "==========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
