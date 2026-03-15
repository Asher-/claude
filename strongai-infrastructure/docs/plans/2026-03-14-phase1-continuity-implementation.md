# Phase 1: Continuity Implementation Plan

**Goal:** Add the remediation pipeline to the Stability Lab — monitors detect problems, the route engine resolves them through formally defined step/condition sequences, and the informal agent handles what formal routes cannot.

**Architecture:** Monitors (existing) publish Observations with severity levels. A new TriggerEvaluator watches for non-OK observations and instantiates ReactionInterpretations. The RouteEngine matches triggers to resolution routes stored in PostgreSQL, walks step/condition sequences, and executes remediation actions via a CommandExecutor. When formal routes cannot resolve, the informal agent (Claude) activates. A FaultInjector provides the test harness.

**Tech Stack:** Go 1.26, PostgreSQL 16, suture/v4 (supervision), stateless (state machine), Connect-RPC (agent↔platform), os/exec (command execution on Linux)

---

## Dependency Graph

```
T1 (schema) ──┬── T3 (route store)
              │
T2 (types)  ──┼── T4 (trigger evaluator) ── T6 (route engine) ── T8 (integration)
              │                                     │
              └── T5 (command executor) ────────────┘
                                                    │
T7 (new monitors) ─────────────────────────────────┘
                                                    │
T9 (fault injector) ────────────────────────────────┘
                                                    │
T10 (deploy + validate) ───────────────────────────┘
```

**Parallel groups:**
- Group 1: T1, T2 (no dependencies)
- Group 2: T3, T4, T5 (depend on T1/T2)
- Group 3: T6, T7 (depend on T2–T5)
- Group 4: T8 (depends on T3–T7)
- Group 5: T9 (depends on T8)
- Group 6: T10 (depends on T9)

---

### Task 1: Database Migration — Resolution Routes and Reaction Interpretations

**Files:**
- Create: `migrations/002_resolution_routes.up.sql`
- Create: `migrations/002_resolution_routes.down.sql`

**Step 1: Write the up migration**

```sql
-- Resolution routes
CREATE TABLE resolution_routes (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    workload_type TEXT,
    trigger_match JSONB NOT NULL,
    priority      INTEGER NOT NULL DEFAULT 0,
    enabled       BOOLEAN NOT NULL DEFAULT true,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_routes_workload ON resolution_routes(workload_type);
CREATE INDEX idx_routes_enabled ON resolution_routes(enabled) WHERE enabled = true;

-- Route nodes (steps and conditions in sequence)
CREATE TABLE route_nodes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    route_id        UUID NOT NULL REFERENCES resolution_routes(id) ON DELETE CASCADE,
    position        INTEGER NOT NULL,
    node_type       TEXT NOT NULL CHECK (node_type IN ('step', 'condition')),
    definition      JSONB NOT NULL,
    evaluation_mode TEXT NOT NULL DEFAULT 'formal' CHECK (evaluation_mode IN ('formal', 'semantic')),
    privilege_level TEXT CHECK (privilege_level IN ('autonomous', 'gated', 'obligatory')),
    branch_on_true  UUID REFERENCES route_nodes(id),
    branch_on_false UUID REFERENCES route_nodes(id),
    UNIQUE (route_id, position)
);

CREATE INDEX idx_nodes_route ON route_nodes(route_id, position);

-- Reaction interpretations
CREATE TABLE reaction_interpretations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id           TEXT NOT NULL REFERENCES servers(id),
    trigger_source      TEXT NOT NULL CHECK (trigger_source IN ('formal_monitor', 'informal_agent', 'external_process')),
    trigger_data        JSONB NOT NULL,
    semantic_evaluation TEXT,
    system_state        JSONB,
    matched_route_id    UUID REFERENCES resolution_routes(id),
    resolution_method   TEXT CHECK (resolution_method IN ('formal_route', 'informal_agent', 'escalated')),
    permission_state    TEXT NOT NULL DEFAULT 'executing'
        CHECK (permission_state IN ('executing', 'pending_approval', 'approved', 'denied')),
    state               TEXT NOT NULL DEFAULT 'detected'
        CHECK (state IN ('detected', 'diagnosing', 'remediating', 'verifying', 'resolved', 'escalated')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at         TIMESTAMPTZ
);

CREATE INDEX idx_reactions_server ON reaction_interpretations(server_id, created_at DESC);
CREATE INDEX idx_reactions_state ON reaction_interpretations(state) WHERE state NOT IN ('resolved', 'escalated');

-- Reaction history (log of each step executed)
CREATE TABLE reaction_history (
    id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reaction_interpretation_id UUID NOT NULL REFERENCES reaction_interpretations(id) ON DELETE CASCADE,
    node_id                    UUID REFERENCES route_nodes(id),
    action_taken               TEXT NOT NULL,
    result                     JSONB,
    timestamp                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_reaction_history_ri ON reaction_history(reaction_interpretation_id, timestamp);
```

**Step 2: Write the down migration**

```sql
DROP TABLE IF EXISTS reaction_history CASCADE;
DROP TABLE IF EXISTS reaction_interpretations CASCADE;
DROP TABLE IF EXISTS route_nodes CASCADE;
DROP TABLE IF EXISTS resolution_routes CASCADE;
```

**Step 3: Apply migration on ctrl-lab**

Run: `ssh -i ~/.ssh/stability-lab root@178.104.59.223 "sudo -u postgres psql -d strongai -f -" < migrations/002_resolution_routes.up.sql`
Expected: Tables created successfully, no errors.

**Step 4: Commit**

```bash
git add migrations/002_resolution_routes.up.sql migrations/002_resolution_routes.down.sql
git commit -m "feat: add resolution routes and reaction interpretations schema"
```

---

### Task 2: Go Types — Route, Node, ReactionInterpretation, CommandResult

**Files:**
- Create: `internal/agent/remediation/types.go`
- Create: `internal/agent/remediation/types_test.go`

**Step 1: Write the failing test**

```go
package remediation

import (
    "testing"
    "time"
)

func TestTriggerMatchesObservation(t *testing.T) {
    match := TriggerMatch{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
    }

    obs := TriggerContext{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
        Value:       0.0,
        Labels:      map[string]string{"process": "nginx"},
    }

    if !match.Matches(obs) {
        t.Error("expected match")
    }

    obs.Severity = "ok"
    if match.Matches(obs) {
        t.Error("expected no match on severity mismatch")
    }
}

func TestReactionInterpretationLifecycle(t *testing.T) {
    ri := NewReactionInterpretation("wp-lab", TriggerSourceFormalMonitor, TriggerContext{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
        Labels:      map[string]string{"process": "nginx"},
    })

    if ri.State != StateDetected {
        t.Errorf("expected detected, got %s", ri.State)
    }
    if ri.ID == "" {
        t.Error("expected non-empty ID")
    }
    if ri.CreatedAt.IsZero() {
        t.Error("expected non-zero created_at")
    }
}

func TestNodeDefinitionStepParsing(t *testing.T) {
    node := RouteNode{
        ID:             "node-1",
        RouteID:        "route-1",
        Position:       1,
        NodeType:       NodeTypeStep,
        EvaluationMode: EvalModeFormal,
        PrivilegeLevel: PrivilegeAutonomous,
        Definition: NodeDefinition{
            Action:          "systemctl restart nginx",
            ExpectedOutcome: "process nginx is running",
            Timeout:         10 * time.Second,
        },
    }

    if node.IsCondition() {
        t.Error("expected step, not condition")
    }
    if !node.IsStep() {
        t.Error("expected step")
    }
    if node.PrivilegeLevel != PrivilegeAutonomous {
        t.Errorf("expected autonomous, got %s", node.PrivilegeLevel)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/asher/Dropbox/Projects/claude/strongai/infrastructure && go test ./internal/agent/remediation/ -v -run TestTrigger`
Expected: FAIL — package does not exist.

**Step 3: Write types implementation**

```go
package remediation

import (
    "time"

    "github.com/strongai/infrastructure/internal/agent/monitor"
)

// Trigger sources
type TriggerSource string

const (
    TriggerSourceFormalMonitor  TriggerSource = "formal_monitor"
    TriggerSourceInformalAgent  TriggerSource = "informal_agent"
    TriggerSourceExternalProcess TriggerSource = "external_process"
)

// Resolution methods
type ResolutionMethod string

const (
    ResolutionFormalRoute   ResolutionMethod = "formal_route"
    ResolutionInformalAgent ResolutionMethod = "informal_agent"
    ResolutionEscalated     ResolutionMethod = "escalated"
)

// Permission states
type PermissionState string

const (
    PermissionExecuting       PermissionState = "executing"
    PermissionPendingApproval PermissionState = "pending_approval"
    PermissionApproved        PermissionState = "approved"
    PermissionDenied          PermissionState = "denied"
)

// Reaction states (matches existing event lifecycle)
type ReactionState string

const (
    StateDetected    ReactionState = "detected"
    StateDiagnosing  ReactionState = "diagnosing"
    StateRemediating ReactionState = "remediating"
    StateVerifying   ReactionState = "verifying"
    StateResolved    ReactionState = "resolved"
    StateEscalated   ReactionState = "escalated"
)

// Node types
type NodeType string

const (
    NodeTypeStep      NodeType = "step"
    NodeTypeCondition NodeType = "condition"
)

// Evaluation modes
type EvalMode string

const (
    EvalModeFormal   EvalMode = "formal"
    EvalModeSemantic EvalMode = "semantic"
)

// Privilege levels
type PrivilegeLevel string

const (
    PrivilegeAutonomous PrivilegeLevel = "autonomous"
    PrivilegeGated      PrivilegeLevel = "gated"
    PrivilegeObligatory PrivilegeLevel = "obligatory"
)

// TriggerMatch defines when a resolution route should be selected.
type TriggerMatch struct {
    MonitorName  string            `json:"monitor_name,omitempty"`
    MetricName   string            `json:"metric_name,omitempty"`
    Severity     string            `json:"severity,omitempty"`
    Labels       map[string]string `json:"labels,omitempty"`
}

// Matches returns true if this trigger match applies to the given context.
func (tm TriggerMatch) Matches(tc TriggerContext) bool {
    if tm.MonitorName != "" && tm.MonitorName != tc.MonitorName {
        return false
    }
    if tm.MetricName != "" && tm.MetricName != tc.MetricName {
        return false
    }
    if tm.Severity != "" && tm.Severity != tc.Severity {
        return false
    }
    for k, v := range tm.Labels {
        if tc.Labels[k] != v {
            return false
        }
    }
    return true
}

// TriggerContext holds the data from the triggering observation.
type TriggerContext struct {
    MonitorName string            `json:"monitor_name"`
    MetricName  string            `json:"metric_name"`
    Value       float64           `json:"value"`
    Severity    string            `json:"severity"`
    Message     string            `json:"message"`
    Labels      map[string]string `json:"labels"`
    Timestamp   time.Time         `json:"timestamp"`
}

// TriggerContextFromObservation converts a monitor.Observation to TriggerContext.
func TriggerContextFromObservation(obs monitor.Observation) TriggerContext {
    return TriggerContext{
        MonitorName: obs.MonitorName,
        MetricName:  obs.MetricName,
        Value:       obs.Value,
        Severity:    obs.Severity.String(),
        Message:     obs.Message,
        Labels:      obs.Labels,
        Timestamp:   obs.Timestamp,
    }
}

// ResolutionRoute is a named route with trigger matching and priority.
type ResolutionRoute struct {
    ID            string       `json:"id"`
    Name          string       `json:"name"`
    WorkloadType  string       `json:"workload_type,omitempty"`
    TriggerMatch  TriggerMatch `json:"trigger_match"`
    Priority      int          `json:"priority"`
    Enabled       bool         `json:"enabled"`
    Nodes         []RouteNode  `json:"nodes"`
    CreatedAt     time.Time    `json:"created_at"`
}

// NodeDefinition holds the details of a step or condition.
type NodeDefinition struct {
    // For steps
    Action          string        `json:"action,omitempty"`
    Precondition    string        `json:"precondition,omitempty"`
    ExpectedOutcome string        `json:"expected_outcome,omitempty"`
    Timeout         time.Duration `json:"timeout,omitempty"`

    // For conditions
    Evaluation      string `json:"evaluation,omitempty"`
    TrueLabel       string `json:"true_label,omitempty"`
    FalseLabel      string `json:"false_label,omitempty"`
}

// RouteNode is a single step or condition in a resolution route.
type RouteNode struct {
    ID             string         `json:"id"`
    RouteID        string         `json:"route_id"`
    Position       int            `json:"position"`
    NodeType       NodeType       `json:"node_type"`
    Definition     NodeDefinition `json:"definition"`
    EvaluationMode EvalMode       `json:"evaluation_mode"`
    PrivilegeLevel PrivilegeLevel `json:"privilege_level,omitempty"`
    BranchOnTrue   string         `json:"branch_on_true,omitempty"`
    BranchOnFalse  string         `json:"branch_on_false,omitempty"`
}

// IsStep returns true if this node is a step.
func (n RouteNode) IsStep() bool { return n.NodeType == NodeTypeStep }

// IsCondition returns true if this node is a condition.
func (n RouteNode) IsCondition() bool { return n.NodeType == NodeTypeCondition }

// ReactionInterpretation is the central structure instantiated on trigger.
type ReactionInterpretation struct {
    ID                string           `json:"id"`
    ServerID          string           `json:"server_id"`
    TriggerSource     TriggerSource    `json:"trigger_source"`
    TriggerData       TriggerContext   `json:"trigger_data"`
    SemanticEvaluation string          `json:"semantic_evaluation,omitempty"`
    SystemState       map[string]any   `json:"system_state,omitempty"`
    MatchedRouteID    string           `json:"matched_route_id,omitempty"`
    ResolutionMethod  ResolutionMethod `json:"resolution_method,omitempty"`
    PermissionState   PermissionState  `json:"permission_state"`
    State             ReactionState    `json:"state"`
    History           []HistoryEntry   `json:"history,omitempty"`
    CreatedAt         time.Time        `json:"created_at"`
    ResolvedAt        time.Time        `json:"resolved_at,omitempty"`
}

// NewReactionInterpretation creates a new RI in the detected state.
func NewReactionInterpretation(serverID string, source TriggerSource, trigger TriggerContext) *ReactionInterpretation {
    return &ReactionInterpretation{
        ID:              generateID(),
        ServerID:        serverID,
        TriggerSource:   source,
        TriggerData:     trigger,
        PermissionState: PermissionExecuting,
        State:           StateDetected,
        CreatedAt:       time.Now(),
    }
}

// HistoryEntry records one step executed within a reaction interpretation.
type HistoryEntry struct {
    ID                       string    `json:"id"`
    ReactionInterpretationID string    `json:"reaction_interpretation_id"`
    NodeID                   string    `json:"node_id,omitempty"`
    ActionTaken              string    `json:"action_taken"`
    Result                   any       `json:"result,omitempty"`
    Timestamp                time.Time `json:"timestamp"`
}

// CommandResult is the outcome of executing a shell command.
type CommandResult struct {
    Command  string        `json:"command"`
    Stdout   string        `json:"stdout"`
    Stderr   string        `json:"stderr"`
    ExitCode int           `json:"exit_code"`
    Duration time.Duration `json:"duration"`
    Error    string        `json:"error,omitempty"`
}

func generateID() string {
    // UUID v4 generation — use crypto/rand
    b := make([]byte, 16)
    // crypto/rand.Read is used; if it fails, fall back to timestamp
    _, err := cryptoRandRead(b)
    if err != nil {
        return time.Now().Format("20060102150405.000000000")
    }
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
        b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// cryptoRandRead wraps crypto/rand.Read for testability.
var cryptoRandRead = func(b []byte) (int, error) {
    return rand.Read(b)
}
```

Note: Add `"crypto/rand"` and `"fmt"` to the import block.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/asher/Dropbox/Projects/claude/strongai/infrastructure && go test ./internal/agent/remediation/ -v`
Expected: PASS (3 tests).

**Step 5: Commit**

```bash
git add internal/agent/remediation/types.go internal/agent/remediation/types_test.go
git commit -m "feat: add remediation types — routes, nodes, reaction interpretations"
```

---

### Task 3: Route Store — Load and Match Routes from PostgreSQL

**Files:**
- Create: `internal/agent/remediation/store.go`
- Create: `internal/agent/remediation/store_test.go`

**Step 1: Write the failing test**

Test against an in-memory route store (interface-based so the real PostgreSQL store and a mock share the same contract).

```go
package remediation

import (
    "context"
    "testing"
)

func TestMemoryStoreMatchRoutes(t *testing.T) {
    store := NewMemoryRouteStore()

    route := ResolutionRoute{
        ID:       "route-1",
        Name:     "process-death",
        Enabled:  true,
        Priority: 10,
        TriggerMatch: TriggerMatch{
            MonitorName: "process",
            MetricName:  "process.running",
            Severity:    "critical",
        },
        Nodes: []RouteNode{
            {
                ID: "node-1", RouteID: "route-1", Position: 1,
                NodeType: NodeTypeCondition, EvaluationMode: EvalModeFormal,
                Definition: NodeDefinition{Evaluation: "process not in process list"},
            },
            {
                ID: "node-2", RouteID: "route-1", Position: 2,
                NodeType: NodeTypeStep, EvaluationMode: EvalModeFormal,
                PrivilegeLevel: PrivilegeAutonomous,
                Definition: NodeDefinition{
                    Action: "systemctl restart {{.Labels.process}}",
                    ExpectedOutcome: "process appears in process list",
                },
            },
        },
    }

    store.Add(route)

    ctx := context.Background()
    tc := TriggerContext{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
        Labels:      map[string]string{"process": "nginx"},
    }

    matches, err := store.FindMatchingRoutes(ctx, tc, "")
    if err != nil {
        t.Fatal(err)
    }
    if len(matches) != 1 {
        t.Fatalf("expected 1 match, got %d", len(matches))
    }
    if matches[0].Name != "process-death" {
        t.Errorf("expected process-death, got %s", matches[0].Name)
    }
}

func TestMemoryStoreMatchByWorkloadType(t *testing.T) {
    store := NewMemoryRouteStore()

    store.Add(ResolutionRoute{
        ID: "r1", Name: "generic", Enabled: true,
        TriggerMatch: TriggerMatch{MonitorName: "disk"},
    })
    store.Add(ResolutionRoute{
        ID: "r2", Name: "wp-specific", Enabled: true, WorkloadType: "wordpress",
        TriggerMatch: TriggerMatch{MonitorName: "disk"},
    })

    ctx := context.Background()
    tc := TriggerContext{MonitorName: "disk", Severity: "warning"}

    // Without workload type — both match
    matches, _ := store.FindMatchingRoutes(ctx, tc, "")
    if len(matches) != 2 {
        t.Fatalf("expected 2 matches, got %d", len(matches))
    }

    // With workload type — both match (generic + specific)
    matches, _ = store.FindMatchingRoutes(ctx, tc, "wordpress")
    if len(matches) != 2 {
        t.Fatalf("expected 2 matches, got %d", len(matches))
    }

    // With different workload type — only generic matches
    matches, _ = store.FindMatchingRoutes(ctx, tc, "rails")
    if len(matches) != 1 {
        t.Fatalf("expected 1 match, got %d", len(matches))
    }
}

func TestMemoryStoreDisabledRoutesExcluded(t *testing.T) {
    store := NewMemoryRouteStore()
    store.Add(ResolutionRoute{
        ID: "r1", Name: "disabled", Enabled: false,
        TriggerMatch: TriggerMatch{MonitorName: "process"},
    })

    ctx := context.Background()
    matches, _ := store.FindMatchingRoutes(ctx, TriggerContext{MonitorName: "process"}, "")
    if len(matches) != 0 {
        t.Fatalf("expected 0 matches for disabled route, got %d", len(matches))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `go test ./internal/agent/remediation/ -v -run TestMemoryStore`
Expected: FAIL — NewMemoryRouteStore undefined.

**Step 3: Write the route store implementation**

The `RouteStore` interface with `FindMatchingRoutes(ctx, TriggerContext, workloadType) ([]ResolutionRoute, error)`. A `MemoryRouteStore` for testing and a `PostgresRouteStore` for production. The memory store sorts results by priority descending. The Postgres store queries `resolution_routes` joined with `route_nodes` ordered by position.

The `PostgresRouteStore.FindMatchingRoutes` loads all enabled routes, filters in Go (the trigger_match JSONB comparison is simpler in application code than in SQL for this structure), and returns sorted by priority.

**Step 4: Run tests**

Run: `go test ./internal/agent/remediation/ -v -run TestMemoryStore`
Expected: PASS (3 tests).

**Step 5: Commit**

```bash
git add internal/agent/remediation/store.go internal/agent/remediation/store_test.go
git commit -m "feat: add route store — in-memory and PostgreSQL implementations"
```

---

### Task 4: Trigger Evaluator — Watch Observations, Instantiate Reaction Interpretations

**Files:**
- Create: `internal/agent/remediation/trigger.go`
- Create: `internal/agent/remediation/trigger_test.go`

**Step 1: Write the failing test**

```go
package remediation

import (
    "context"
    "testing"
    "time"

    "github.com/strongai/infrastructure/internal/agent/monitor"
)

func TestTriggerEvaluatorFiresOnCritical(t *testing.T) {
    sink := monitor.NewChannelSink(10)
    reactions := make(chan *ReactionInterpretation, 10)
    eval := NewTriggerEvaluator(sink, "wp-lab", reactions)

    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()

    go eval.Serve(ctx)

    // Send a critical observation
    sink.Send(ctx, monitor.Observation{
        MonitorName: "process",
        MetricName:  "process.running",
        Value:       0.0,
        Severity:    monitor.SeverityCritical,
        Message:     "process nginx is NOT running",
        Timestamp:   time.Now(),
        Labels:      map[string]string{"process": "nginx"},
    })

    select {
    case ri := <-reactions:
        if ri.ServerID != "wp-lab" {
            t.Errorf("expected wp-lab, got %s", ri.ServerID)
        }
        if ri.TriggerSource != TriggerSourceFormalMonitor {
            t.Errorf("expected formal_monitor, got %s", ri.TriggerSource)
        }
        if ri.TriggerData.MonitorName != "process" {
            t.Errorf("expected process monitor, got %s", ri.TriggerData.MonitorName)
        }
    case <-ctx.Done():
        t.Fatal("timeout waiting for reaction interpretation")
    }
}

func TestTriggerEvaluatorIgnoresOK(t *testing.T) {
    sink := monitor.NewChannelSink(10)
    reactions := make(chan *ReactionInterpretation, 10)
    eval := NewTriggerEvaluator(sink, "wp-lab", reactions)

    ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
    defer cancel()

    go eval.Serve(ctx)

    // Send an OK observation — should not trigger
    sink.Send(ctx, monitor.Observation{
        MonitorName: "process",
        MetricName:  "process.running",
        Value:       1.0,
        Severity:    monitor.SeverityOK,
        Timestamp:   time.Now(),
    })

    select {
    case <-reactions:
        t.Fatal("should not have triggered on OK observation")
    case <-ctx.Done():
        // Expected — no reaction
    }
}
```

**Step 2: Run test to verify it fails**

Run: `go test ./internal/agent/remediation/ -v -run TestTriggerEvaluator`
Expected: FAIL — NewTriggerEvaluator undefined.

**Step 3: Write implementation**

The `TriggerEvaluator` is a `suture.Service`. It reads from the `ChannelSink`, filters for non-OK observations, applies deduplication (same monitor+metric+labels within a cooldown window, default 60s), converts to `TriggerContext`, creates a `ReactionInterpretation`, and sends it to the reactions channel.

Deduplication prevents the same fault from generating a new reaction every 10 seconds (the monitor interval). Once a reaction is in progress for a given trigger signature, new observations for the same signature are ignored until the reaction resolves or the cooldown expires.

**Step 4: Run tests**

Run: `go test ./internal/agent/remediation/ -v -run TestTriggerEvaluator`
Expected: PASS (2 tests).

**Step 5: Commit**

```bash
git add internal/agent/remediation/trigger.go internal/agent/remediation/trigger_test.go
git commit -m "feat: add trigger evaluator — watches observations, instantiates reactions"
```

---

### Task 5: Command Executor — Run Shell Commands on the Server

**Files:**
- Create: `internal/agent/remediation/executor.go`
- Create: `internal/agent/remediation/executor_test.go`

**Step 1: Write the failing test**

```go
package remediation

import (
    "context"
    "testing"
    "time"
)

func TestCommandExecutorRunsCommand(t *testing.T) {
    exec := NewCommandExecutor()
    ctx := context.Background()

    result := exec.Execute(ctx, "echo hello", 5*time.Second)
    if result.ExitCode != 0 {
        t.Errorf("expected exit 0, got %d", result.ExitCode)
    }
    if result.Stdout != "hello\n" {
        t.Errorf("expected 'hello\\n', got %q", result.Stdout)
    }
}

func TestCommandExecutorTimeout(t *testing.T) {
    exec := NewCommandExecutor()
    ctx := context.Background()

    result := exec.Execute(ctx, "sleep 10", 100*time.Millisecond)
    if result.ExitCode == 0 {
        t.Error("expected non-zero exit on timeout")
    }
    if result.Error == "" {
        t.Error("expected error message on timeout")
    }
}

func TestCommandExecutorFailingCommand(t *testing.T) {
    exec := NewCommandExecutor()
    ctx := context.Background()

    result := exec.Execute(ctx, "false", 5*time.Second)
    if result.ExitCode == 0 {
        t.Error("expected non-zero exit for 'false'")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `go test ./internal/agent/remediation/ -v -run TestCommandExecutor`
Expected: FAIL — NewCommandExecutor undefined.

**Step 3: Write implementation**

The `CommandExecutor` runs shell commands via `exec.CommandContext("bash", "-c", command)` with a timeout. It captures stdout, stderr, exit code, and duration. The executor is a thin wrapper — it does not decide what to run; the route engine decides. The executor just runs it and returns the result.

For testing, provide a `MockCommandExecutor` that returns predefined results for given commands, so the route engine can be tested without actually executing shell commands.

**Step 4: Run tests**

Run: `go test ./internal/agent/remediation/ -v -run TestCommandExecutor`
Expected: PASS (3 tests).

**Step 5: Commit**

```bash
git add internal/agent/remediation/executor.go internal/agent/remediation/executor_test.go
git commit -m "feat: add command executor — runs shell commands with timeout"
```

---

### Task 6: Route Engine — Walk Step/Condition Sequences

**Files:**
- Create: `internal/agent/remediation/engine.go`
- Create: `internal/agent/remediation/engine_test.go`

This is the core component. The route engine:
1. Receives a `ReactionInterpretation`
2. Queries the route store for matching routes
3. Picks the highest-priority match
4. Walks the route's node sequence: executes steps, evaluates conditions, follows branches
5. Updates the reaction interpretation state at each transition
6. Records each action to the history

**Step 1: Write the failing test**

Test a complete route execution with the mock command executor: process is down → check systemd → restart → verify.

```go
package remediation

import (
    "context"
    "testing"
    "time"
)

func TestRouteEngineExecutesProcessDeathRoute(t *testing.T) {
    store := NewMemoryRouteStore()
    mock := NewMockCommandExecutor()

    // Configure mock responses
    mock.OnCommand("systemctl is-active nginx", CommandResult{
        Stdout: "inactive", ExitCode: 3,
    })
    mock.OnCommand("systemctl restart nginx", CommandResult{
        ExitCode: 0,
    })
    mock.OnCommand("pgrep -x nginx", CommandResult{
        Stdout: "12345", ExitCode: 0,
    })

    // Add a simple process death route
    store.Add(ResolutionRoute{
        ID: "route-1", Name: "process-death", Enabled: true, Priority: 10,
        TriggerMatch: TriggerMatch{
            MonitorName: "process",
            MetricName:  "process.running",
            Severity:    "critical",
        },
        Nodes: []RouteNode{
            {ID: "n1", RouteID: "route-1", Position: 1,
                NodeType: NodeTypeStep, EvaluationMode: EvalModeFormal,
                PrivilegeLevel: PrivilegeAutonomous,
                Definition: NodeDefinition{
                    Action: "systemctl restart nginx",
                    Timeout: 10 * time.Second,
                },
            },
            {ID: "n2", RouteID: "route-1", Position: 2,
                NodeType: NodeTypeCondition, EvaluationMode: EvalModeFormal,
                Definition: NodeDefinition{
                    Evaluation: "pgrep -x nginx",
                    TrueLabel:  "resolved",
                    FalseLabel: "escalate",
                },
            },
        },
    })

    engine := NewRouteEngine(store, mock)
    ctx := context.Background()

    ri := NewReactionInterpretation("wp-lab", TriggerSourceFormalMonitor, TriggerContext{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
        Labels:      map[string]string{"process": "nginx"},
    })

    result, err := engine.Execute(ctx, ri)
    if err != nil {
        t.Fatal(err)
    }

    if result.State != StateResolved {
        t.Errorf("expected resolved, got %s", result.State)
    }
    if result.ResolutionMethod != ResolutionFormalRoute {
        t.Errorf("expected formal_route, got %s", result.ResolutionMethod)
    }
    if len(result.History) < 2 {
        t.Errorf("expected at least 2 history entries, got %d", len(result.History))
    }
}

func TestRouteEngineEscalatesWhenNoRouteMatches(t *testing.T) {
    store := NewMemoryRouteStore() // empty — no routes
    mock := NewMockCommandExecutor()
    engine := NewRouteEngine(store, mock)

    ctx := context.Background()
    ri := NewReactionInterpretation("wp-lab", TriggerSourceFormalMonitor, TriggerContext{
        MonitorName: "process",
        MetricName:  "process.running",
        Severity:    "critical",
    })

    result, err := engine.Execute(ctx, ri)
    if err != nil {
        t.Fatal(err)
    }

    if result.State != StateEscalated {
        t.Errorf("expected escalated, got %s", result.State)
    }
    if result.ResolutionMethod != ResolutionEscalated {
        t.Errorf("expected escalated method, got %s", result.ResolutionMethod)
    }
}

func TestRouteEngineRespectsGatedPermissions(t *testing.T) {
    store := NewMemoryRouteStore()
    mock := NewMockCommandExecutor()

    store.Add(ResolutionRoute{
        ID: "route-1", Name: "gated-route", Enabled: true, Priority: 10,
        TriggerMatch: TriggerMatch{MonitorName: "cpu"},
        Nodes: []RouteNode{
            {ID: "n1", RouteID: "route-1", Position: 1,
                NodeType: NodeTypeStep, EvaluationMode: EvalModeFormal,
                PrivilegeLevel: PrivilegeGated,
                Definition: NodeDefinition{Action: "kill -9 12345"},
            },
        },
    })

    engine := NewRouteEngine(store, mock)
    ctx := context.Background()

    ri := NewReactionInterpretation("wp-lab", TriggerSourceFormalMonitor, TriggerContext{
        MonitorName: "cpu", Severity: "critical",
    })

    result, err := engine.Execute(ctx, ri)
    if err != nil {
        t.Fatal(err)
    }

    // Should be pending approval, not executed
    if result.PermissionState != PermissionPendingApproval {
        t.Errorf("expected pending_approval, got %s", result.PermissionState)
    }
    // The command should NOT have been executed
    if mock.WasCalled("kill -9 12345") {
        t.Error("gated command should not have been executed")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `go test ./internal/agent/remediation/ -v -run TestRouteEngine`
Expected: FAIL — NewRouteEngine undefined.

**Step 3: Write the route engine**

The engine:
- Calls `store.FindMatchingRoutes(ctx, ri.TriggerData, workloadType)`
- Picks the highest-priority match (routes are already sorted by priority)
- Sets `ri.MatchedRouteID`, transitions state to Diagnosing
- Walks nodes in position order:
  - **Step** with autonomous privilege → execute via CommandExecutor, record to history
  - **Step** with gated privilege → set `ri.PermissionState = PendingApproval`, stop execution, return
  - **Condition** with formal evaluation → execute the evaluation command, check exit code (0 = true), follow branch
  - Conditions with TrueLabel "resolved" → set state to Resolved
  - Conditions with FalseLabel "escalate" → set state to Escalated
- If no route matches → set state to Escalated, method to Escalated
- After route completes successfully → state transitions: Diagnosing → Remediating → Verifying → Resolved

Template substitution: step actions can contain `{{.Labels.process}}` etc. — simple string replacement from the trigger context labels.

**Step 4: Run tests**

Run: `go test ./internal/agent/remediation/ -v -run TestRouteEngine`
Expected: PASS (3 tests).

**Step 5: Commit**

```bash
git add internal/agent/remediation/engine.go internal/agent/remediation/engine_test.go
git commit -m "feat: add route engine — walks step/condition sequences, respects permissions"
```

---

### Task 7: New Monitors — Config, Connection, Swap

**Files:**
- Create: `internal/agent/monitor/config.go`
- Create: `internal/agent/monitor/connection.go`
- Create: `internal/agent/monitor/swap.go`
- Modify: `internal/agent/monitor/monitor_test.go` — add tests for new monitors

Three new monitors identified in the design that don't exist in Phase 0:

**ConfigMonitor:** Computes SHA256 checksums of configured files (e.g., `/etc/nginx/nginx.conf`, `/etc/mysql/my.cnf`). On first run, stores the checksums. On subsequent runs, compares. If a checksum changes, emits a Warning observation. Config files and their known-good checksums are provided in the config.

**ConnectionMonitor:** For MySQL, runs `mysqladmin -u root status` and parses "Threads" count, or queries `SHOW STATUS LIKE 'Threads_connected'`. For PostgreSQL, runs `psql -c "SELECT count(*) FROM pg_stat_activity"`. Compares against configured max_connections threshold (default 80%). Emits Warning/Critical based on percentage.

**SwapMonitor:** Reads `/proc/swaps` or `/proc/meminfo` (SwapTotal, SwapFree). Computes swap usage percentage. Emits Warning above threshold (default 25%), Critical above higher threshold (default 50%).

Each follows the same pattern as existing monitors: implements `suture.Service`, collects on interval, publishes `Observation` to `Sink`.

**Step 1: Write failing tests for all three**

**Step 2: Run tests to verify they fail**

Run: `go test ./internal/agent/monitor/ -v -run "TestConfig|TestConnection|TestSwap"`
Expected: FAIL.

**Step 3: Implement each monitor**

**Step 4: Run tests**

Run: `go test ./internal/agent/monitor/ -v`
Expected: PASS (all existing + new tests).

**Step 5: Commit**

```bash
git add internal/agent/monitor/config.go internal/agent/monitor/connection.go internal/agent/monitor/swap.go internal/agent/monitor/monitor_test.go
git commit -m "feat: add config, connection, and swap monitors"
```

---

### Task 8: Integration — Wire Remediation Pipeline into Agent

**Files:**
- Modify: `cmd/agent/main.go` — add trigger evaluator, route engine, remediation service
- Create: `internal/agent/remediation/service.go` — suture.Service that orchestrates the pipeline
- Create: `internal/agent/remediation/service_test.go`

The `RemediationService` is a `suture.Service` added to the supervision tree's core services. It:
1. Reads `ReactionInterpretation` from the reactions channel (populated by TriggerEvaluator)
2. Passes each to the RouteEngine for execution
3. Reports completed reactions to the EventSink (for the EventReporter to send to the platform)
4. Logs results

**Step 1: Write failing test for the service**

Test end-to-end: observation enters ChannelSink → TriggerEvaluator creates RI → RemediationService picks it up → RouteEngine executes → event reported.

**Step 2: Implement RemediationService**

**Step 3: Update cmd/agent/main.go**

Add to main():
```go
// Reaction interpretation pipeline
reactions := make(chan *remediation.ReactionInterpretation, 100)
triggerEval := remediation.NewTriggerEvaluator(sink, cfg.ServerID, reactions)
tree.AddObserver("trigger-evaluator", triggerEval)

routeStore := remediation.NewMemoryRouteStore() // TODO: PostgresRouteStore when platform provides routes
executor := remediation.NewCommandExecutor()
engine := remediation.NewRouteEngine(routeStore, executor)
remediationSvc := remediation.NewRemediationService(reactions, engine, eventSink, cfg.ServerID)
tree.AddCoreService("remediation", remediationSvc)
```

Also register the new monitors (config, connection, swap) based on workload type, and seed the route store with the 13 formal routes from the design.

**Step 4: Run all tests**

Run: `go test ./... -v`
Expected: PASS.

**Step 5: Build both binaries**

Run: `go build ./cmd/agent && go build ./cmd/platform`
Expected: Success.

**Step 6: Commit**

```bash
git add cmd/agent/main.go internal/agent/remediation/service.go internal/agent/remediation/service_test.go
git commit -m "feat: wire remediation pipeline into agent supervision tree"
```

---

### Task 9: Seed Routes — Define the 13 Formal Resolution Routes

**Files:**
- Create: `internal/agent/remediation/routes.go`

This file contains a function `DefaultRoutes() []ResolutionRoute` that returns all 13 formally defined resolution routes from the design doc, each with their step/condition sequences. These are loaded into the MemoryRouteStore on agent startup.

Each route is defined as Go structs (not SQL) so they can be used in both the MemoryRouteStore (for now) and later inserted into PostgreSQL.

The routes use template variables for service names (e.g., `{{.Labels.process}}`, `{{.Labels.port}}`) so a single route definition handles all workload types.

**Step 1: Write tests verifying route structure**

Test that all 13 routes have valid structure: non-empty names, valid node types, valid privilege levels, contiguous positions, conditions have evaluation criteria.

**Step 2: Implement DefaultRoutes()**

**Step 3: Run tests**

Run: `go test ./internal/agent/remediation/ -v -run TestDefaultRoutes`
Expected: PASS.

**Step 4: Commit**

```bash
git add internal/agent/remediation/routes.go
git commit -m "feat: define 13 formal resolution routes from Phase 1 design"
```

---

### Task 10: Fault Injector — Cause Faults and Verify Resolution

**Files:**
- Create: `internal/agent/faultinjector/injector.go`
- Create: `internal/agent/faultinjector/injector_test.go`
- Create: `cmd/inject/main.go` — CLI tool to inject faults

The fault injector is a separate binary (`cmd/inject`) that runs on lab servers. It:
1. Causes a specific fault (kill process, fill disk, block port, corrupt config)
2. Waits for the agent to detect and resolve
3. Verifies the resolution by checking the system state after a timeout
4. Reports pass/fail

**Fault implementations:**

| Fault          | Implementation                                               | Cleanup                                           |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------- |
| process-death  | `kill -9 $(pgrep -x <process>)`                              | Agent should restart it                           |
| disk-pressure  | `dd if=/dev/zero of=/tmp/fault-inject-fill bs=1M count=<MB>` | `rm /tmp/fault-inject-fill`                       |
| port-block     | `iptables -I INPUT -p tcp --dport <port> -j DROP`            | `iptables -D INPUT -p tcp --dport <port> -j DROP` |
| config-corrupt | Append invalid line to config file (backup original first)   | Restore from backup                               |

**Step 1: Write test for injector lifecycle**

Test with mock executor: inject fault → wait → verify → cleanup.

**Step 2: Implement injector**

**Step 3: Implement CLI**

The CLI takes: `--fault process-death --target nginx --timeout 60s --server wp-lab`

**Step 4: Build**

Run: `go build ./cmd/inject`
Expected: Success.

**Step 5: Commit**

```bash
git add internal/agent/faultinjector/ cmd/inject/
git commit -m "feat: add fault injector — cause faults, verify agent resolution"
```

---

### Task 11: Deploy Updated Agent and Validate on Lab Servers

**Files:**
- Modify: `deploy/ansible/roles/agent/tasks/main.yml` — update to deploy new agent binary

**Step 1: Cross-compile agent for Linux**

Run: `GOOS=linux GOARCH=amd64 go build -o agent-linux ./cmd/agent`

**Step 2: Cross-compile fault injector for Linux**

Run: `GOOS=linux GOARCH=amd64 go build -o inject-linux ./cmd/inject`

**Step 3: Apply database migration on ctrl-lab**

Run: `ssh -i ~/.ssh/stability-lab root@178.104.59.223 "sudo -u postgres psql -d strongai" < migrations/002_resolution_routes.up.sql`

**Step 4: Deploy updated agent to all workload servers**

Copy the new binary and restart the service on each server.

**Step 5: Deploy fault injector to all workload servers**

Copy the inject binary.

**Step 6: Run a basic fault injection test**

SSH into wp-lab, inject a process death fault on nginx, verify the agent detects and restarts it within 60 seconds.

Run: `ssh -i ~/.ssh/stability-lab root@178.104.61.200 "./inject-linux --fault process-death --target nginx --timeout 60s"`
Expected: PASS — nginx killed and restarted by agent.

**Step 7: Run fault injection on all servers**

Test process death on each server's primary workload service.

**Step 8: Commit any deployment adjustments**

```bash
git commit -m "feat: deploy Phase 1 remediation pipeline to Stability Lab"
```
