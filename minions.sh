#!/bin/bash
# ┌─────────────────────────────────────────────────────────────────┐
# │  claude-minions v2 — Autonomous spec-driven development        │
# │                                                                 │
# │  Point it at a spec. It builds until the spec is satisfied.     │
# │  Stripe blueprint pattern + convergence loop.                   │
# │                                                                 │
# │  ANALYZE spec → GENERATE tasks → EXECUTE each task →            │
# │  VERIFY against spec → if gaps remain → LOOP                    │
# │  Max iterations prevent infinite loops.                         │
# └─────────────────────────────────────────────────────────────────┘
#
# Modes:
#   ./minions.sh                        # Spec-driven: read spec, build until done
#   ./minions.sh --tasks minions.yaml   # Task-driven: run a fixed task list
#   ./minions.sh --task "Fix auth bug"  # Ad-hoc: run a single task
#   ./minions.sh --verify-only          # Just check spec coverage, no building
#   ./minions.sh --dry-run              # Show what would run
#
# Config: minions.config.yaml (spec files, verify command, test command, etc.)
#
set -uo pipefail

VERSION="3.0.0"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ─── Config defaults ──────────────────────────────────────────────────
CONFIG_FILE="${MINIONS_CONFIG:-$PROJECT_DIR/minions.config.yaml}"
TASKS_FILE=""
LOG_DIR="${MINIONS_LOG_DIR:-$PROJECT_DIR/.minions/logs}"
STATE_DIR="${MINIONS_STATE_DIR:-$PROJECT_DIR/.minions/state}"
MAX_RETRIES="${MINIONS_MAX_RETRIES:-1}"
MAX_TURNS="${MINIONS_MAX_TURNS:-40}"
FIX_TURNS="${MINIONS_FIX_TURNS:-15}"
ANALYZE_TURNS="${MINIONS_ANALYZE_TURNS:-20}"
MAIN_BRANCH="${MINIONS_MAIN_BRANCH:-main}"
MAX_ITERATIONS="${MINIONS_MAX_ITERATIONS:-10}"
DRY_RUN=false
VERIFY_ONLY=false
SINGLE_TASK=""

# ─── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)      DRY_RUN=true; shift ;;
    --verify-only)  VERIFY_ONLY=true; shift ;;
    --task)         SINGLE_TASK="$2"; shift 2 ;;
    --tasks)        TASKS_FILE="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --max-turns)    MAX_TURNS="$2"; shift 2 ;;
    --max-iter)     MAX_ITERATIONS="$2"; shift 2 ;;
    --help|-h)
      echo "claude-minions v$VERSION — Autonomous spec-driven development"
      echo ""
      echo "Modes:"
      echo "  ./minions.sh                        Spec-driven (read spec, build until done)"
      echo "  ./minions.sh --tasks minions.yaml   Task-driven (run fixed task list)"
      echo "  ./minions.sh --task \"Fix bug\"        Ad-hoc (single task)"
      echo "  ./minions.sh --verify-only           Check spec coverage only"
      echo "  ./minions.sh --dry-run               Show plan without executing"
      echo ""
      echo "Options:"
      echo "  --config FILE      Config file (default: minions.config.yaml)"
      echo "  --max-turns N      Agent turns per task (default: 40)"
      echo "  --max-iter N       Max convergence iterations (default: 10)"
      echo "  --help             Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
MASTER_LOG="$LOG_DIR/run-$RUN_ID.log"

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

# ─── Read config ──────────────────────────────────────────────────────
SPEC_FILES=""
CONTEXT_FILES=""
CUSTOM_VERIFY=""
CUSTOM_TEST=""
GOAL=""
MODE=""  # spec, goal, tasks, adhoc

if [[ -f "$CONFIG_FILE" ]]; then
  det "Reading config: $CONFIG_FILE"

  # Parse goal (takes priority over spec) — handles YAML multiline block scalar (goal: |)
  GOAL=$(awk '
    /^goal:/ {
      found=1
      # Check for single-line goal (goal: "some text")
      sub(/^goal:[[:space:]]*\|?[[:space:]]*$/, "", $0)
      if ($0 != "") { print $0; found=0 }
      next
    }
    found && /^[a-zA-Z]/ { exit }
    found && /^[^ ]/ { exit }
    found { gsub(/^    /, ""); gsub(/^  /, ""); print }
  ' "$CONFIG_FILE" 2>/dev/null)
  # Trim leading/trailing whitespace
  GOAL=$(echo "$GOAL" | sed '/^$/d' | head -50)

  # Parse spec files
  SPEC_FILES=$(grep -A100 '^spec:' "$CONFIG_FILE" 2>/dev/null | grep '^ *- ' | sed 's/^ *- //' | sed 's/"//g' | head -20)

  # Parse context files
  CONTEXT_FILES=$(grep -A100 '^context:' "$CONFIG_FILE" 2>/dev/null | grep '^ *- ' | sed 's/^ *- //' | sed 's/"//g' | head -20)

  # Parse verify/test commands
  CUSTOM_VERIFY=$(grep '^verify:' "$CONFIG_FILE" 2>/dev/null | sed 's/^verify: *//' | sed 's/"//g')
  CUSTOM_TEST=$(grep '^test:' "$CONFIG_FILE" 2>/dev/null | sed 's/^test: *//' | sed 's/"//g')

  # Parse settings
  local_max_iter=$(grep '^max_iterations:' "$CONFIG_FILE" 2>/dev/null | sed 's/^max_iterations: *//')
  [[ -n "$local_max_iter" ]] && MAX_ITERATIONS="$local_max_iter"

  local_main=$(grep '^main_branch:' "$CONFIG_FILE" 2>/dev/null | sed 's/^main_branch: *//' | sed 's/"//g')
  [[ -n "$local_main" ]] && MAIN_BRANCH="$local_main"
fi

# ─── Detect project verify/test commands ──────────────────────────────
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

# ─── Build context string ─────────────────────────────────────────────
build_context() {
  local CTX=""
  # Auto-detect project files
  for f in CLAUDE.md README.md ARCHITECTURE.md; do
    [[ -f "$PROJECT_DIR/$f" ]] && CTX="$CTX
Read $PROJECT_DIR/$f for project context."
  done
  # Config-specified context files
  if [[ -n "$CONTEXT_FILES" ]]; then
    while IFS= read -r f; do
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
      [[ -n "$f" ]] && [[ -f "$f" ]] && CTX="$CTX
Read this SPEC file — the project must implement everything in it: $f"
    done <<< "$SPEC_FILES"
  fi
  echo "$CTX"
}

PROJECT_CONTEXT=$(build_context)
SPEC_CONTEXT=$(build_spec_context)

# ═══════════════════════════════════════════════════════════════════════
# CORE: Run one task (the Stripe blueprint)
# ═══════════════════════════════════════════════════════════════════════
run_task() {
  local TASK_NAME="$1"
  local PROMPT="$2"
  local SLUG=$(slug "$TASK_NAME")
  local BRANCH="minion/$SLUG-iter$ITERATION"
  local TASK_LOG="$LOG_DIR/$SLUG-iter$ITERATION.log"
  local TASK_START=$(date +%s)

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  TASK: $TASK_NAME (iteration $ITERATION)"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [DRY RUN] Would execute: $TASK_NAME"
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

  # ── [AGENTIC] Implement ──
  agt "Building: $TASK_NAME"
  claude -p "$PROMPT
$PROJECT_CONTEXT

RULES:
- Working directory: $PROJECT_DIR
- Read existing code before modifying
- Follow existing patterns
- Do NOT modify files outside this task's scope
- Do NOT refactor unrelated code
- Verify your changes compile: run '$VERIFY_CMD'" \
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
  det "Verify: $VERIFY_CMD"
  if ! eval "$VERIFY_CMD" 2>&1 | tee /tmp/verify-$SLUG.log; then
    VERIFY_ERRORS=$(tail -30 /tmp/verify-$SLUG.log)
    local RETRY=0

    while [[ $RETRY -lt $MAX_RETRIES ]]; do
      RETRY=$((RETRY + 1))
      agt "Fix attempt $RETRY/$MAX_RETRIES"
      claude -p "Build/compile failed. Fix ONLY these errors:

$VERIFY_ERRORS" \
        --max-turns "$FIX_TURNS" \
        --allowedTools "Read,Edit,Bash,Grep" \
        2>&1 | tee -a "$TASK_LOG"

      if eval "$VERIFY_CMD" 2>/dev/null; then
        det "Verify passed after fix"
        break
      fi
    done

    if ! eval "$VERIFY_CMD" 2>/dev/null; then
      fail "$TASK_NAME (verify failed)"
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

Built by claude-minions v$VERSION (iteration $ITERATION)" 2>&1 | tee -a "$TASK_LOG"

  git checkout "$MAIN_BRANCH" 2>&1
  if ! git merge "$BRANCH" --no-edit 2>&1 | tee -a "$TASK_LOG"; then
    fail "$TASK_NAME (merge conflict)"
    git merge --abort 2>&1 || true
    return 1
  fi
  git branch -d "$BRANCH" 2>&1

  local DURATION=$(( $(date +%s) - TASK_START ))
  pass "$TASK_NAME (${DURATION}s)"
}

# ═══════════════════════════════════════════════════════════════════════
# ANALYZE: Read codebase, figure out what to do
# Two modes: spec-driven (compare to spec) or goal-driven (figure it out)
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

  # QA results from previous iteration
  local QA_CONTEXT=""
  local PREV_QA="$STATE_DIR/qa-iter$((ITERATION_NUM - 1)).txt"
  if [[ -f "$PREV_QA" ]]; then
    QA_CONTEXT="
QA TEST RESULTS FROM PREVIOUS ITERATION (bugs found by browser testing):
$(tail -50 "$PREV_QA")"
  fi

  local ANALYSIS_PROMPT=""

  if [[ "$MODE" == "goal" ]]; then
    # ── GOAL-DRIVEN MODE ──
    # The agent explores the codebase, understands the goal, and decides what to do
    ANALYSIS_PROMPT="You are an autonomous developer. Your job is to make this project achieve its goal.

THE GOAL:
$GOAL

$PROJECT_CONTEXT
$PREV_CONTEXT
$QA_CONTEXT

You have FULL AUTONOMY to decide what needs to happen. There is no spec to follow — you decide what to build, fix, improve, or remove based on the goal.

APPROACH:
1. Read the codebase thoroughly — understand what exists, what works, what's broken
2. Think about the GOAL — what does 'done' look like? What would a user experience?
3. Identify the HIGHEST IMPACT work — what's the most broken/missing thing that blocks the goal?
4. Generate tasks to fix it, ordered by impact

YOU DECIDE:
- What architecture to use
- What files to create or modify
- What patterns to follow
- What to prioritize
- What to skip (if it's not needed for the goal)

The only constraint: each task must be completable in one session (~40 turns).

OUTPUT FORMAT (exactly this, parseable):
---TASKS---
TASK: [short name]
PROMPT: [what to do and why — be specific about files, but let the implementing agent make design decisions]
---
TASK: [next task]
PROMPT: [instructions]
---
---END---

If the goal is ACHIEVED (the project works as described), output:
---TASKS---
---DONE---

Max 8 tasks per iteration. Focus on what MATTERS MOST for the goal."

  elif [[ $ITERATION_NUM -eq 1 ]]; then
    # ── SPEC-DRIVEN MODE: First iteration ──
    ANALYSIS_PROMPT="You are analyzing a codebase against its spec to determine what needs to be built.

$SPEC_CONTEXT
$PROJECT_CONTEXT

ANALYZE the project:
1. Read all spec files listed above
2. Read the codebase (key files, directory structure, existing implementations)
3. Compare: what does the spec require vs what exists?
4. Generate a prioritized list of tasks to close the gaps

OUTPUT FORMAT (exactly this, parseable):
---TASKS---
TASK: [short name]
PROMPT: [detailed implementation instructions — what to build, which files to create/modify, what patterns to follow]
---
TASK: [next task]
PROMPT: [instructions]
---
---END---

RULES:
- Only list tasks for things that DON'T EXIST yet or are BROKEN
- Order by dependency: foundational tasks first
- Each task should be completable in one agent session (40 turns)
- If a feature is partially built, the task should say 'finish' not 'build'
- Be SPECIFIC in prompts — file paths, function names, expected behavior
- Max 10 tasks per iteration (do the most important ones first)"
  else
    # ── SPEC-DRIVEN MODE: Subsequent iterations ──
    ANALYSIS_PROMPT="You are re-analyzing a codebase after a development iteration. Some tasks were completed, some failed.

$SPEC_CONTEXT
$PROJECT_CONTEXT
$PREV_CONTEXT
$QA_CONTEXT

RE-ANALYZE:
1. Read the spec files
2. Read the CURRENT codebase (it has changed since last iteration)
3. Check what was completed vs what still has gaps
4. If there are QA bugs from browser testing, prioritize fixing those
5. Generate tasks ONLY for remaining gaps

OUTPUT FORMAT (exactly this, parseable):
---TASKS---
TASK: [short name]
PROMPT: [detailed instructions]
---
---END---

If the project FULLY SATISFIES the spec, output:
---TASKS---
---DONE---

RULES:
- Do NOT repeat tasks that already passed
- Failed tasks can be retried with a different approach
- QA bugs are HIGH PRIORITY — fix them first
- Be specific about what's STILL missing
- Max 10 tasks"
  fi

  agt "Analyzing codebase against spec"
  claude -p "$ANALYSIS_PROMPT" \
    --max-turns "$ANALYZE_TURNS" \
    --allowedTools "Read,Grep,Glob,Bash" \
    2>&1 | tee "$STATE_DIR/analysis-iter$ITERATION_NUM.txt"

  # Parse the output into tasks
  local ANALYSIS=$(cat "$STATE_DIR/analysis-iter$ITERATION_NUM.txt")

  # Check if done
  if echo "$ANALYSIS" | grep -q "\-\-\-DONE\-\-\-"; then
    det "Spec satisfied — no more tasks needed"
    return 1  # Signal: we're done
  fi

  # Extract tasks
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
# VERIFY: Check if spec is satisfied
# ═══════════════════════════════════════════════════════════════════════
verify_spec() {
  local ITERATION_NUM=$1

  local VERIFY_PROMPT=""

  if [[ "$MODE" == "goal" ]]; then
    # ── GOAL-DRIVEN VERIFICATION ──
    # Don't check against a spec — check if the goal is achieved
    agt "Verifying goal achievement"
    VERIFY_PROMPT="You are verifying whether a project achieves its goal.

THE GOAL:
$GOAL

$PROJECT_CONTEXT

VERIFY by actually examining the project:
1. Read the codebase — does the code look production-quality?
2. Check if the core user flows would work (trace the logic, check for missing pieces)
3. Look for broken imports, missing files, dead code, incomplete features
4. Think like a USER — would this app achieve the goal?

Also consider QA results if available:
$(cat "$STATE_DIR/qa-iter$ITERATION_NUM.txt" 2>/dev/null | tail -30)

SCORE the project on:
- Functionality: does it do what the goal describes? (0-100)
- Quality: is the code clean, typed, error-handled? (0-100)
- Completeness: are there half-built features? (0-100)

OUTPUT FORMAT:
FUNCTIONALITY: [number]%
QUALITY: [number]%
COMPLETENESS: [number]%
OVERALL: [number]%
REMAINING:
- [most important gap]
- [second most important]
...
VERDICT: DONE | NEEDS_WORK"
  else
    # ── SPEC-DRIVEN VERIFICATION ──
    agt "Verifying spec coverage"
    VERIFY_PROMPT="You are verifying whether a codebase satisfies its spec.

$SPEC_CONTEXT
$PROJECT_CONTEXT

CHECK every requirement in the spec files against the actual codebase:
1. Read each spec file
2. For each requirement/feature, check if it exists in the code
3. Score: what percentage of the spec is implemented?

Also consider QA results if available:
$(cat "$STATE_DIR/qa-iter$ITERATION_NUM.txt" 2>/dev/null | tail -30)

OUTPUT FORMAT:
COVERAGE: [number]%
REMAINING:
- [gap 1]
- [gap 2]
...
VERDICT: DONE | NEEDS_WORK"
  fi

  claude -p "$VERIFY_PROMPT" \
    --max-turns "$ANALYZE_TURNS" \
    --allowedTools "Read,Grep,Glob,Bash" \
    2>&1 | tee "$STATE_DIR/verify-iter$ITERATION_NUM.txt"

  if grep -q "VERDICT: DONE" "$STATE_DIR/verify-iter$ITERATION_NUM.txt"; then
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════════════
# EXECUTE: Run all tasks from a task list file
# ═══════════════════════════════════════════════════════════════════════
execute_tasks() {
  local TASK_FILE="$1"
  local RESULTS_FILE="$STATE_DIR/results-iter$ITERATION.txt"
  > "$RESULTS_FILE"

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
}

# ═══════════════════════════════════════════════════════════════════════
# QA: Start the app and test it with a browser
# ═══════════════════════════════════════════════════════════════════════
qa_test() {
  local ITERATION_NUM=$1
  local QA_LOG="$STATE_DIR/qa-iter$ITERATION_NUM.txt"
  local QA_SCREENSHOTS="$STATE_DIR/screenshots-iter$ITERATION_NUM"
  mkdir -p "$QA_SCREENSHOTS"

  # Check for browse binary
  local B=""
  [[ -x "$HOME/.claude/skills/gstack/browse/dist/browse" ]] && B="$HOME/.claude/skills/gstack/browse/dist/browse"
  if [[ -z "$B" ]]; then
    det "No browse binary — skipping QA (install gstack for browser testing)"
    return 0
  fi

  # Read start command from config or auto-detect
  local START_CMD=""
  START_CMD=$(grep '^start:' "$CONFIG_FILE" 2>/dev/null | sed 's/^start: *//' | sed 's/"//g')
  if [[ -z "$START_CMD" ]]; then
    if [[ -f "package.json" ]] && grep -q '"dev"' package.json; then
      START_CMD="npm run dev"
    elif [[ -f "mix.exs" ]]; then
      START_CMD="mix phx.server"
    else
      det "No start command found — skipping QA"
      return 0
    fi
  fi

  # Read app URL from config or default
  local APP_URL=""
  APP_URL=$(grep '^url:' "$CONFIG_FILE" 2>/dev/null | sed 's/^url: *//' | sed 's/"//g')
  [[ -z "$APP_URL" ]] && APP_URL="http://localhost:3000"

  det "Starting app: $START_CMD"
  eval "$START_CMD" &
  APP_PID=$!

  # Wait for app to be ready
  det "Waiting for $APP_URL to respond..."
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
    det "App didn't start in 60s — skipping QA"
    kill $APP_PID 2>/dev/null || true
    return 0
  fi

  # [AGENTIC] QA the running app
  agt "QA testing the running app"
  claude -p "You are QA testing a running web application at $APP_URL.

You have a headless browser at: $B

$SPEC_CONTEXT
$PROJECT_CONTEXT

TEST THE APP using the browse binary. For each test:
1. Navigate: $B goto $APP_URL
2. Take screenshot: $B screenshot $QA_SCREENSHOTS/test-name.png
3. Check content: $B text
4. Check for errors: $B console --errors
5. Test interactions: $B snapshot -i then $B click @e1, $B fill @e2 \"test\", etc.

TEST THESE FLOWS (based on the spec):
- Does the main page load without JS errors?
- Do all navigation links work?
- Does the chat/agent interface work? (send a message, get response)
- Do forms submit correctly?
- Are there any console errors?
- Do interactive elements respond?

After testing, output:

QA_SCORE: [0-100]
BUGS_FOUND:
- [bug 1: what's broken, screenshot path]
- [bug 2: ...]
QA_VERDICT: PASS | FAIL

If FAIL, describe each bug clearly so a developer can fix it." \
    --max-turns 30 \
    --allowedTools "Read,Bash,Grep,Glob" \
    2>&1 | tee "$QA_LOG"

  # Kill the app
  det "Stopping app (PID $APP_PID)"
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true

  # Parse QA results
  if grep -q "QA_VERDICT: PASS" "$QA_LOG"; then
    det "QA PASSED ✓"
    echo "QA: PASSED" >> "$STATE_DIR/results-iter$ITERATION.txt"
    return 0
  else
    det "QA FAILED — bugs found"
    # Extract bugs and create fix tasks
    local BUGS=$(grep -A1 "BUGS_FOUND:" "$QA_LOG" | grep "^- " | head -10)
    if [[ -n "$BUGS" ]]; then
      echo "QA: FAILED — bugs found" >> "$STATE_DIR/results-iter$ITERATION.txt"

      # Run a fix agent for QA bugs
      run_task "Fix QA bugs (iteration $ITERATION_NUM)" \
        "The QA test found these bugs in the running app:

$BUGS

Screenshots are in $QA_SCREENSHOTS/ — read them for visual context.

Fix each bug. The app runs at $APP_URL with '$START_CMD'."
    fi
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# Parse minions.yaml (for --tasks mode)
# ═══════════════════════════════════════════════════════════════════════
run_yaml_tasks() {
  local FILE="$1"
  if [[ ! -f "$FILE" ]]; then
    echo "Tasks file not found: $FILE" >&2
    exit 1
  fi

  local CURRENT_NAME="" CURRENT_PROMPT="" IN_PROMPT=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
      if [[ -n "$CURRENT_NAME" && -n "$CURRENT_PROMPT" ]]; then
        run_task "$CURRENT_NAME" "$CURRENT_PROMPT"
      fi
      CURRENT_NAME="${BASH_REMATCH[1]//\"/}"
      CURRENT_PROMPT=""
      IN_PROMPT=false
    elif [[ "$line" =~ ^[[:space:]]*prompt:[[:space:]]*\|[[:space:]]*$ ]]; then
      IN_PROMPT=true
      CURRENT_PROMPT=""
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
log "  Mode:    $(if [[ -n "$SINGLE_TASK" ]]; then echo "ad-hoc"; elif [[ -n "$TASKS_FILE" ]]; then echo "task-list"; else echo "spec-driven"; fi)"
log "═══════════════════════════════════════════════"

# Auth check — try a simple prompt, fail only if "Not logged in" appears
AUTH_RESULT=$(claude -p "Say OK" --max-turns 1 2>&1 || true)
if echo "$AUTH_RESULT" | grep -qi "not logged in"; then
  log "ERROR: claude -p not authenticated. Run: claude /login"
  exit 1
fi
det "Claude authenticated ✓"

# ─── Mode: Ad-hoc single task ────────────────────────────────────────
if [[ -n "$SINGLE_TASK" ]]; then
  run_task "$SINGLE_TASK" "$SINGLE_TASK"

# ─── Mode: Fixed task list ────────────────────────────────────────────
elif [[ -n "$TASKS_FILE" ]]; then
  run_yaml_tasks "$TASKS_FILE"

# ─── Mode: Verify only ───────────────────────────────────────────────
elif [[ "$VERIFY_ONLY" == "true" ]]; then
  if [[ -z "$SPEC_FILES" ]]; then
    log "ERROR: No spec files configured. Add spec: section to minions.config.yaml"
    exit 1
  fi
  verify_spec 0
  exit $?

# ─── Mode: Spec-driven or Goal-driven convergence loop ────────────────
else
  # Determine mode
  if [[ -n "$GOAL" ]]; then
    MODE="goal"
  elif [[ -n "$SPEC_FILES" ]]; then
    MODE="spec"
  else
    log "ERROR: No goal or spec files. Add goal: or spec: to minions.config.yaml"
    exit 1
  fi

  log ""
  if [[ "$MODE" == "goal" ]]; then
    log "Mode: GOAL-DRIVEN (autonomous)"
    log "Goal: $(echo "$GOAL" | head -3)..."
  else
    log "Mode: SPEC-DRIVEN"
    log "Spec files:"
    while IFS= read -r f; do
      [[ -n "$f" ]] && log "  → $f"
    done <<< "$SPEC_FILES"
  fi
  log ""

  # ── THE CONVERGENCE LOOP ──
  while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ITERATION=$((ITERATION + 1))
    log ""
    log "╔═══════════════════════════════════════════╗"
    log "║  ITERATION $ITERATION / $MAX_ITERATIONS"
    log "╚═══════════════════════════════════════════╝"

    # [AGENTIC] Analyze spec vs codebase → generate tasks
    if ! analyze $ITERATION; then
      log ""
      log "Spec is SATISFIED. No more tasks needed."
      break
    fi

    TASK_FILE="$STATE_DIR/tasks-iter$ITERATION.json"
    TASK_COUNT=$(wc -l < "$TASK_FILE" 2>/dev/null | tr -d ' ')

    if [[ "$TASK_COUNT" -eq 0 ]]; then
      log "No tasks generated — checking if we're done"
      if verify_spec $ITERATION; then
        log "Spec SATISFIED ✓"
        break
      else
        log "Spec not satisfied but no tasks generated — may need manual intervention"
        break
      fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "Tasks that would run:"
      cat "$TASK_FILE" | while IFS=$'\t' read -r name prompt; do
        log "  → $name"
      done
      continue
    fi

    # [MIXED] Execute each task (deterministic + agentic)
    execute_tasks "$TASK_FILE"

    # [DETERMINISTIC] Push progress
    det "Pushing to origin"
    git push origin "$MAIN_BRANCH" 2>&1 | tee -a "$MASTER_LOG" || true

    # [MIXED] QA test the running app (if configured)
    local SKIP_QA=""
    SKIP_QA=$(grep '^skip_qa:' "$CONFIG_FILE" 2>/dev/null | sed 's/^skip_qa: *//')
    if [[ "$SKIP_QA" != "true" ]]; then
      qa_test $ITERATION
    fi

    # [AGENTIC] Verify spec coverage
    if verify_spec $ITERATION; then
      log ""
      log "Spec SATISFIED after iteration $ITERATION ✓"
      break
    fi

    log "Gaps remain — starting iteration $((ITERATION + 1))"
  done

  if [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    log ""
    log "Hit max iterations ($MAX_ITERATIONS). Check $STATE_DIR/ for remaining gaps."
  fi
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

[[ $FAILED -gt 0 ]] && exit 1
exit 0
