#!/bin/bash
# ┌─────────────────────────────────────────────────────────────────┐
# │  claude-minions v4 — Autonomous spec-driven development        │
# │                                                                 │
# │  Stripe blueprint pattern + convergence loop + context scoping  │
# │  + task categories + parallel worktrees + escalating retries    │
# │                                                                 │
# │  v4 improvements:                                               │
# │  1. Per-node context scoping (implement/fix/verify/qa agents)   │
# │  2. Task category templates (feature/bugfix/refactor/test)      │
# │  3. Escalating retries (3 attempts, rethink on retry 2+)       │
# │  4. Parallel execution via git worktrees                        │
# │  5. Blueprint definitions in config                             │
# │  6. --watch flag for live observability                         │
# └─────────────────────────────────────────────────────────────────┘
#
# Modes:
#   ./minions.sh                        # Spec/goal-driven convergence loop
#   ./minions.sh --tasks minions.yaml   # Task-driven: run a fixed task list
#   ./minions.sh --task "Fix auth bug"  # Ad-hoc: run a single task
#   ./minions.sh --verify-only          # Just check spec coverage
#   ./minions.sh --dry-run              # Show what would run
#   ./minions.sh --watch                # Live tail with colored output
#
set -uo pipefail

VERSION="4.1.0"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ─── Config defaults ──────────────────────────────────────────────────
CONFIG_FILE="${MINIONS_CONFIG:-$PROJECT_DIR/minions.config.yaml}"
TASKS_FILE=""
LOG_DIR="${MINIONS_LOG_DIR:-$PROJECT_DIR/.minions/logs}"
STATE_DIR="${MINIONS_STATE_DIR:-$PROJECT_DIR/.minions/state}"
MAX_RETRIES="${MINIONS_MAX_RETRIES:-3}"
MAX_TURNS="${MINIONS_MAX_TURNS:-40}"
FIX_TURNS="${MINIONS_FIX_TURNS:-15}"
ANALYZE_TURNS="${MINIONS_ANALYZE_TURNS:-20}"
MAIN_BRANCH="${MINIONS_MAIN_BRANCH:-main}"
MAX_ITERATIONS="${MINIONS_MAX_ITERATIONS:-10}"
PARALLEL="${MINIONS_PARALLEL:-1}"
DRY_RUN=false
VERIFY_ONLY=false
WATCH_MODE=false
SINGLE_TASK=""

# ─── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)      DRY_RUN=true; shift ;;
    --verify-only)  VERIFY_ONLY=true; shift ;;
    --watch)        WATCH_MODE=true; shift ;;
    --task)         SINGLE_TASK="$2"; shift 2 ;;
    --tasks)        TASKS_FILE="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --max-turns)    MAX_TURNS="$2"; shift 2 ;;
    --max-iter)     MAX_ITERATIONS="$2"; shift 2 ;;
    --parallel)     PARALLEL="$2"; shift 2 ;;
    --help|-h)
      echo "claude-minions v$VERSION — Autonomous spec-driven development"
      echo ""
      echo "Modes:"
      echo "  ./minions.sh                        Spec/goal-driven convergence loop"
      echo "  ./minions.sh --tasks minions.yaml   Fixed task list"
      echo "  ./minions.sh --task \"Fix bug\"        Single ad-hoc task"
      echo "  ./minions.sh --verify-only           Check spec coverage only"
      echo "  ./minions.sh --dry-run               Show plan without executing"
      echo "  ./minions.sh --watch                 Live colored log output"
      echo ""
      echo "Options:"
      echo "  --config FILE      Config file (default: minions.config.yaml)"
      echo "  --max-turns N      Agent turns per task (default: 40)"
      echo "  --max-iter N       Max convergence iterations (default: 10)"
      echo "  --parallel N       Parallel tasks via worktrees (default: 1)"
      echo "  --help             Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
MASTER_LOG="$LOG_DIR/run-$RUN_ID.log"

# ─── Watch mode ───────────────────────────────────────────────────────
if [[ "$WATCH_MODE" == "true" ]]; then
  LATEST=$(ls -t "$LOG_DIR"/run-*.log 2>/dev/null | head -1)
  if [[ -z "$LATEST" ]]; then
    echo "No log files found. Start a minions run first."
    exit 1
  fi
  echo "Watching: $LATEST"
  echo "Press Ctrl+C to stop."
  tail -f "$LATEST" | sed \
    -e 's/■ DET/\x1b[36m■ DET\x1b[0m/g' \
    -e 's/◆ AGENT/\x1b[33m◆ AGENT\x1b[0m/g' \
    -e 's/✓ PASS/\x1b[32m✓ PASS\x1b[0m/g' \
    -e 's/✗ FAIL/\x1b[31m✗ FAIL\x1b[0m/g' \
    -e 's/RATE LIMITED/\x1b[35mRATE LIMITED\x1b[0m/g' \
    -e 's/ITERATION/\x1b[1mITERATION\x1b[0m/g' \
    -e 's/━/\x1b[90m━\x1b[0m/g'
  exit 0
fi

# ─── Counters ─────────────────────────────────────────────────────────
PASSED=0
FAILED=0
SKIPPED=0
ITERATION=0
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

# Rate-limit-aware claude wrapper
claude_with_retry() {
  local OUTPUT_FILE=$(mktemp)
  local MAX_WAIT_ATTEMPTS=66  # 66 x 5min = 5.5hrs

  for ATTEMPT in $(seq 1 $MAX_WAIT_ATTEMPTS); do
    claude "$@" 2>&1 | tee "$OUTPUT_FILE"
    local EXIT_CODE=${PIPESTATUS[0]}

    if grep -qi "hit your limit\|rate limit\|resets.*am\|resets.*pm\|too many requests\|429" "$OUTPUT_FILE" 2>/dev/null; then
      local RESET_TIME=$(grep -oi "resets [0-9]*[ap]m\|resets [0-9]*:[0-9]*" "$OUTPUT_FILE" | head -1)
      det "RATE LIMITED${RESET_TIME:+ ($RESET_TIME)}. Waiting 5 minutes... (attempt $ATTEMPT/$MAX_WAIT_ATTEMPTS)"
      sleep 300
      det "Retrying after cooldown..."
      continue
    fi

    if grep -qi "not logged in" "$OUTPUT_FILE" 2>/dev/null; then
      det "AUTH ERROR: Not logged in. Run: claude /login"
      rm -f "$OUTPUT_FILE"
      return 1
    fi

    rm -f "$OUTPUT_FILE"
    return $EXIT_CODE
  done

  det "RATE LIMITED for 5.5 hours. Giving up."
  rm -f "$OUTPUT_FILE"
  return 1
}

# ─── Read config ──────────────────────────────────────────────────────
SPEC_FILES=""
CONTEXT_FILES=""
CUSTOM_VERIFY=""
CUSTOM_TEST=""
GOAL=""
MODE=""

if [[ -f "$CONFIG_FILE" ]]; then
  det "Reading config: $CONFIG_FILE"

  GOAL=$(awk '
    /^goal:/ {
      found=1
      sub(/^goal:[[:space:]]*\|?[[:space:]]*$/, "", $0)
      if ($0 != "") { print $0; found=0 }
      next
    }
    found && /^[a-zA-Z]/ { exit }
    found && /^[^ ]/ { exit }
    found { gsub(/^    /, ""); gsub(/^  /, ""); print }
  ' "$CONFIG_FILE" 2>/dev/null)
  GOAL=$(echo "$GOAL" | sed '/^$/d' | head -50)

  SPEC_FILES=$(grep -A100 '^spec:' "$CONFIG_FILE" 2>/dev/null | grep '^ *- ' | sed 's/^ *- //' | sed 's/"//g' | head -20)
  CONTEXT_FILES=$(grep -A100 '^context:' "$CONFIG_FILE" 2>/dev/null | grep '^ *- ' | sed 's/^ *- //' | sed 's/"//g' | head -20)
  CUSTOM_VERIFY=$(grep '^verify:' "$CONFIG_FILE" 2>/dev/null | sed 's/^verify: *//' | sed 's/"//g')
  CUSTOM_TEST=$(grep '^test:' "$CONFIG_FILE" 2>/dev/null | sed 's/^test: *//' | sed 's/"//g')

  local_max_iter=$(grep '^max_iterations:' "$CONFIG_FILE" 2>/dev/null | sed 's/^max_iterations: *//')
  [[ -n "$local_max_iter" ]] && MAX_ITERATIONS="$local_max_iter"
  local_main=$(grep '^main_branch:' "$CONFIG_FILE" 2>/dev/null | sed 's/^main_branch: *//' | sed 's/"//g')
  [[ -n "$local_main" ]] && MAIN_BRANCH="$local_main"
  local_parallel=$(grep '^parallel:' "$CONFIG_FILE" 2>/dev/null | sed 's/^parallel: *//')
  [[ -n "$local_parallel" ]] && PARALLEL="$local_parallel"
  local_retries=$(grep '^max_retries:' "$CONFIG_FILE" 2>/dev/null | sed 's/^max_retries: *//')
  [[ -n "$local_retries" ]] && MAX_RETRIES="$local_retries"
fi

# ─── Detect verify/test commands ──────────────────────────────────────
detect_verify_cmd() {
  if [[ -n "$CUSTOM_VERIFY" ]]; then echo "$CUSTOM_VERIFY"; return; fi
  if [[ -f "tsconfig.json" ]]; then echo "npx tsc --noEmit"
  elif [[ -f "mix.exs" ]]; then echo "mix compile --warnings-as-errors"
  elif [[ -f "Cargo.toml" ]]; then echo "cargo check"
  elif [[ -f "go.mod" ]]; then echo "go build ./..."
  elif [[ -f "pyproject.toml" ]]; then echo "python -m py_compile"
  else echo "true"; fi
}

detect_test_cmd() {
  if [[ -n "$CUSTOM_TEST" ]]; then echo "$CUSTOM_TEST"; return; fi
  if [[ -f "vitest.config.ts" ]] || [[ -f "vitest.config.js" ]]; then echo "npx vitest run"
  elif [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then echo "npm test"
  elif [[ -f "mix.exs" ]]; then echo "mix test"
  elif [[ -f "Cargo.toml" ]]; then echo "cargo test"
  elif [[ -f "go.mod" ]]; then echo "go test ./..."
  elif [[ -f "pyproject.toml" ]]; then echo "pytest"
  else echo "true"; fi
}

VERIFY_CMD=$(detect_verify_cmd)
TEST_CMD=$(detect_test_cmd)

# ─── Build context strings ────────────────────────────────────────────
build_context() {
  local CTX=""
  for f in CLAUDE.md README.md ARCHITECTURE.md; do
    [[ -f "$PROJECT_DIR/$f" ]] && CTX="$CTX
Read $PROJECT_DIR/$f for project context."
  done
  if [[ -n "$CONTEXT_FILES" ]]; then
    while IFS= read -r f; do
      # Expand ~ to $HOME
      f="${f/#\~/$HOME}"
      [[ -n "$f" ]] && [[ -f "$f" ]] && CTX="$CTX
Read $f for project context."
    done <<< "$CONTEXT_FILES"
  fi
  echo "$CTX"
}

build_spec_context() {
  local CTX=""
  if [[ -n "$SPEC_FILES" ]]; then
    while IFS= read -r f; do
      f="${f/#\~/$HOME}"
      [[ -n "$f" ]] && [[ -f "$f" ]] && CTX="$CTX
Read this SPEC file — the project must implement everything in it: $f"
    done <<< "$SPEC_FILES"
  fi
  echo "$CTX"
}

PROJECT_CONTEXT=$(build_context)
SPEC_CONTEXT=$(build_spec_context)

# ═══════════════════════════════════════════════════════════════════════
# IMPROVEMENT 2: Task Category Detection + Specialized Prompts
# ═══════════════════════════════════════════════════════════════════════
detect_task_category() {
  local TASK_NAME="$1"
  local TASK_PROMPT="$2"

  # First: extract explicit [category] tag from task name (set by analyzer)
  local EXPLICIT=$(echo "$TASK_NAME" | grep -oi '\[feature\]\|\[bugfix\]\|\[refactor\]\|\[test\]\|\[migration\]' | head -1 | tr -d '[]' | tr '[:upper:]' '[:lower:]')
  if [[ -n "$EXPLICIT" ]]; then
    echo "$EXPLICIT"
    return
  fi

  # Fallback: keyword detection for tasks without explicit tags
  local COMBINED="$TASK_NAME $TASK_PROMPT"
  if echo "$COMBINED" | grep -qi "fix\|bug\|broken\|error\|crash\|fail\|repair\|patch"; then
    echo "bugfix"
  elif echo "$COMBINED" | grep -qi "test\|spec\|coverage\|assert\|verify\|e2e\|unit test"; then
    echo "test"
  elif echo "$COMBINED" | grep -qi "refactor\|clean\|rename\|reorganize\|restructure\|simplif"; then
    echo "refactor"
  elif echo "$COMBINED" | grep -qi "migrat\|upgrade\|convert\|port\|switch"; then
    echo "migration"
  else
    echo "feature"
  fi
}

get_category_rules() {
  local CATEGORY="$1"
  case "$CATEGORY" in
    bugfix)
      echo "CATEGORY: BUG FIX
- Read the error/bug description carefully
- Find the root cause before changing code
- Make the MINIMUM change needed to fix the bug
- Add a regression test if possible
- Do NOT refactor surrounding code"
      ;;
    test)
      echo "CATEGORY: TEST
- Read existing test files first — mirror their patterns exactly
- Use the same test framework, assertion style, and file structure
- Test behavior, not implementation details
- Include edge cases and error paths
- Do NOT modify source code, only test files"
      ;;
    refactor)
      echo "CATEGORY: REFACTOR
- Do NOT change external behavior — only internal structure
- Run tests before AND after to verify nothing broke
- Make changes incrementally, not all at once
- Do NOT add new features or fix bugs during refactoring"
      ;;
    migration)
      echo "CATEGORY: MIGRATION
- Read both the old and new patterns thoroughly
- Migrate incrementally — don't rewrite everything at once
- Maintain backwards compatibility where possible
- Test each migrated component individually"
      ;;
    feature)
      echo "CATEGORY: NEW FEATURE
- Read the spec/goal to understand what to build
- Read existing code to understand patterns and conventions
- Build incrementally — get the core working first, then polish
- Write clean code with types and error handling"
      ;;
  esac
}

get_category_tools() {
  local CATEGORY="$1"
  case "$CATEGORY" in
    bugfix)   echo "Read,Edit,Bash,Grep,Glob" ;;
    test)     echo "Read,Write,Bash,Grep,Glob" ;;
    refactor) echo "Read,Edit,Grep,Glob,Bash" ;;
    *)        echo "Read,Write,Edit,Bash,Grep,Glob" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════
# IMPROVEMENT 1 + 3: Run task with context scoping + escalating retries
# ═══════════════════════════════════════════════════════════════════════
run_task() {
  local TASK_NAME="$1"
  local PROMPT="$2"
  local SLUG=$(slug "$TASK_NAME")
  local BRANCH="minion/$SLUG-iter$ITERATION"
  local TASK_LOG="$LOG_DIR/$SLUG-iter$ITERATION.log"
  local TASK_START=$(date +%s)
  local WORK_DIR="$PROJECT_DIR"

  # Detect task category
  local CATEGORY=$(detect_task_category "$TASK_NAME" "$PROMPT")
  local CATEGORY_RULES=$(get_category_rules "$CATEGORY")
  local CATEGORY_TOOLS=$(get_category_tools "$CATEGORY")

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  TASK: $TASK_NAME [$CATEGORY] (iteration $ITERATION)"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [DRY RUN] Would execute: $TASK_NAME [$CATEGORY]"
    return 0
  fi

  # ── [DETERMINISTIC] Clean state ──
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    det "Stashing uncommitted changes"
    git stash push -m "minions-$SLUG" 2>&1 | tee -a "$TASK_LOG" || true
  fi

  # ── [DETERMINISTIC] Branch ──
  det "Branch: $BRANCH"
  git checkout "$MAIN_BRANCH" 2>&1 | tee -a "$TASK_LOG"
  git pull origin "$MAIN_BRANCH" 2>&1 | tee -a "$TASK_LOG" || true
  git branch -D "$BRANCH" 2>/dev/null || true
  git checkout -b "$BRANCH" 2>&1 | tee -a "$TASK_LOG"

  # ── [AGENTIC] Implement (scoped context: spec + architecture + patterns) ──
  agt "Implementing: $TASK_NAME [$CATEGORY]"
  claude_with_retry -p "$PROMPT

$CATEGORY_RULES

$PROJECT_CONTEXT

RULES:
- Working directory: $WORK_DIR
- Read existing code before modifying
- Follow existing patterns
- Do NOT modify files outside this task's scope
- Verify your changes compile: run '$VERIFY_CMD'" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$CATEGORY_TOOLS" \
    2>&1 | tee -a "$TASK_LOG"

  if [[ $? -ne 0 ]]; then
    fail "$TASK_NAME (agent error)"
    git checkout "$MAIN_BRANCH" 2>&1
    git branch -D "$BRANCH" 2>&1 || true
    return 1
  fi

  # ── [DETERMINISTIC] Verify ──
  det "Verify: $VERIFY_CMD"
  local ALL_ERRORS=""
  if ! eval "$VERIFY_CMD" 2>&1 | tee /tmp/verify-$SLUG.log; then
    local RETRY=0
    ALL_ERRORS=$(tail -30 /tmp/verify-$SLUG.log)

    while [[ $RETRY -lt $MAX_RETRIES ]]; do
      RETRY=$((RETRY + 1))

      # IMPROVEMENT 3: Escalating context on retries
      local FIX_PROMPT=""
      if [[ $RETRY -le 1 ]]; then
        # First retry: just show the error
        FIX_PROMPT="Build/compile failed. Fix ONLY these errors:

$ALL_ERRORS"
      else
        # Retry 2+: rethink prompt with ALL previous errors
        FIX_PROMPT="Previous fix attempts have FAILED. Here are ALL the errors from every attempt:

$ALL_ERRORS

STOP and rethink. The previous approach was wrong. Try a fundamentally different approach:
- Maybe the type signature needs to change
- Maybe the import is wrong
- Maybe the file structure assumption is incorrect
- Read the surrounding code again before making changes"
      fi

      # IMPROVEMENT 1: Fix agent gets scoped context (only error + changed files)
      agt "Fix attempt $RETRY/$MAX_RETRIES (escalating)"
      claude_with_retry -p "$FIX_PROMPT" \
        --max-turns "$FIX_TURNS" \
        --allowedTools "Read,Edit,Bash,Grep" \
        2>&1 | tee -a "$TASK_LOG"

      if eval "$VERIFY_CMD" 2>&1 | tee /tmp/verify-$SLUG.log; then
        det "Verify passed after fix attempt $RETRY"
        break
      else
        # Accumulate errors for next retry
        ALL_ERRORS="$ALL_ERRORS

--- Fix attempt $RETRY failed ---
$(tail -30 /tmp/verify-$SLUG.log)"
      fi
    done

    if ! eval "$VERIFY_CMD" 2>/dev/null; then
      fail "$TASK_NAME (verify failed after $MAX_RETRIES attempts)"
      git checkout "$MAIN_BRANCH" 2>&1
      git branch -D "$BRANCH" 2>&1 || true
      return 1
    fi
  fi

  # ── [DETERMINISTIC] Commit + Merge ──
  if git diff --quiet && git diff --cached --quiet; then
    log "  No changes — skipping"
    SKIPPED=$((SKIPPED + 1))
    git checkout "$MAIN_BRANCH" 2>&1
    git branch -D "$BRANCH" 2>&1 || true
    return 0
  fi

  det "Commit + merge"
  git add -A
  git commit -m "feat: $TASK_NAME

Category: $CATEGORY
Built by claude-minions v$VERSION (iteration $ITERATION)" 2>&1 | tee -a "$TASK_LOG"

  git checkout "$MAIN_BRANCH" 2>&1
  if ! git merge "$BRANCH" --no-edit 2>&1 | tee -a "$TASK_LOG"; then
    fail "$TASK_NAME (merge conflict)"
    git merge --abort 2>&1 || true
    return 1
  fi
  git branch -d "$BRANCH" 2>&1

  local DURATION=$(( $(date +%s) - TASK_START ))
  pass "$TASK_NAME [$CATEGORY] (${DURATION}s)"
}

# ═══════════════════════════════════════════════════════════════════════
# IMPROVEMENT 4: Parallel execution via git worktrees
# ═══════════════════════════════════════════════════════════════════════
run_task_in_worktree() {
  local TASK_NAME="$1"
  local PROMPT="$2"
  local RESULTS_FILE="$3"  # passed from execute_tasks
  local SLUG=$(slug "$TASK_NAME")
  local WORKTREE_DIR=$(mktemp -d -t "minion-$SLUG-XXXXXX")
  local BRANCH="minion/$SLUG-iter$ITERATION"
  local TASK_LOG="$LOG_DIR/$SLUG-iter$ITERATION.log"
  local TASK_START=$(date +%s)

  local CATEGORY=$(detect_task_category "$TASK_NAME" "$PROMPT")
  local CATEGORY_RULES=$(get_category_rules "$CATEGORY")
  local CATEGORY_TOOLS=$(get_category_tools "$CATEGORY")

  log "  ┣ PARALLEL: $TASK_NAME [$CATEGORY] → $WORKTREE_DIR"

  # Create worktree
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" "$MAIN_BRANCH" 2>&1 | tee -a "$TASK_LOG" || {
    fail "$TASK_NAME (worktree creation failed)"
    echo "FAILED: $TASK_NAME (worktree creation failed)" >> "$RESULTS_FILE"
    return 1
  }

  # Run agent in worktree directory — CRITICAL: tell agent to cd first
  claude_with_retry -p "IMPORTANT: Before doing ANYTHING, run this command first:
cd $WORKTREE_DIR

All file paths in this task are relative to $WORKTREE_DIR. You MUST work in that directory.

---

$PROMPT

$CATEGORY_RULES

$PROJECT_CONTEXT

RULES:
- Working directory: $WORKTREE_DIR (you MUST cd there first)
- Read existing code before modifying
- Follow existing patterns
- Do NOT modify files outside this task's scope
- Verify changes compile: cd $WORKTREE_DIR && $VERIFY_CMD" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$CATEGORY_TOOLS" \
    2>&1 | tee -a "$TASK_LOG"

  # Verify in worktree
  if ! (cd "$WORKTREE_DIR" && eval "$VERIFY_CMD") 2>&1 | tee /tmp/verify-$SLUG.log; then
    fail "$TASK_NAME (verify failed in worktree)"
    echo "FAILED: $TASK_NAME (verify failed)" >> "$RESULTS_FILE"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    git branch -D "$BRANCH" 2>/dev/null || true
    return 1
  fi

  # Check for changes
  if (cd "$WORKTREE_DIR" && git diff --quiet && git diff --cached --quiet); then
    SKIPPED=$((SKIPPED + 1))
    echo "SKIPPED: $TASK_NAME (no changes)" >> "$RESULTS_FILE"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    git branch -D "$BRANCH" 2>/dev/null || true
    return 0
  fi

  # Commit in worktree
  (cd "$WORKTREE_DIR" && git add -A && git commit -m "feat: $TASK_NAME

Category: $CATEGORY
Built by claude-minions v$VERSION (parallel, iteration $ITERATION)") 2>&1 | tee -a "$TASK_LOG"

  # Clean up worktree (branch stays for merging)
  git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true

  local DURATION=$(( $(date +%s) - TASK_START ))
  pass "$TASK_NAME [$CATEGORY] (${DURATION}s, parallel)"
  echo "PASSED: $TASK_NAME" >> "$RESULTS_FILE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════
# ANALYZE: Read codebase, figure out what to do
# ═══════════════════════════════════════════════════════════════════════
analyze() {
  local ITERATION_NUM=$1
  local TASK_LIST_FILE="$STATE_DIR/tasks-iter$ITERATION_NUM.json"
  local PREV_RESULTS="$STATE_DIR/results-iter$((ITERATION_NUM - 1)).txt"

  det "Analyzing: iteration $ITERATION_NUM (mode: $MODE)"

  local PREV_CONTEXT=""
  if [[ -f "$PREV_RESULTS" ]]; then
    PREV_CONTEXT="
PREVIOUS ITERATION RESULTS (do NOT repeat completed tasks):
$(cat "$PREV_RESULTS")"
  fi

  local QA_CONTEXT=""
  local PREV_QA="$STATE_DIR/qa-iter$((ITERATION_NUM - 1)).txt"
  if [[ -f "$PREV_QA" ]]; then
    QA_CONTEXT="
QA TEST RESULTS FROM PREVIOUS ITERATION:
$(tail -50 "$PREV_QA")"
  fi

  local ANALYSIS_PROMPT=""

  if [[ "$MODE" == "goal" ]]; then
    ANALYSIS_PROMPT="You are an autonomous developer. Your job is to make this project achieve its goal.

THE GOAL:
$GOAL

$PROJECT_CONTEXT
$PREV_CONTEXT
$QA_CONTEXT

You have FULL AUTONOMY to decide what needs to happen.

APPROACH:
1. Read the codebase thoroughly
2. Think about the GOAL — what does 'done' look like?
3. Identify the HIGHEST IMPACT work
4. Generate tasks ordered by impact

For each task, include a CATEGORY tag: [feature], [bugfix], [refactor], [test], or [migration]

OUTPUT FORMAT (exactly this, parseable):
---TASKS---
TASK: [category] Short task name
PROMPT: [detailed instructions]
---
---END---

If the goal is ACHIEVED, output:
---TASKS---
---DONE---

Max 8 tasks. Focus on what MATTERS MOST."

  elif [[ $ITERATION_NUM -eq 1 ]]; then
    ANALYSIS_PROMPT="You are analyzing a codebase against its spec.

$SPEC_CONTEXT
$PROJECT_CONTEXT

ANALYZE: what does the spec require vs what exists?
Generate tasks to close gaps. Include [category] tags.

OUTPUT FORMAT:
---TASKS---
TASK: [category] Short name
PROMPT: [detailed instructions]
---
---END---

Max 10 tasks, ordered by dependency."
  else
    ANALYSIS_PROMPT="Re-analyzing after iteration. Some tasks completed, some failed.

$SPEC_CONTEXT
$PROJECT_CONTEXT
$PREV_CONTEXT
$QA_CONTEXT

Generate tasks ONLY for remaining gaps. Include [category] tags.

OUTPUT FORMAT:
---TASKS---
TASK: [category] Short name
PROMPT: [instructions]
---
---END---

If FULLY SATISFIED:
---TASKS---
---DONE---

Max 10 tasks. QA bugs are HIGH PRIORITY."
  fi

  agt "Analyzing codebase"
  claude_with_retry -p "$ANALYSIS_PROMPT" \
    --max-turns "$ANALYZE_TURNS" \
    --allowedTools "Read,Grep,Glob,Bash" \
    2>&1 | tee "$STATE_DIR/analysis-iter$ITERATION_NUM.txt"

  local ANALYSIS=$(cat "$STATE_DIR/analysis-iter$ITERATION_NUM.txt")

  if echo "$ANALYSIS" | grep -q "\-\-\-DONE\-\-\-"; then
    det "Spec satisfied — no more tasks needed"
    return 1
  fi

  echo "$ANALYSIS" | awk '
    /^TASK: / { task = substr($0, 7); next }
    /^PROMPT: / { prompt = substr($0, 9); next }
    /^---$/ { if (task != "" && prompt != "") print task "\t" prompt; task=""; prompt="" }
    /^---END---/ { if (task != "" && prompt != "") print task "\t" prompt }
    !/^TASK:|^PROMPT:|^---|^---END/ { if (prompt != "") prompt = prompt " " $0 }
  ' > "$TASK_LIST_FILE"

  local TASK_COUNT=$(wc -l < "$TASK_LIST_FILE" | tr -d ' ')
  det "Generated $TASK_COUNT tasks for iteration $ITERATION_NUM"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════
# VERIFY: Check if spec/goal is satisfied
# ═══════════════════════════════════════════════════════════════════════
verify_spec() {
  local ITERATION_NUM=$1
  local VERIFY_PROMPT=""

  if [[ "$MODE" == "goal" ]]; then
    agt "Verifying goal achievement"
    VERIFY_PROMPT="You are verifying whether a project achieves its goal.

THE GOAL:
$GOAL

$PROJECT_CONTEXT

Examine the project. Score:
- Functionality: does it do what the goal describes? (0-100)
- Quality: clean code, typed, error-handled? (0-100)
- Completeness: any half-built features? (0-100)

$(cat "$STATE_DIR/qa-iter$ITERATION_NUM.txt" 2>/dev/null | tail -30)

OUTPUT:
FUNCTIONALITY: [number]%
QUALITY: [number]%
COMPLETENESS: [number]%
REMAINING:
- [gap]
...
VERDICT: DONE | NEEDS_WORK"
  else
    agt "Verifying spec coverage"
    VERIFY_PROMPT="Verify codebase satisfies spec.

$SPEC_CONTEXT
$PROJECT_CONTEXT

$(cat "$STATE_DIR/qa-iter$ITERATION_NUM.txt" 2>/dev/null | tail -30)

OUTPUT:
COVERAGE: [number]%
REMAINING:
- [gap]
...
VERDICT: DONE | NEEDS_WORK"
  fi

  # Verify agent gets spec + full read access, no write, no bash
  claude_with_retry -p "$VERIFY_PROMPT" \
    --max-turns "$ANALYZE_TURNS" \
    --allowedTools "Read,Grep,Glob" \
    2>&1 | tee "$STATE_DIR/verify-iter$ITERATION_NUM.txt"

  grep -q "VERDICT: DONE" "$STATE_DIR/verify-iter$ITERATION_NUM.txt" && return 0
  return 1
}

# ═══════════════════════════════════════════════════════════════════════
# QA: Browser test the running app
# ═══════════════════════════════════════════════════════════════════════
qa_test() {
  local ITERATION_NUM=$1
  local QA_LOG="$STATE_DIR/qa-iter$ITERATION_NUM.txt"
  local QA_SCREENSHOTS="$STATE_DIR/screenshots-iter$ITERATION_NUM"
  mkdir -p "$QA_SCREENSHOTS"

  local B=""
  [[ -x "$HOME/.claude/skills/gstack/browse/dist/browse" ]] && B="$HOME/.claude/skills/gstack/browse/dist/browse"
  if [[ -z "$B" ]]; then
    det "No browse binary — skipping QA"
    return 0
  fi

  local START_CMD=""
  START_CMD=$(grep '^start:' "$CONFIG_FILE" 2>/dev/null | sed 's/^start: *//' | sed 's/"//g')
  if [[ -z "$START_CMD" ]]; then
    if [[ -f "package.json" ]] && grep -q '"dev"' package.json; then
      START_CMD="npm run dev"
    elif [[ -f "mix.exs" ]]; then
      START_CMD="mix phx.server"
    else
      det "No start command — skipping QA"
      return 0
    fi
  fi

  local APP_URL=""
  APP_URL=$(grep '^url:' "$CONFIG_FILE" 2>/dev/null | sed 's/^url: *//' | sed 's/"//g')
  [[ -z "$APP_URL" ]] && APP_URL="http://localhost:3000"

  det "Starting app: $START_CMD"
  eval "$START_CMD" &
  APP_PID=$!

  det "Waiting for $APP_URL..."
  local RETRIES=0
  while [[ $RETRIES -lt 30 ]]; do
    if curl -s -o /dev/null -w "%{http_code}" "$APP_URL" 2>/dev/null | grep -q "200\|304\|302\|301"; then
      det "App is ready"
      break
    fi
    sleep 2
    RETRIES=$((RETRIES + 1))
  done

  if [[ $RETRIES -ge 30 ]]; then
    det "App didn't start — skipping QA"
    kill $APP_PID 2>/dev/null || true
    return 0
  fi

  # QA agent gets spec/goal context + app URL + browser, no code write access
  local QA_SPEC=""
  if [[ "$MODE" == "goal" ]]; then
    QA_SPEC="THE GOAL (test against this):
$GOAL"
  elif [[ -n "$SPEC_CONTEXT" ]]; then
    QA_SPEC="$SPEC_CONTEXT"
  fi

  agt "QA testing the running app"
  claude_with_retry -p "You are QA testing a running web app at $APP_URL.

$QA_SPEC

Headless browser: $B

Test these flows based on the goal/spec above:
1. Does the main page load without JS errors?
2. Do all navigation links work?
3. Does the chat interface work?
4. Do forms submit correctly?
5. Are there console errors?
6. Do the key features from the spec/goal actually work?

Commands: $B goto URL, $B screenshot PATH, $B text, $B console --errors, $B snapshot -i, $B click SELECTOR

QA_SCORE: [0-100]
BUGS_FOUND:
- [bug description]
QA_VERDICT: PASS | FAIL" \
    --max-turns 30 \
    --allowedTools "Read,Bash,Grep,Glob" \
    2>&1 | tee "$QA_LOG"

  det "Stopping app (PID $APP_PID)"
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true

  if grep -q "QA_VERDICT: PASS" "$QA_LOG"; then
    det "QA PASSED ✓"
    echo "QA: PASSED" >> "$STATE_DIR/results-iter$ITERATION.txt"
    return 0
  else
    det "QA FAILED — bugs found"
    local BUGS=$(grep -A1 "BUGS_FOUND:" "$QA_LOG" | grep "^- " | head -10)
    if [[ -n "$BUGS" ]]; then
      echo "QA: FAILED" >> "$STATE_DIR/results-iter$ITERATION.txt"
      run_task "Fix QA bugs (iteration $ITERATION_NUM)" \
        "QA testing found these bugs:

$BUGS

Fix each bug."
    fi
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# EXECUTE: Run tasks (sequential or parallel)
# ═══════════════════════════════════════════════════════════════════════
execute_tasks() {
  local TASK_FILE="$1"
  local RESULTS_FILE="$STATE_DIR/results-iter$ITERATION.txt"
  > "$RESULTS_FILE"

  local TASK_COUNT=$(wc -l < "$TASK_FILE" | tr -d ' ')

  if [[ "$PARALLEL" -gt 1 && "$TASK_COUNT" -gt 1 ]]; then
    # ── PARALLEL MODE: git worktrees ──
    det "Running $TASK_COUNT tasks in parallel ($PARALLEL at a time)"
    local PIDS=()
    local RUNNING=0

    while IFS=$'\t' read -r TASK_NAME TASK_PROMPT; do
      [[ -z "$TASK_NAME" ]] && continue

      # Wait if at parallel limit
      while [[ $RUNNING -ge $PARALLEL ]]; do
        for i in "${!PIDS[@]}"; do
          if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
            wait "${PIDS[$i]}" || true
            unset "PIDS[$i]"
            RUNNING=$((RUNNING - 1))
          fi
        done
        sleep 1
      done

      # Launch in background (pass results file for tracking)
      run_task_in_worktree "$TASK_NAME" "$TASK_PROMPT" "$RESULTS_FILE" &
      PIDS+=($!)
      RUNNING=$((RUNNING + 1))
    done < "$TASK_FILE"

    # Wait for remaining
    for PID in "${PIDS[@]}"; do
      wait "$PID" || true
    done

    # Merge all parallel branches with conflict resolution
    det "Merging parallel branches"
    git checkout "$MAIN_BRANCH" 2>&1
    local MERGE_FAILED=()
    for BRANCH in $(git branch --list 'minion/*-iter'$ITERATION 2>/dev/null); do
      BRANCH=$(echo "$BRANCH" | tr -d ' *')
      if git merge "$BRANCH" --no-edit 2>&1; then
        det "Merged $BRANCH ✓"
        git branch -d "$BRANCH" 2>/dev/null || true
      else
        # Try rebase instead of merge
        git merge --abort 2>&1 || true
        det "Merge conflict on $BRANCH — trying rebase..."
        if git rebase "$MAIN_BRANCH" "$BRANCH" 2>&1 && \
           git checkout "$MAIN_BRANCH" 2>&1 && \
           git merge "$BRANCH" --no-edit 2>&1; then
          det "Rebased and merged $BRANCH ✓"
          git branch -d "$BRANCH" 2>/dev/null || true
        else
          git rebase --abort 2>/dev/null || true
          git checkout "$MAIN_BRANCH" 2>/dev/null || true
          MERGE_FAILED+=("$BRANCH")
          det "CONFLICT: $BRANCH could not be merged or rebased — branch preserved for manual review"
        fi
      fi
    done
    if [[ ${#MERGE_FAILED[@]} -gt 0 ]]; then
      det "Unmerged branches (${#MERGE_FAILED[@]}): ${MERGE_FAILED[*]}"
      echo "MERGE_CONFLICTS: ${MERGE_FAILED[*]}" >> "$RESULTS_FILE"
    fi
  else
    # ── SEQUENTIAL MODE ──
    while IFS=$'\t' read -r TASK_NAME TASK_PROMPT; do
      [[ -z "$TASK_NAME" ]] && continue
      run_task "$TASK_NAME" "$TASK_PROMPT"
      local STATUS=$?
      if [[ $STATUS -eq 0 ]]; then
        echo "PASSED: $TASK_NAME" >> "$RESULTS_FILE"
      else
        echo "FAILED: $TASK_NAME" >> "$RESULTS_FILE"
      fi
    done < "$TASK_FILE"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Parse minions.yaml
# ═══════════════════════════════════════════════════════════════════════
run_yaml_tasks() {
  local FILE="$1"
  [[ ! -f "$FILE" ]] && { echo "Tasks file not found: $FILE" >&2; exit 1; }

  local CURRENT_NAME="" CURRENT_PROMPT="" IN_PROMPT=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
      [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]] && run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
      CURRENT_NAME="${BASH_REMATCH[1]//\"/}"
      CURRENT_PROMPT=""
      IN_PROMPT=false
    elif [[ "$line" =~ ^[[:space:]]*prompt:[[:space:]]*\|[[:space:]]*$ ]]; then
      IN_PROMPT=true; CURRENT_PROMPT=""
    elif [[ "$line" =~ ^[[:space:]]*prompt:[[:space:]]+(.*) ]]; then
      CURRENT_PROMPT="${BASH_REMATCH[1]//\"/}"
    elif [[ "$IN_PROMPT" == "true" ]]; then
      if [[ "$line" =~ ^[[:space:]]{4,} ]] || [[ -z "${line// }" ]]; then
        CURRENT_PROMPT="$CURRENT_PROMPT
$line"
      else
        IN_PROMPT=false
      fi
    fi
  done < "$FILE"

  [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]] && run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════"
log "  claude-minions v$VERSION"
log "  Autonomous Spec-Driven Development"
log "  Started: $(date)"
log "  Project: $PROJECT_DIR"
log "  Verify:  $VERIFY_CMD"
log "  Retries: $MAX_RETRIES (escalating)"
log "  Parallel: $PARALLEL"
log "  Mode:    $(if [[ -n "$SINGLE_TASK" ]]; then echo "ad-hoc"; elif [[ -n "$TASKS_FILE" ]]; then echo "task-list"; else echo "convergence"; fi)"
log "═══════════════════════════════════════════════"

# Auth check
det "Checking auth..."
AUTH_RESULT=$(claude -p "Say OK" --max-turns 1 2>&1 || true)
if echo "$AUTH_RESULT" | grep -qi "not logged in"; then
  log "ERROR: claude -p not authenticated. Run: claude /login"
  exit 1
elif echo "$AUTH_RESULT" | grep -qi "hit your limit\|rate limit\|resets"; then
  RESET_TIME=$(echo "$AUTH_RESULT" | grep -oi "resets [0-9]*[ap]m\|resets [0-9]*:[0-9]*" | head -1)
  det "Rate limited${RESET_TIME:+ ($RESET_TIME)}. Waiting 5 minutes..."
  sleep 300
fi
det "Claude authenticated ✓"

# ─── Route to mode ────────────────────────────────────────────────────
if [[ -n "$SINGLE_TASK" ]]; then
  run_task "$SINGLE_TASK" "$SINGLE_TASK"

elif [[ -n "$TASKS_FILE" ]]; then
  run_yaml_tasks "$TASKS_FILE"

elif [[ "$VERIFY_ONLY" == "true" ]]; then
  if [[ -z "$SPEC_FILES" && -z "$GOAL" ]]; then
    log "ERROR: No spec or goal configured."
    exit 1
  fi
  MODE=$([[ -n "$GOAL" ]] && echo "goal" || echo "spec")
  verify_spec 0
  exit $?

else
  # ── Convergence loop ──
  if [[ -n "$GOAL" ]]; then
    MODE="goal"
  elif [[ -n "$SPEC_FILES" ]]; then
    MODE="spec"
  else
    log "ERROR: No goal or spec. Add goal: or spec: to config."
    exit 1
  fi

  log ""
  if [[ "$MODE" == "goal" ]]; then
    log "Mode: GOAL-DRIVEN (autonomous)"
    log "Goal: $(echo "$GOAL" | head -3)..."
  else
    log "Mode: SPEC-DRIVEN"
    while IFS= read -r f; do
      [[ -n "$f" ]] && log "  → $f"
    done <<< "$SPEC_FILES"
  fi
  log ""

  while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ITERATION=$((ITERATION + 1))
    log ""
    log "╔═══════════════════════════════════════════╗"
    log "║  ITERATION $ITERATION / $MAX_ITERATIONS"
    log "╚═══════════════════════════════════════════╝"

    if ! analyze $ITERATION; then
      log ""; log "Spec is SATISFIED. No more tasks needed."; break
    fi

    TASK_FILE="$STATE_DIR/tasks-iter$ITERATION.json"
    TASK_COUNT=$(wc -l < "$TASK_FILE" 2>/dev/null | tr -d ' ')

    if [[ "$TASK_COUNT" -eq 0 ]]; then
      log "No tasks generated — checking if done"
      verify_spec $ITERATION && { log "Spec SATISFIED ✓"; break; }
      log "Spec not satisfied but no tasks — may need manual intervention"
      break
    fi

    [[ "$DRY_RUN" == "true" ]] && {
      cat "$TASK_FILE" | while IFS=$'\t' read -r name prompt; do log "  → $name"; done
      continue
    }

    execute_tasks "$TASK_FILE"

    det "Pushing to origin"
    git push origin "$MAIN_BRANCH" 2>&1 | tee -a "$MASTER_LOG" || true

    local SKIP_QA=""
    SKIP_QA=$(grep '^skip_qa:' "$CONFIG_FILE" 2>/dev/null | sed 's/^skip_qa: *//')
    [[ "$SKIP_QA" != "true" ]] && qa_test $ITERATION

    verify_spec $ITERATION && { log ""; log "Spec SATISFIED after iteration $ITERATION ✓"; break; }
    log "Gaps remain — starting iteration $((ITERATION + 1))"
  done

  [[ $ITERATION -ge $MAX_ITERATIONS ]] && log "Hit max iterations ($MAX_ITERATIONS)."
fi

# ═══════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════

TOTAL_END=$(date +%s)
TOTAL_DURATION=$(( TOTAL_END - TOTAL_START ))
MINUTES=$(( TOTAL_DURATION / 60 ))
SECONDS_R=$(( TOTAL_DURATION % 60 ))

log ""
log "═══════════════════════════════════════════════"
log "  claude-minions v$VERSION — COMPLETE"
log "  Iterations: $ITERATION"
log "  Passed:     $PASSED"
log "  Failed:     $FAILED"
log "  Skipped:    $SKIPPED"
log "  Duration:   ${MINUTES}m ${SECONDS_R}s"
log "  Log:        $MASTER_LOG"
log "  State:      $STATE_DIR/"
log "═══════════════════════════════════════════════"

# Generate HTML report
REPORT="$LOG_DIR/report-$RUN_ID.html"
cat > "$REPORT" << 'HTMLEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Minions Report</title>
<style>body{font-family:monospace;background:#111;color:#eee;padding:20px;max-width:900px;margin:0 auto}
.pass{color:#30D158}.fail{color:#FF453A}.skip{color:#FFD60A}.det{color:#64D2FF}.agent{color:#BF5AF2}
h1{border-bottom:1px solid #333;padding-bottom:10px}pre{background:#1a1a1a;padding:15px;border-radius:8px;overflow-x:auto;border:1px solid #333}
.stat{display:inline-block;padding:8px 16px;margin:4px;border-radius:8px;background:#1a1a1a;border:1px solid #333}
</style></head><body>
HTMLEOF
echo "<h1>claude-minions v$VERSION — Run Report</h1>" >> "$REPORT"
echo "<p>$(date) | Duration: ${MINUTES}m ${SECONDS_R}s | Iterations: $ITERATION</p>" >> "$REPORT"
echo "<div><span class='stat pass'>✓ Passed: $PASSED</span><span class='stat fail'>✗ Failed: $FAILED</span><span class='stat skip'>○ Skipped: $SKIPPED</span></div>" >> "$REPORT"
echo "<h2>Log</h2><pre>" >> "$REPORT"
sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$MASTER_LOG" | sed \
  -e 's/■ DET/<span class="det">■ DET<\/span>/g' \
  -e 's/◆ AGENT/<span class="agent">◆ AGENT<\/span>/g' \
  -e 's/✓ PASS/<span class="pass">✓ PASS<\/span>/g' \
  -e 's/✗ FAIL/<span class="fail">✗ FAIL<\/span>/g' >> "$REPORT"
echo "</pre></body></html>" >> "$REPORT"
det "Report: $REPORT"

[[ $FAILED -gt 0 ]] && exit 1
exit 0
