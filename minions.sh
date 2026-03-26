#!/bin/bash
# ┌─────────────────────────────────────────────────────────────────┐
# │  claude-minions — Stripe-style AI agent pipeline for any repo  │
# │                                                                 │
# │  Deterministic shell wrapping agentic execution.                │
# │  The LLM only does what requires intelligence.                  │
# │  Everything mechanical is bash.                                 │
# │                                                                 │
# │  [Deterministic] Branch → [Agentic] Build → [Deterministic]    │
# │  Verify → [Agentic] Fix (1 try) → [Deterministic] Commit →     │
# │  Merge → Next task                                              │
# └─────────────────────────────────────────────────────────────────┘
#
# Usage:
#   ./minions.sh                          # Run all tasks from minions.yaml
#   ./minions.sh --task "Fix auth bug"    # Run a single ad-hoc task
#   ./minions.sh --dry-run                # Show what would run without executing
#
# Requirements:
#   - claude (Claude Code CLI, authenticated via `claude /login`)
#   - git (initialized repo)
#   - Your project's build/test tools (npm, mix, cargo, etc.)
#
# Config: minions.yaml (see README for format)
#
set -uo pipefail

VERSION="1.0.0"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ─── Config defaults ──────────────────────────────────────────────────
CONFIG_FILE="${MINIONS_CONFIG:-$PROJECT_DIR/minions.yaml}"
LOG_DIR="${MINIONS_LOG_DIR:-$PROJECT_DIR/.minions/logs}"
MAX_RETRIES="${MINIONS_MAX_RETRIES:-1}"
MAX_TURNS="${MINIONS_MAX_TURNS:-40}"
FIX_TURNS="${MINIONS_FIX_TURNS:-15}"
MAIN_BRANCH="${MINIONS_MAIN_BRANCH:-main}"
DRY_RUN=false
SINGLE_TASK=""

# ─── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)    DRY_RUN=true; shift ;;
    --task)       SINGLE_TASK="$2"; shift 2 ;;
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --max-turns)  MAX_TURNS="$2"; shift 2 ;;
    --help|-h)
      echo "claude-minions v$VERSION — Stripe-style AI agent pipeline"
      echo ""
      echo "Usage: ./minions.sh [options]"
      echo ""
      echo "Options:"
      echo "  --task \"desc\"    Run a single ad-hoc task"
      echo "  --dry-run        Show tasks without executing"
      echo "  --config FILE    Use custom config (default: minions.yaml)"
      echo "  --max-turns N    Max agent turns per task (default: 40)"
      echo "  --help           Show this help"
      echo ""
      echo "Config: minions.yaml (see README)"
      exit 0
      ;;
    *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"
MASTER_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"

# ─── Counters ─────────────────────────────────────────────────────────
PASSED=0
FAILED=0
SKIPPED=0
TOTAL_START=$(date +%s)

# ─── Helpers ──────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $1" | tee -a "$MASTER_LOG"; }
det()  { log "■ DET   $1"; }
agt()  { log "◆ AGENT $1"; }
pass() { log "✓ PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { log "✗ FAIL  $1"; FAILED=$((FAILED + 1)); }

slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | cut -c1-40
}

# ─── Detect project verify command ────────────────────────────────────
detect_verify_cmd() {
  if [[ -f "package.json" ]]; then
    # Node/TypeScript project
    if grep -q '"lint"' package.json 2>/dev/null; then
      echo "npx tsc --noEmit"
    elif [[ -f "tsconfig.json" ]]; then
      echo "npx tsc --noEmit"
    else
      echo "true"  # no type checker
    fi
  elif [[ -f "mix.exs" ]]; then
    echo "mix compile --warnings-as-errors"
  elif [[ -f "Cargo.toml" ]]; then
    echo "cargo check"
  elif [[ -f "go.mod" ]]; then
    echo "go build ./..."
  elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
    echo "python -m py_compile"
  else
    echo "true"  # no verify command found
  fi
}

detect_test_cmd() {
  if [[ -f "package.json" ]]; then
    if grep -q '"test"' package.json 2>/dev/null; then
      echo "npm test"
    elif [[ -f "vitest.config.ts" ]] || [[ -f "vitest.config.js" ]]; then
      echo "npx vitest run"
    elif ls src/**/*.test.ts 2>/dev/null | head -1 > /dev/null; then
      echo "npx vitest run"
    else
      echo "true"
    fi
  elif [[ -f "mix.exs" ]]; then
    echo "mix test"
  elif [[ -f "Cargo.toml" ]]; then
    echo "cargo test"
  elif [[ -f "go.mod" ]]; then
    echo "go test ./..."
  elif [[ -f "pyproject.toml" ]]; then
    echo "pytest"
  else
    echo "true"
  fi
}

VERIFY_CMD=$(detect_verify_cmd)
TEST_CMD=$(detect_test_cmd)

# ─── Read context files ───────────────────────────────────────────────
build_context() {
  local CONTEXT=""
  # Auto-detect common context files
  for f in CLAUDE.md README.md ARCHITECTURE.md CONTRIBUTING.md; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
      CONTEXT="$CONTEXT
Read $PROJECT_DIR/$f for project context."
    fi
  done
  echo "$CONTEXT"
}

PROJECT_CONTEXT=$(build_context)

# ─── Core: run one task ───────────────────────────────────────────────
run_task() {
  local TASK_NAME="$1"
  local PROMPT="$2"
  local SLUG=$(slug "$TASK_NAME")
  local BRANCH="minion/$SLUG"
  local TASK_LOG="$LOG_DIR/$SLUG.log"
  local TASK_START=$(date +%s)

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  TASK: $TASK_NAME"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [DRY RUN] Would execute this task"
    return 0
  fi

  # ── [DETERMINISTIC] Clean state ──
  det "Checking for uncommitted changes"
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    det "Stashing uncommitted changes"
    git stash push -m "minions-auto-stash-$SLUG" 2>&1 | tee -a "$TASK_LOG"
  fi

  # ── [DETERMINISTIC] Branch ──
  det "Creating branch: $BRANCH"
  git checkout "$MAIN_BRANCH" 2>&1 | tee -a "$TASK_LOG"
  git pull origin "$MAIN_BRANCH" 2>&1 | tee -a "$TASK_LOG" || true

  # Delete existing branch if re-running
  git branch -D "$BRANCH" 2>/dev/null || true
  git checkout -b "$BRANCH" 2>&1 | tee -a "$TASK_LOG"

  # ── [AGENTIC] Implement ──
  agt "Agent working on: $TASK_NAME"
  claude -p "$PROMPT
$PROJECT_CONTEXT

RULES:
- You are working in $PROJECT_DIR
- Read existing code before modifying
- Follow existing patterns and conventions
- Do NOT modify files outside the scope of this task
- Do NOT refactor unrelated code" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
    2>&1 | tee -a "$TASK_LOG"

  if [[ $? -ne 0 ]]; then
    fail "$TASK_NAME (agent error)"
    git checkout "$MAIN_BRANCH" 2>&1
    git branch -D "$BRANCH" 2>&1 || true
    return 1
  fi

  # ── [DETERMINISTIC] Verify ──
  det "Verifying: $VERIFY_CMD"
  if ! eval "$VERIFY_CMD" 2>&1 | tee /tmp/verify-$SLUG.log; then
    VERIFY_ERRORS=$(cat /tmp/verify-$SLUG.log | tail -30)
    local RETRY=0

    while [[ $RETRY -lt $MAX_RETRIES ]]; do
      RETRY=$((RETRY + 1))
      agt "Fixing errors (attempt $RETRY/$MAX_RETRIES)"

      claude -p "Build/compile failed. Fix ONLY the errors below. Do not rewrite working code.

Errors:
$VERIFY_ERRORS" \
        --max-turns "$FIX_TURNS" \
        --allowedTools "Read,Edit,Bash,Grep" \
        2>&1 | tee -a "$TASK_LOG"

      det "Re-verifying"
      if eval "$VERIFY_CMD" 2>&1 | tee /tmp/verify-$SLUG.log; then
        det "Verify passed after fix"
        break
      fi
    done

    if ! eval "$VERIFY_CMD" 2>/dev/null; then
      fail "$TASK_NAME (verify failed after $MAX_RETRIES fix attempts)"
      git checkout "$MAIN_BRANCH" 2>&1
      git branch -D "$BRANCH" 2>&1 || true
      return 1
    fi
  fi

  # ── [DETERMINISTIC] Check for changes ──
  if git diff --quiet && git diff --cached --quiet; then
    log "  No changes made — skipping"
    SKIPPED=$((SKIPPED + 1))
    git checkout "$MAIN_BRANCH" 2>&1
    git branch -D "$BRANCH" 2>&1 || true
    return 0
  fi

  # ── [DETERMINISTIC] Commit ──
  det "Committing"
  git add -A
  git commit -m "feat: $TASK_NAME

Built by claude-minions v$VERSION (Stripe blueprint pattern)" 2>&1 | tee -a "$TASK_LOG"

  # ── [DETERMINISTIC] Merge to main ──
  det "Merging to $MAIN_BRANCH"
  git checkout "$MAIN_BRANCH" 2>&1
  git merge "$BRANCH" --no-edit 2>&1 | tee -a "$TASK_LOG"

  if [[ $? -ne 0 ]]; then
    fail "$TASK_NAME (merge conflict)"
    git merge --abort 2>&1 || true
    return 1
  fi

  git branch -d "$BRANCH" 2>&1

  local TASK_END=$(date +%s)
  local TASK_DURATION=$(( TASK_END - TASK_START ))
  pass "$TASK_NAME (${TASK_DURATION}s)"
  return 0
}

# ─── Parse minions.yaml ──────────────────────────────────────────────
parse_yaml_tasks() {
  # Simple YAML parser for tasks list
  # Format:
  #   tasks:
  #     - name: "Task name"
  #       prompt: "What to do"
  #     - name: "Another task"
  #       prompt: "What to do"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "No config file found at $CONFIG_FILE" >&2
    echo "Create minions.yaml or use --task for ad-hoc tasks" >&2
    return 1
  fi

  local IN_TASK=false
  local CURRENT_NAME=""
  local CURRENT_PROMPT=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Detect task start
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
      # Save previous task if exists
      if [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]]; then
        run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
      fi
      CURRENT_NAME="${BASH_REMATCH[1]}"
      CURRENT_NAME="${CURRENT_NAME#\"}" # strip quotes
      CURRENT_NAME="${CURRENT_NAME%\"}"
      CURRENT_PROMPT=""
      IN_TASK=true
    elif [[ "$IN_TASK" == "true" && "$line" =~ ^[[:space:]]*prompt:[[:space:]]*(.*) ]]; then
      CURRENT_PROMPT="${BASH_REMATCH[1]}"
      CURRENT_PROMPT="${CURRENT_PROMPT#\"}"
      CURRENT_PROMPT="${CURRENT_PROMPT%\"}"
    elif [[ "$IN_TASK" == "true" && "$line" =~ ^[[:space:]]*prompt:[[:space:]]*\| ]]; then
      # Multi-line prompt (YAML block scalar)
      CURRENT_PROMPT=""
      while IFS= read -r pline; do
        # Stop at next task or end of indent
        if [[ "$pline" =~ ^[[:space:]]*-[[:space:]]*name: ]] || [[ "$pline" =~ ^[^[:space:]] ]]; then
          # Push back this line — it's the start of next task
          # Save current task
          if [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]]; then
            run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
          fi
          CURRENT_NAME=""
          CURRENT_PROMPT=""
          # Re-parse this line
          if [[ "$pline" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
            CURRENT_NAME="${BASH_REMATCH[1]}"
            CURRENT_NAME="${CURRENT_NAME#\"}"
            CURRENT_NAME="${CURRENT_NAME%\"}"
            IN_TASK=true
          fi
          break
        fi
        CURRENT_PROMPT="$CURRENT_PROMPT
$pline"
      done
    fi
  done < "$CONFIG_FILE"

  # Don't forget the last task
  if [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]]; then
    run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════"
log "  claude-minions v$VERSION"
log "  Stripe Blueprint Pattern for Claude Code"
log "  Started: $(date)"
log "  Project: $PROJECT_DIR"
log "  Verify:  $VERIFY_CMD"
log "  Test:    $TEST_CMD"
log "  Branch:  $MAIN_BRANCH"
log "═══════════════════════════════════════════════"

# Check claude is authenticated
if ! claude -p "echo ok" --max-turns 1 --bare 2>/dev/null | grep -q "ok"; then
  log "ERROR: claude -p is not authenticated. Run: claude /login"
  exit 1
fi
det "Claude authenticated ✓"

if [[ -n "$SINGLE_TASK" ]]; then
  # Ad-hoc single task
  run_task "$SINGLE_TASK" "$SINGLE_TASK"
else
  # Run all tasks from config
  parse_yaml_tasks
fi

# ═══════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════

TOTAL_END=$(date +%s)
TOTAL_DURATION=$(( TOTAL_END - TOTAL_START ))
MINUTES=$(( TOTAL_DURATION / 60 ))
SECONDS=$(( TOTAL_DURATION % 60 ))

log ""
log "═══════════════════════════════════════════════"
log "  claude-minions — COMPLETE"
log "  Passed:   $PASSED"
log "  Failed:   $FAILED"
log "  Skipped:  $SKIPPED"
log "  Duration: ${MINUTES}m ${SECONDS}s"
log "  Log:      $MASTER_LOG"
log "═══════════════════════════════════════════════"

[[ $FAILED -gt 0 ]] && exit 1
exit 0
