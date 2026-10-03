// Package scripts holds the Go entry point cg test uses to run the bash suite
// for prune-claude-sessions.sh, so a merge auditor can witness it first-hand.
package scripts

import (
	"os/exec"
	"regexp"
	"strconv"
	"testing"
)

// summary matches the suite's closing line, "<n> passed, <m> failed".
var summary = regexp.MustCompile(`(?m)^(\d+) passed, \d+ failed`)

// TestPruneSuite runs test-prune-claude-sessions.sh under stock /bin/bash and
// fails when the suite exits non-zero or reports no passed test.
func TestPruneSuite(t *testing.T) {
	t.Parallel()
	out, err := exec.Command("/bin/bash", "test-prune-claude-sessions.sh").CombinedOutput()
	t.Logf("%s", out)
	if err != nil {
		t.Fatalf("suite failed: %v", err)
	}
	m := summary.FindSubmatch(out)
	if m == nil {
		t.Fatal("suite printed no summary line")
	}
	if n, _ := strconv.Atoi(string(m[1])); n == 0 {
		t.Fatal("suite ran no test")
	}
}
