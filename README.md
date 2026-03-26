# claude-minions

**Stripe-style AI agent pipeline for any codebase.** One script. Fully automated. No framework needed.

Stripe ships 1,300+ PRs/week with zero human-written code using a pattern called **blueprints**: a state machine that interleaves deterministic steps (lint, test, git) with agentic steps (plan, implement, fix). This script brings that pattern to any project using Claude Code.

```
[Deterministic] Create branch
[Agentic]       Claude implements the task
[Deterministic] Type check / compile
[Agentic]       If broken → Claude fixes (ONE try)
[Deterministic] If still broken → skip, move on
[Deterministic] Commit → merge to main
[Deterministic] Next task
```

The LLM only does what requires intelligence. Everything mechanical is bash.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/claude-minions.git
cp claude-minions/minions.sh your-project/
cp claude-minions/minions.yaml.example your-project/minions.yaml

# 2. Authenticate Claude Code (one time)
claude /login

# 3. Define your tasks
edit minions.yaml

# 4. Run
cd your-project
./minions.sh
```

Walk away. Come back to a log of what passed and what failed.

## How It Works

```
you run ./minions.sh
    │
    ▼
┌─────────────────────────────────────────┐
│         DETERMINISTIC SHELL (bash)       │
│                                          │
│  for each task in minions.yaml:          │
│    ├── git checkout -b minion/task-name  │
│    │                                     │
│    ├── [AGENTIC] claude -p "do the task" │
│    │   └── reads code, writes code,      │
│    │       runs commands (up to 40 turns)│
│    │                                     │
│    ├── [DETERMINISTIC] verify            │
│    │   ├── TypeScript: npx tsc --noEmit  │
│    │   ├── Elixir: mix compile           │
│    │   ├── Rust: cargo check             │
│    │   └── Go: go build ./...            │
│    │                                     │
│    ├── if verify fails:                  │
│    │   ├── [AGENTIC] claude -p "fix it"  │
│    │   │   (ONE chance)                  │
│    │   ├── [DETERMINISTIC] verify again  │
│    │   └── if still fails → SKIP task    │
│    │                                     │
│    ├── git add -A && git commit          │
│    ├── git checkout main && git merge    │
│    └── → next task                       │
│                                          │
│  print report: passed / failed / skipped │
└─────────────────────────────────────────┘
```

## Config: minions.yaml

```yaml
tasks:
  - name: "Add user authentication"
    prompt: |
      Add JWT-based authentication to the API.
      Use bcrypt for password hashing.
      Add login and register endpoints.
      Add middleware that validates tokens.
      Add tests for all auth flows.

  - name: "Fix N+1 query in dashboard"
    prompt: |
      The /dashboard endpoint makes N+1 database queries.
      Use eager loading / joins to fix it.
      Add a test that asserts query count.

  - name: "Add rate limiting"
    prompt: |
      Add rate limiting to all public endpoints.
      100 requests per minute per IP.
      Return 429 with Retry-After header.
```

Each task gets its own git branch, its own agent session, and its own commit. Tasks run sequentially so they build on each other.

## Ad-Hoc Tasks

Don't need a yaml file — run a single task directly:

```bash
./minions.sh --task "Fix the login bug — users get 401 after OAuth redirect"
```

## Options

```
./minions.sh                          # Run all tasks from minions.yaml
./minions.sh --task "Fix auth bug"    # Run a single task
./minions.sh --dry-run                # Show tasks without executing
./minions.sh --config tasks.yaml      # Custom config file
./minions.sh --max-turns 60           # More agent turns per task (default: 40)
```

## Environment Variables

```bash
MINIONS_CONFIG=tasks.yaml       # Config file path (default: minions.yaml)
MINIONS_LOG_DIR=.minions/logs   # Log directory (default: .minions/logs)
MINIONS_MAX_RETRIES=1           # Fix attempts before skipping (default: 1)
MINIONS_MAX_TURNS=40            # Agent turns per task (default: 40)
MINIONS_FIX_TURNS=15            # Agent turns for fix attempts (default: 15)
MINIONS_MAIN_BRANCH=main        # Branch to merge into (default: main)
```

## Auto-Detection

The script auto-detects your project type and uses the right verify command:

| Project | Detected By | Verify Command |
|---------|-------------|---------------|
| TypeScript/Node | `tsconfig.json` | `npx tsc --noEmit` |
| Elixir | `mix.exs` | `mix compile --warnings-as-errors` |
| Rust | `Cargo.toml` | `cargo check` |
| Go | `go.mod` | `go build ./...` |
| Python | `pyproject.toml` | `python -m py_compile` |

## Context Files

The script automatically reads these files (if they exist) and includes them as context for every task:

- `CLAUDE.md` — Project-specific instructions for Claude
- `README.md` — Project overview
- `ARCHITECTURE.md` — System design
- `CONTRIBUTING.md` — Code conventions

Write a `CLAUDE.md` in your repo root to give the agent project-specific context. This is the single highest-leverage thing you can do for quality.

## The Stripe Pattern

This script implements the same pattern Stripe uses for their Minions system (1,300+ PRs/week):

1. **Deterministic nodes** handle everything mechanical: git, lint, test, format, commit, merge. No LLM involved. Reliable by construction.

2. **Agentic nodes** handle everything creative: understanding the task, reading code, planning changes, writing implementation, fixing errors. This is where the LLM adds value.

3. **Max 1 retry then escalate.** LLMs show diminishing returns on retries. If the first fix doesn't work, the task is skipped and logged for human review.

4. **No shared state between tasks.** Each task gets a clean branch. The only state that carries forward is the merged code on main.

The key insight from Stripe: **the framework matters less than the deterministic shell.** Stripe built theirs on Goose. You can build yours with a 200-line bash script. What matters is that mechanical steps are never delegated to an LLM.

## Requirements

- **Claude Code CLI** — Install from [claude.ai/code](https://claude.ai/code), authenticate with `claude /login`
- **git** — Initialized repo with a main branch
- **Your project's toolchain** — npm, mix, cargo, go, etc.

## Logs

Every run creates timestamped logs in `.minions/logs/`:

```
.minions/logs/
├── run-20260326-165452.log          # Master log for the full run
├── fix-auth-bug.log                 # Per-task log
├── add-rate-limiting.log            # Per-task log
└── improve-error-handling.log       # Per-task log
```

## FAQ

**Why not parallel agents?**
Sequential is simpler and more reliable. Each task can build on the previous task's merged code. Parallel agents risk merge conflicts and require complex coordination. Stripe uses isolated devboxes for parallelism — that's an infrastructure investment most teams don't need.

**Why not use CrewAI / LangChain / AutoGen?**
You don't need a framework. The deterministic shell IS the orchestrator. Adding a framework adds complexity without adding value for this pattern. Stripe's Minions are built on a Goose fork + bash scripts, not an agent framework.

**Why max 1 retry?**
LLMs show diminishing returns on retries. If the agent can't fix it in one try, a second try rarely helps. Better to skip and let a human look at the logged error.

**Can I use this with OpenAI / Gemini / other models?**
This script uses `claude -p` (Claude Code CLI). To use other models, replace the `claude -p` calls with your preferred CLI tool (e.g., `codex` for OpenAI Codex, `gemini` for Google Gemini CLI).

## License

MIT — do whatever you want with it.

## Credits

Inspired by [Stripe's Minions architecture](https://blog.bytebytego.com/p/how-stripes-minions-ship-1300-prs) and the blueprint pattern: deterministic nodes + agentic nodes = reliable AI-assisted development.
