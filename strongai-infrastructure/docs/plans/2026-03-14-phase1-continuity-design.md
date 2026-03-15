# Phase 1: Continuity — Design

## Overview

Phase 1 adds the remediation pipeline to the Stability Lab. Phase 0 established monitoring — agents detect conditions and report metrics. Phase 1 makes agents act on what they detect.

The architecture has two layers: formal and informal. Formal monitors operate in computable number space (thresholds, rates, correlations). Informal agents operate in semantic space (interpretation, pattern recognition, meaning). Both exist at every level of the system — per-server and across the orthogonal planes that cut across all servers.

## Core Concepts

### Formal vs Informal

The distinction is the mode of evaluation, not the scope or location.

**Formal agents** evaluate in computable number space. A formal monitor can span multiple data sources and compute functions over them. The evaluation is a defined computation over measurable quantities.

**Informal agents** evaluate in semantic space. They read the same observations but evaluate through understanding. "This combination of metrics looks like the early stages of a memory leak in a Rails app" is an interpretation, not a threshold.

Both formal and informal agents exist at every level:

- **Per-server plane** — formal monitors and informal agents on each server
- **Network orthogonal plane** — formal and informal agents spanning a network region
- **Strong.AI orthogonal plane** — formal and informal agents spanning the entire fleet

The orthogonal planes are "orthogonal" because they cut across the agent spaces on every server in their domain.

### Trigger Mechanisms

There are two trigger paths:

1. **Formal trigger** — A formal monitor recognizes an exceptional indicator and triggers the informal agent. The informal agent arrives already in triggered mode, not monitor mode.
2. **Self-trigger** — The informal agent sees something across all formal monitors that no individual monitor can see from its embedded conditions. It self-triggers.

### Reaction Interpretation

The reaction interpretation is instantiated when an agent is triggered. It is the central structure of Phase 1.

A reaction interpretation holds:

- **Trigger source** — what triggered it and how (formal indicator, informal interpretation, external formal process)
- **Trigger context** — raw data: observations, metrics, state at the moment of trigger
- **Semantic evaluation** — diagnosis produced by the informal agent, or the formal indicator's defined meaning
- **System state** — current state of all monitored dimensions on this server
- **History** — prior events with similar characteristics, their outcomes
- **Available routes** — resolution routes whose conditions match this context, filtered by privileges
- **Composed routes** — if no single route matches, compositions assembled from available steps
- **Permission state** — which route steps can execute autonomously, which are pending approval
- **Resolution state** — tracks execution (Detected → Diagnosing → Remediating → Verifying → Resolved / Escalated)

### Resolution Routes

**Formal resolution routes** are ordered sequences of steps and conditions stored in the database. Conditions are interspersed throughout — they control flow, branching, and termination. Some conditions are formally evaluable (computable); some are compound language conditions requiring semantic evaluation.

**Informal resolution routes** are Claude skills. The informal agent has context (the reaction interpretation), knowledge (the knowledge base, prior outcomes), and whatever skills have been made available to its context.

### Resolution Order

1. Trigger → reaction interpretation instantiated
2. Search for matching formal routes
3. If a formal route matches and all conditions are formally evaluable → execute mechanically, no LLM
4. If formal routes don't resolve → informal agent activates with the reaction interpretation as context

The informal agent is the fallback the human used to be. The formal system handles what it can. Everything it can't used to land on a human's desk. Now it lands on the informal agent. Humans are still there — gated permissions, escalation — but they're not the default fallback.

### Permission Model

Permissions are on route steps, not on actions globally. Routes compose, and the permission model of a composed route is determined by its most restrictive step.

| Level      | Behavior                                   |
| ---------- | ------------------------------------------ |
| Autonomous | Execute and raise notification event       |
| Gated      | Request approval and wait in pending state |
| Obligatory | Must execute, cannot skip                  |

If a route contains gated steps, the agent raises events and waits for human approval. If nothing can be composed → escalation.

### Feedback Loop

When the informal agent resolves something, that resolution can be studied and potentially formalized into a new route. The system gets more formal over time. This is the lifecycle:

1. **Emergence** — informal agent notices a pattern
2. **Response** — it resolves the issue
3. **Codification** — if the pattern is stable, it becomes a formal route
4. **Quieting** — the formal system handles it; the informal agent moves on

## Data Model

### `resolution_routes`

| Column        | Type        | Description                                     |
| ------------- | ----------- | ----------------------------------------------- |
| id            | uuid        | Primary key                                     |
| name          | text        | Human-readable name                             |
| workload_type | text        | Which workload this applies to (nullable = any) |
| trigger_match | jsonb       | Conditions under which this route is selected   |
| priority      | integer     | When multiple routes match, higher wins         |
| enabled       | boolean     | Can be disabled without deletion                |
| created_at    | timestamptz |                                                 |

### `route_nodes`

| Column          | Type    | Description                                                                                        |
| --------------- | ------- | -------------------------------------------------------------------------------------------------- |
| id              | uuid    | Primary key                                                                                        |
| route_id        | uuid    | FK to resolution_routes                                                                            |
| position        | integer | Order in the sequence                                                                              |
| node_type       | text    | 'step' or 'condition'                                                                              |
| definition      | jsonb   | For steps: action, preconditions, expected_outcome. For conditions: evaluation criteria, branches. |
| evaluation_mode | text    | 'formal' or 'semantic' — whether this node can be evaluated computationally                        |
| privilege_level | text    | 'autonomous', 'gated', 'obligatory' (steps only)                                                   |
| branch_on_true  | uuid    | Next node if condition is true (nullable)                                                          |
| branch_on_false | uuid    | Next node if condition is false (nullable)                                                         |

### `reaction_interpretations`

| Column              | Type        | Description                                                       |
| ------------------- | ----------- | ----------------------------------------------------------------- |
| id                  | uuid        | Primary key                                                       |
| server_id           | text        | Which server                                                      |
| trigger_source      | text        | 'formal_monitor', 'informal_agent', 'external_process'            |
| trigger_data        | jsonb       | Raw observation/indicator data                                    |
| semantic_evaluation | text        | Diagnosis (populated by informal agent if involved)               |
| system_state        | jsonb       | Snapshot of all monitor readings at trigger time                  |
| matched_route_id    | uuid        | FK to resolution_routes (nullable if no match)                    |
| resolution_method   | text        | 'formal_route', 'informal_agent', 'escalated'                     |
| permission_state    | text        | 'executing', 'pending_approval', 'approved', 'denied'             |
| state               | text        | detected, diagnosing, remediating, verifying, resolved, escalated |
| created_at          | timestamptz |                                                                   |
| resolved_at         | timestamptz |                                                                   |

### `reaction_history`

| Column                     | Type        | Description                              |
| -------------------------- | ----------- | ---------------------------------------- |
| id                         | uuid        | Primary key                              |
| reaction_interpretation_id | uuid        | FK to reaction_interpretations           |
| node_id                    | uuid        | FK to route_nodes (nullable if informal) |
| action_taken               | text        | What was executed                        |
| result                     | jsonb       | Outcome data                             |
| timestamp                  | timestamptz |                                          |

## Components

| Component               | Description                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------- |
| Formal monitors         | Already exist (Phase 0). Compute over measurable quantities. Trigger the reaction interpretation pipeline.    |
| Reaction interpretation | Context object instantiated on trigger. Holds trigger data, system state, history, available routes.          |
| Route store             | Database tables holding formally defined routes — sequences of steps and conditions.                          |
| Route engine            | Walks a formal route's step/condition sequence. Executes steps, evaluates formal conditions.                  |
| Informal agent          | Claude with available skills. Activated when formal routes can't resolve. Reaction interpretation as context. |
| Knowledge base          | Already exists (Phase 0). Stores prior events, outcomes, resolution patterns. Feeds history into reactions.   |
| Permission gate         | Evaluates privilege levels on steps. Autonomous → execute. Gated → wait. Obligatory → must execute.           |

## Formal Exception Catalogue

### Exceptions Applicable to Stability Lab

| Exception                      | Applies To                                        | Formal Monitor                           |
| ------------------------------ | ------------------------------------------------- | ---------------------------------------- |
| Process death                  | All (nginx, mysql, postgresql, redis, node, puma) | ProcessMonitor                           |
| Disk pressure                  | All                                               | DiskMonitor                              |
| Inode exhaustion               | All                                               | DiskMonitor                              |
| Memory pressure                | All                                               | MemoryMonitor                            |
| CPU saturation                 | All                                               | CPUMonitor                               |
| Port unreachable               | All (80, 3306, 5432, 6379, 3000)                  | PortMonitor                              |
| HTTP health degraded           | wp-lab, rails-lab, node-lab                       | ResponseMonitor                          |
| Certificate expiry             | Future (no TLS yet)                               | CertMonitor                              |
| Log accumulation               | All                                               | DiskMonitor                              |
| Config corruption              | All (nginx.conf, my.cnf, postgresql.conf, etc.)   | New: ConfigMonitor                       |
| Database connection exhaustion | wp-lab (MySQL), rails-lab (PostgreSQL)            | New: ConnectionMonitor                   |
| Swap usage                     | All                                               | New: SwapMonitor or extend MemoryMonitor |
| Service restart needed         | All                                               | Derived from other exceptions            |

### Additional Exceptions from xnn (applicable when infrastructure grows)

| Exception                | Formal Indicator                          |
| ------------------------ | ----------------------------------------- |
| High error rate          | >5% error rate sustained 5min             |
| Critical error rate      | >20% error rate sustained 5min            |
| High latency             | p99 >2s sustained 5min                    |
| Event loop lag           | Node.js event loop >100ms                 |
| Pod/service restart loop | >3 restarts in 30min                      |
| Stuck rollout            | Not at desired state for >10min           |
| Cert renewal failure     | Renewal failed in last 24h                |
| Unpatched CVE            | Critical/high CVE unpatched >48h          |
| Secret age exceeded      | Secret past rotation schedule             |
| Backup age exceeded      | Last full backup >8 days                  |
| WAL archive gap          | pgBackRest WAL continuity broken          |
| Backup size anomaly      | Full backup <50% or >200% of previous     |
| Resource overallocation  | Service using <20% of allocated resources |
| Cluster saturation trend | Utilization trending toward capacity      |

## Formal Resolution Routes

### 1. Process Death

```
[C] Expected process not in process list
[S] Check if service unit exists in systemd                        → autonomous
[C] Service unit exists → continue; doesn't exist → escalate
[S] systemctl restart <service>                                    → autonomous
[C] Process appears in process list within 10s → continue; doesn't → retry
[S] systemctl restart <service> (retry)                            → autonomous
[C] Process appears within 10s → resolved; doesn't → continue
[S] Check journal logs for crash reason                            → autonomous
[C] Known crash pattern → branch to specific route; unknown → escalate
```

### 2. Service Restart (subroute)

```
[S] systemctl restart <service>                                    → autonomous
[C] Service reports active within 10s → continue; doesn't → continue
[S] systemctl stop <service>, wait 5s, systemctl start <service>   → autonomous
[C] Service reports active within 10s → resolved; doesn't → escalate
```

### 3. Disk Pressure

```
[C] Disk usage above warning threshold (e.g., 85%)
[S] Identify largest directories under /var/log, /tmp, /var/cache  → autonomous
[C] Clearable space found → continue; not found → escalate
[S] Clear rotated logs: find /var/log -name '*.gz' -mtime +7 -delete  → autonomous
[S] Clear tmp: find /tmp -mtime +3 -delete                        → autonomous
[S] Clear apt cache: apt-get clean                                 → autonomous
[C] Disk usage dropped below threshold → resolved; still above → continue
[S] Identify largest non-clearable consumers                       → autonomous
[C] Database growth → advise maintenance; app logs → rotate; other → escalate
```

### 4. Inode Exhaustion

```
[C] Inode usage above threshold (e.g., 90%)
[S] Find directories with most files                               → autonomous
[C] Session/cache directory identified → continue; unknown → escalate
[S] Clear identified cache/session directory                       → autonomous
[C] Inode usage dropped below threshold → resolved; still above → escalate
```

### 5. Memory Pressure

```
[C] Memory usage above threshold (e.g., 90%)
[S] Identify top memory consumers                                  → autonomous
[C] Known service consuming excess → continue; unknown process → escalate
[S] Check for memory leak pattern (usage growing over time)        → autonomous
[C] Leak detected → continue to restart; normal high usage → escalate (capacity)
[S] Restart offending service                                      → autonomous
[C] Memory drops after restart → resolved; doesn't → escalate
```

### 6. CPU Saturation

```
[C] CPU usage above threshold sustained (e.g., >90% for 5min)
[S] Identify top CPU consumers                                     → autonomous
[C] Known service → continue; unknown process → investigate
[S] Check if process is expected workload or runaway                → autonomous
[C] Runaway process → continue; primary workload under load → escalate (capacity)
[S] Kill runaway process or restart service                        → gated
[C] CPU drops after action → resolved; doesn't → escalate
```

### 7. Port Unreachable

```
[C] TCP connect to expected port fails
[S] Check if owning service process is running                     → autonomous
[C] Not running → branch to "Process Death"; running → continue
[S] Check if port is bound: ss -tlnp                              → autonomous
[C] Not bound (internal crash) → continue; bound (network issue) → escalate
[S] Restart owning service                                         → autonomous
[C] Port responds within 10s → resolved; doesn't → escalate
```

### 8. HTTP Health Degraded

```
[C] HTTP GET to health endpoint returns non-200 or timeout
[S] Check if service process is running                            → autonomous
[C] Not running → branch to "Process Death"; running → continue
[S] Check if port responds to TCP                                  → autonomous
[C] Not responding → branch to "Port Unreachable"; responding → continue
[S] Check service error logs (last 50 lines)                       → autonomous
[C] Config error → branch to "Config Corruption"; dependency error → continue; unknown → escalate
[S] Check upstream dependencies (database, redis)                  → autonomous
[C] Dependency down → branch to dependency's route; healthy → continue
[S] Restart service                                                → autonomous
[C] Health responds 200 within 15s → resolved; doesn't → escalate
```

### 9. Certificate Expiry

```
[C] Certificate expires within 30 days
[S] Attempt renewal via certbot renew                              → autonomous
[C] Renewal succeeded → continue; failed → escalate
[S] Reload web server: systemctl reload nginx                      → autonomous
[C] TLS validates with new cert → resolved; doesn't → escalate
```

### 10. Log Accumulation

```
[C] /var/log usage exceeds threshold or growing faster than expected
[S] Identify largest log files                                     → autonomous
[S] Force log rotation: logrotate --force                          → autonomous
[S] Clear old rotated logs                                         → autonomous
[C] Size reduced → resolved; still growing → continue
[S] Identify service producing excessive logs                      → autonomous
[C] Service identified → continue; can't determine → escalate
[S] Check if log level is too verbose                              → autonomous
[C] Verbose → escalate with recommendation; not verbose → escalate
```

### 11. Config Corruption

```
[C] Config file checksum differs from known good
[S] Diff current config against last known good                    → autonomous
[C] Minor/expected changes → resolved with notification; significant → continue
[S] Validate config syntax (nginx -t, mysqld --validate-config)    → autonomous
[C] Valid → resolved with notification; invalid → continue
[S] Restore from last known good backup                            → gated
[C] Restored and service reloaded → resolved; failed → escalate
```

### 12. Database Connection Exhaustion

```
[C] Active connections approaching max (>80% of max_connections)
[S] Identify connection sources (SHOW PROCESSLIST / pg_stat_activity)  → autonomous
[C] Idle connections from known service → continue; unknown → escalate
[S] Kill idle connections older than threshold                     → gated
[C] Count drops → resolved; doesn't → continue
[S] Restart application service to reset connection pool           → autonomous
[C] Normalizes → resolved; doesn't → escalate
```

### 13. Swap Usage

```
[C] Swap usage exceeds threshold (e.g., >100MB or >25%)
[S] Identify top memory consumers                                  → autonomous
[C] Known service → branch to "Memory Pressure"; system-wide → continue
[S] Check for OOM killer activity: dmesg | grep -i oom             → autonomous
[C] OOM kills detected → escalate (increase memory); no OOM → continue
[S] Check if swap is stable or growing                             → autonomous
[C] Growing → escalate (memory leak); stable → resolved with notification
```

## Privilege Summary

| Level      | Count          | Examples                                                        |
| ---------- | -------------- | --------------------------------------------------------------- |
| Autonomous | ~35 steps      | Service restarts, log clearing, diagnostics, monitoring queries |
| Gated      | ~3 steps       | Kill runaway process, kill idle DB connections, restore config  |
| Escalate   | ~15 conditions | Unknown patterns, capacity issues, unresolvable failures        |

## Fault Injection (Test Harness)

The fault injector is a formal process that:

1. Causes a fault on a server (kills a process, fills disk, drops a port, corrupts a config)
2. Triggers the agent directly as a formal process — the agent arrives already in triggered mode
3. Observes the reaction interpretation lifecycle
4. Verifies the outcome

The injector and the remediation engine validate each other. If the injector causes a fault and the agent doesn't resolve it, either the agent is broken or the fault wasn't realistic. If the agent resolves it but the injector doesn't see the resolution, the injector's verification is broken.

### Phase 1 Fault Types

| Fault                 | Injection Method                                | Expected Route                  |
| --------------------- | ----------------------------------------------- | ------------------------------- |
| Process death         | kill -9 <pid>                                   | Route 1: Process Death          |
| Disk pressure         | dd if=/dev/zero of=/tmp/fill bs=1M              | Route 3: Disk Pressure          |
| Port unavailability   | iptables -A INPUT -p tcp --dport <port> -j DROP | Route 7: Port Unreachable       |
| Service degradation   | tc qdisc add dev eth0 root netem delay 500ms    | Route 8: HTTP Health Degraded   |
| Config corruption     | Modify nginx.conf with invalid directive        | Route 11: Config Corruption     |
| Connection exhaustion | Open max_connections idle connections           | Route 12: Connection Exhaustion |

## Implementation Layers

Phase 1 builds in three layers, each validating the next:

### Layer A: Mock + Hardcoded Rules

Unit tests simulate monitor observations. Hardcoded rules map exceptions to resolution steps. The full pipeline works end-to-end: trigger → reaction interpretation → route matching → step execution → verification → resolution. No LLM, no real faults.

### Layer B: Real Faults + Formal Routes

Fault injector runs on lab servers. Actually kills processes, fills disks, drops ports. Formal routes from the database execute mechanically. The route engine walks step/condition sequences. The agent detects and resolves real problems without semantic evaluation.

### Layer C: Informal Agent

When formal routes can't resolve, the informal agent activates. Claude with available skills, the reaction interpretation as context, formal routes and allowed actions as tools. The informal agent is the fallback the human used to be.

## Scope Boundaries

**In scope for Phase 1:**
- Per-server formal monitors and reaction interpretation pipeline
- Formal route engine (walks step/condition sequences from database)
- 13 formal exception types with resolution routes
- Fault injector for the 6 core fault types
- Informal agent as fallback (single-server scope)
- Knowledge base integration (history feeds into reaction interpretations)

**Out of scope (later phases):**
- Orthogonal planes (Phase 4: Coordination)
- Agent-to-agent composition across servers (Phase 4)
- Autonomous operation without platform connectivity (Phase 5)
- Predictive detection / slow-burn degradation (Phase 2)
- Adversarial detection and containment (Phase 3)
