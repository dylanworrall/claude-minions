# claude-minions

**Autonomous spec-driven development.** Point it at a spec. It builds until the spec is satisfied.

Stripe ships 1,300+ PRs/week using **blueprints**: deterministic steps (lint, test, git) interleaved with agentic steps (plan, implement, fix). This script brings that pattern to any project — plus a **convergence loop** that keeps iterating until your spec is fully implemented.

```
┌─────────────────────────────────────────────────────┐
│              THE CONVERGENCE LOOP                    │
│                                                      │
│  [AGENTIC]       Read spec + codebase → find gaps    │
│  [AGENTIC]       Generate tasks to close gaps        │
│  for each task:                                      │
│    [DETERMINISTIC] Create branch                     │
│    [AGENTIC]       Implement                         │
│    [DETERMINISTIC] Compile / type check              │
│    [AGENTIC]       Fix if broken (ONE try)           │
│    [DETERMINISTIC] Commit → merge                    │
│  [AGENTIC]       Verify: does codebase match spec?   │
│  [DETERMINISTIC]  If gaps remain → LOOP              │
│  [DETERMINISTIC]  If spec satisfied → DONE           │
└─────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Get it
git clone https://github.com/dylanworrall/claude-minions.git
cp claude-minions/minions.sh your-project/
chmod +x your-project/minions.sh

# 2. Authenticate (one time)
claude /login

# 3. Point it at your spec
cat > your-project/minions.config.yaml << 'EOF'
spec:
  - docs/SPEC.md
  - docs/ARCHITECTURE.md
context:
  - CLAUDE.md
max_iterations: 10
EOF

# 4. Let it rip
cd your-project
./minions.sh
```

Walk away. Come back to a production codebase.

## Three Modes

### Spec-Driven (the main event)

```bash
./minions.sh
```

Reads `minions.config.yaml`, analyzes your spec vs codebase, generates tasks, builds, verifies, loops until done. This is the Stripe Minions pattern.

### Task-Driven (fixed task list)

```bash
./minions.sh --tasks minions.yaml
```

Runs a predefined list of tasks. No analysis, no loop. Good for known work.

```yaml
# minions.yaml
tasks:
  - name: "Add authentication"
    prompt: |
      Add JWT auth to the API. Use bcrypt for passwords.
      Add login/register endpoints. Add auth middleware.

  - name: "Add rate limiting"
    prompt: |
      Add rate limiting to all public endpoints.
      100 req/min per IP. Return 429 with Retry-After.
```

### Ad-Hoc (single task)

```bash
./minions.sh --task "Fix the login bug — users get 401 after OAuth redirect"
```

One task, one branch, one commit. Quick fix.

## Config: minions.config.yaml

```yaml
# The spec: what the project should implement
spec:
  - ~/docs/master-plan.md        # Your main spec
  - ~/docs/api-spec.md           # API requirements
  - ~/docs/data-model.md         # Database schema

# Additional context (not requirements)
context:
  - CLAUDE.md                    # Project conventions
  - ARCHITECTURE.md              # System design

# Commands (auto-detected if not set)
verify: "npx tsc --noEmit"
test: "npx vitest run"

# Settings
main_branch: main
max_iterations: 10               # Prevent infinite loops
```

### Spec Files

The spec files are the **source of truth**. The minions will:
1. Read every spec file
2. Compare requirements to the actual codebase
3. Generate tasks for anything missing or broken
4. Build until everything in the spec exists and works

Write your spec files like you're describing the finished product to an engineer. Be specific: file paths, function signatures, expected behavior, data models.

## How the Convergence Loop Works

```
Iteration 1:
  Analyze: "Spec says auth, API, dashboard. Nothing exists."
  Tasks:   [Setup project, Add auth, Build API, Build dashboard]
  Execute: 3 pass, 1 fails (dashboard had type errors)
  Verify:  "75% coverage — dashboard incomplete"

Iteration 2:
  Analyze: "Auth and API exist. Dashboard partially built."
  Tasks:   [Finish dashboard, Add missing API endpoints]
  Execute: 2 pass
  Verify:  "95% coverage — missing error handling"

Iteration 3:
  Analyze: "Almost there. Error handling missing in 3 files."
  Tasks:   [Add error handling]
  Execute: 1 pass
  Verify:  "100% — DONE"
```

Each iteration builds on the previous. Failed tasks get retried with different approaches. The loop stops when the spec is satisfied or max iterations is hit.

## State Management

Everything is tracked in `.minions/`:

```
.minions/
├── state/
│   ├── analysis-iter1.txt       # What the analyzer found
│   ├── tasks-iter1.json         # Generated task list
│   ├── results-iter1.txt        # What passed/failed
│   ├── verify-iter1.txt         # Spec coverage check
│   ├── analysis-iter2.txt       # Re-analysis after iteration 1
│   └── ...
└── logs/
    ├── run-20260326-170000.log  # Master log
    ├── add-auth-iter1.log       # Per-task logs
    └── ...
```

Previous iteration results feed into the next analysis — the minions learn from failures and don't repeat completed work.

## Auto-Detection

| Project | Detected By | Verify Command |
|---------|-------------|---------------|
| TypeScript | `tsconfig.json` | `npx tsc --noEmit` |
| Elixir | `mix.exs` | `mix compile --warnings-as-errors` |
| Rust | `Cargo.toml` | `cargo check` |
| Go | `go.mod` | `go build ./...` |
| Python | `pyproject.toml` | `python -m py_compile` |

## Options

```
./minions.sh                          # Spec-driven convergence loop
./minions.sh --tasks minions.yaml     # Fixed task list
./minions.sh --task "Fix bug"         # Single ad-hoc task
./minions.sh --verify-only            # Check spec coverage without building
./minions.sh --dry-run                # Show tasks without executing
./minions.sh --max-iter 5             # Limit iterations
./minions.sh --config custom.yaml     # Custom config file
./minions.sh --max-turns 60           # More agent turns per task
```

## Environment Variables

```bash
MINIONS_CONFIG=minions.config.yaml  # Config file
MINIONS_LOG_DIR=.minions/logs       # Logs
MINIONS_STATE_DIR=.minions/state    # State (analysis, tasks, results)
MINIONS_MAX_RETRIES=1               # Fix attempts per task
MINIONS_MAX_TURNS=40                # Agent turns per task
MINIONS_FIX_TURNS=15                # Agent turns for fixes
MINIONS_ANALYZE_TURNS=20            # Agent turns for analysis
MINIONS_MAX_ITERATIONS=10           # Convergence loop limit
MINIONS_MAIN_BRANCH=main            # Target branch
```

## The Stripe Pattern

This implements three key insights from Stripe's Minions (1,300+ PRs/week):

1. **Deterministic shell wraps agentic execution.** Git, lint, test, commit — all bash. The LLM only does what requires intelligence.

2. **Max 1 retry then move on.** LLMs show diminishing returns. If the fix doesn't work, skip it and let the next iteration try a different approach.

3. **No shared state between tasks.** Each task gets a clean branch. The only state that carries forward is merged code on main.

The addition over Stripe's pattern: **the convergence loop.** Stripe's Minions work from a ticket queue (Linear/Jira). Claude-minions works from a spec file — it figures out what tickets to create, then executes them, then checks if more are needed.

## Requirements

- **Claude Code CLI** — [claude.ai/code](https://claude.ai/code), authenticated with `claude /login`
- **git** — Initialized repo with commits on main
- **Your toolchain** — npm, mix, cargo, go, etc.

## License

MIT
