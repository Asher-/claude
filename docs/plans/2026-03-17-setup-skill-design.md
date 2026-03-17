# Setup Skill Design

## Purpose

An interactive, re-runnable setup wizard that bootstraps Claude Code's environment on a fresh machine. Handles MCPs, skills, hooks, and global configuration. Targets macOS (ARM + Intel), Linux, and Windows (WSL).

## Principles

1. **Source vs product separation** — source lives in git submodules, product (binaries, venvs, node_modules, deployed configs) is built locally and never committed. No platform-specific artifacts leak across machines.
2. **Re-runnable / idempotent** — every run detects current state, reports a checklist, and only acts on what's missing or outdated. Safe to run again after installing new software (e.g., Hopper).
3. **Interactive menus** — for each missing dependency: (a) install it, (b) provide a custom path, (c) skip for now.
4. **Statement-MCP first** — installed before everything else so it can log the rest of the setup.
5. **settings.json is constructed, not copied** — each entry is justified by what's actually installed.

## Source (in git, portable)

| Path                       | Type      | Repo                                    |
| -------------------------- | --------- | --------------------------------------- |
| `mcp/context/`             | Submodule | StrongAI/claude-mcp-context             |
| `mcp/statement/`           | Submodule | StrongAI/claude-statement-mcp           |
| `strongai/infrastructure/` | Submodule | StrongAI/claude-strongai-infrastructure |
| `hopper-mcp/`              | Submodule | Asher-/claude-hopper-mcp                |
| `serena/`                  | Submodule | Asher-/serena (fork of oraios/serena)   |
| `skills/`                  | Submodule | Asher-/claude-skills                    |
| `scripts/`                 | Submodule | StrongAI/claude-scripts                 |

## Product (built locally, never committed)

| Path                                                   | Contents                  | Built from                                   |
| ------------------------------------------------------ | ------------------------- | -------------------------------------------- |
| `~/.claude/mcp-servers/context/dist/`, `node_modules/` | Built JS + deps           | `mcp/context/` source                        |
| `~/.claude/mcp-servers/statement-go/statement-mcp`     | Compiled Go binary (arch) | `strongai/infrastructure/cmd/statement-mcp/` |
| `hopper-mcp/.venv/`                                    | Python venv               | `hopper-mcp/` source                         |
| `serena/.venv/`                                        | Python 3.11 venv          | `serena/` source                             |
| `~/.claude/skills/`                                    | Deployed SKILL.md copies  | `skills/` submodule via sync-skills.py       |
| `~/.claude/scripts/*`                                  | Symlinks                  | `scripts/` submodule                         |
| `~/.claude.json`                                       | MCP server declarations   | Templated by setup skill                     |
| `~/.claude/settings.json`                              | Permissions, hooks, env   | Constructed by setup skill                   |
| `~/.strongai/models/arctic-embed-m-v2/`                | ONNX model + tokenizer    | Downloaded from HuggingFace                  |

## Execution Phases

### Phase 0: Platform Detection & System Dependencies

1. Detect platform: macOS-ARM, macOS-Intel, Linux, Windows-WSL
2. Check system-level dependencies and offer to install missing ones:

| Dependency  | macOS                      | Linux                          | Windows (WSL)  |
| ----------- | -------------------------- | ------------------------------ | -------------- |
| Node.js     | `brew install node`        | `apt install nodejs` / nvm     | Same as Linux  |
| Go          | `brew install go`          | `apt install golang` / tarball | Same as Linux  |
| Python 3.11 | `brew install python@3.11` | `apt install python3.11`       | Same as Linux  |
| uv          | `brew install uv`          | `curl ... uv`                  | Same as Linux  |
| PostgreSQL  | `brew install postgresql`  | `apt install postgresql`       | Same as Linux  |
| pgvector    | `brew install pgvector`    | Build from source              | Same as Linux  |
| onnxruntime | `brew install onnxruntime` | Download release from GitHub   | Same as Linux  |
| Docker      | Docker Desktop             | `apt install docker.io`        | Docker Desktop |

### Phase 1: Statement-MCP (first — logs the rest)

1. Verify PostgreSQL running → offer to install/start
2. Verify pgvector extension → offer to install
3. Create `claude_statements` database if missing
4. Verify onnxruntime → offer to install
5. Download embedding model (`Snowflake/snowflake-arctic-embed-m-v2.0`) to `~/.strongai/models/arctic-embed-m-v2/` if missing:
   - `model.onnx` from `onnx/model.onnx` in HF repo
   - `tokenizer.json` from repo root
6. Build: `go build -o ~/.claude/mcp-servers/statement-go/statement-mcp ./cmd/statement-mcp/` from `strongai/infrastructure/`
7. Write statement-mcp entry to `~/.claude.json`
8. Verify it starts and connects
9. **From here on, log setup progress to statement-mcp**

### Phase 2: Remaining MCPs

**context-lens (all platforms):**
1. Copy/link source from `mcp/context/` to `~/.claude/mcp-servers/context/`
2. `npm install && npm run build`
3. Write config entry: `node ~/.claude/mcp-servers/context/dist/index.js`

**git (all platforms):**
1. Verify `uvx` available
2. Write config entry: `uvx mcp-server-git`

**github-mcp-server (all platforms):**
1. Verify Docker running
2. Prompt for GitHub PAT (never hardcode)
3. Write config entry with Docker command

**serena (all platforms — Swift LSP):**
1. Verify Python 3.11 + uv
2. Create venv: `uv venv --python 3.11` in `serena/`
3. Install: `uv pip install -e .`
4. Write config entry: `serena/.venv/bin/serena-mcp-server`
5. Note: uses fork at `Asher-/serena` (Swift support PR)

**hopper (macOS only — requires Hopper Disassembler):**
- Guard: macOS + `/Applications/Hopper*` exists
- If guard fails: skip, print "Run setup again after installing Hopper to enable this"
- If guard passes:
  1. Create venv: `uv venv` in `hopper-mcp/`
  2. Install: `uv pip install -e .`
  3. Write config entry

### Phase 3: Skills & Global Config

1. Deploy scripts: symlink each script from `scripts/` submodule into `~/.claude/scripts/`
2. Construct and write `~/.claude/settings.json` (see below)
3. Deploy `~/.claude/CLAUDE.md`
4. Deploy `~/.claude/CONVENTIONS.md`
5. Run `sync-skills.py` to populate `~/.claude/skills/`
6. Log completion to statement-mcp

## settings.json Construction

The file is **constructed from installed state**, not copied from a template.

### env

Feature flags. Preserve existing values, add only flags required by new components.

```json
"env": {
  "ENABLE_LSP_TOOL": "1",
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
}
```

### permissions.deny

Driven by context-lens installation. If context-lens is installed:

```json
"deny": [
  "Read(*)", "Grep(*)", "Glob(*)", "Bash(*)", "NotebookEdit(*)",
  "mcp__Claude_in_Chrome(*)", "mcp__Control_Chrome(*)"
]
```

Rationale: Read/Grep/Glob are denied because they're sloppy exploration tools — context-lens forces structured access. Bash is gated through context-lens `run_command`. Write and Edit are **not** denied because they represent intentional action.

If context-lens is NOT installed: only the Chrome bans remain (user preference).

### permissions.allow

Built from first principles:

```
core_always = [
  Agent, TodoWrite, Skill, ToolSearch,
  Write, Edit,                              # intentional action — never denied
  WebSearch, WebFetch, TaskOutput,
  EnterPlanMode, ExitPlanMode,
  EnterWorktree, ExitWorktree,
  ListMcpResourcesTool, AskUserQuestion
]

per_installed_mcp = [                       # only if the MCP was set up
  mcp__context-lens,
  mcp__statement-mcp,
  mcp__git,
  mcp__github-mcp-server,
  mcp__serena,
  mcp__scheduled-tasks,
  mcp__mcp-registry
]

conditional = [
  mcp__hopper                               # only if hopper was installed
]

project_scope = [                           # always allowed (so project-level
  mcp__onshape,                             # MCPs don't prompt every call)
  mcp__rhino,                               # but NOT configured globally —
  mcp__CLIDE,                               # configured in project .mcp.json
  mcp__Claude_Preview
]
```

The setup skill presents the proposed allow list and flags anything unexpected for user confirmation.

### hooks

Constructed from deployed scripts. Each hook entry references a symlink in `~/.claude/scripts/`. Conditional hooks:

| Hook                            | Condition              |
| ------------------------------- | ---------------------- |
| `enforce-tool-bans.sh`          | context-lens installed |
| `swift-typecheck.sh`            | macOS with Xcode       |
| `context-lens/track-session.sh` | context-lens installed |
| All others                      | Always                 |

### model and effortLevel

User preferences. Preserve existing values. If not set, ask.

## ~/.claude.json MCP Declarations

Platform-aware templating:

```
ONNXRUNTIME_SHARED_LIBRARY_PATH:
  macOS ARM   → /opt/homebrew/lib/libonnxruntime.dylib
  macOS Intel → /usr/local/lib/libonnxruntime.dylib
  Linux       → /usr/lib/libonnxruntime.so (or detected)

STRONGAI_EMBED_MODEL_DIR:
  All         → ~/.strongai/models/arctic-embed-m-v2

statement-mcp binary:
  All         → ~/.claude/mcp-servers/statement-go/statement-mcp

context-lens:
  All         → node ~/.claude/mcp-servers/context/dist/index.js

serena:
  All         → <repo>/serena/.venv/bin/serena-mcp-server

hopper (macOS only):
  macOS       → <repo>/hopper-mcp/.venv/bin/hopper-mcp
  Others      → omitted entirely

git:
  All         → uvx mcp-server-git

github-mcp-server:
  All         → docker run ... ghcr.io/github/github-mcp-server
```

## Conditional Components

| MCP               | Platform | Software guard              | Skip message                                             |
| ----------------- | -------- | --------------------------- | -------------------------------------------------------- |
| context-lens      | All      | Node.js                     | "Install Node.js and re-run setup"                       |
| statement-mcp     | All      | Go, PostgreSQL, onnxruntime | Per-dep skip messages                                    |
| git               | All      | Python + uvx                | "Install uv and re-run setup"                            |
| github-mcp-server | All      | Docker                      | "Install Docker and re-run setup"                        |
| serena            | All      | Python 3.11 + uv            | "Install Python 3.11 and re-run setup"                   |
| hopper            | macOS    | Hopper app in /Applications | "Run setup again after installing Hopper to enable this" |

## Prerequisites (completed)

1. ✓ **`mcp/context` submodule** — `StrongAI/claude-mcp-context` created, source from context-lens committed, submodule at `mcp/context/`
2. ✓ **`scripts/` submodule expanded** — 16 hook scripts moved into `StrongAI/claude-scripts`, originals replaced with symlinks in `~/.claude/scripts/`
