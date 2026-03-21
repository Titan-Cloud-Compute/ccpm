#!/bin/bash
# scope-pipeline.sh - Scope-to-PRD pipeline orchestrator
#
# Chains: interrogate → extract-findings → scope-research → roadmap-generate
#         → scope-decompose → scope-generate (per PRD) → prd-parse (per PRD)
#         → batch-process → build-deployment → deploy
#
# After interrogate completes (interactive), the remaining steps run
# unattended. Progress is tracked in a SQLite database so a frontend
# can render the full session conversation and current pipeline state.
#
# Usage:
#   ./scope-pipeline.sh <session-name>              # Full pipeline
#   ./scope-pipeline.sh --resume <session-name>     # Resume from last step
#   ./scope-pipeline.sh --resume-from <N> <session> # Resume from step N (1-10)
#   ./scope-pipeline.sh --status <session-name>     # Show status
#   ./scope-pipeline.sh --status-json <session-name> # JSON for frontend
#   ./scope-pipeline.sh --sessions                  # List all sessions
#
# SQLite DB: .claude/pipeline/scope-pipeline.db
#
# Tables:
#   pipeline_steps  - Static reference (8 rows, pipeline definition)
#   sessions        - One row per session (state, current step, final URL)
#   messages        - Every message exchanged (conversation log for frontend)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH=".claude/pipeline/scope-pipeline.db"

TOTAL_STEPS=10

# ============================================================
# SQLite Setup
# ============================================================

init_db() {
  mkdir -p "$(dirname "$DB_PATH")"

  sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS pipeline_steps (
  step_number       INTEGER PRIMARY KEY,
  step_name         TEXT NOT NULL UNIQUE,
  display_title     TEXT NOT NULL,
  description       TEXT NOT NULL,
  expected_input    TEXT NOT NULL
);

-- Seed static rows (ignore if already present)
INSERT OR IGNORE INTO pipeline_steps (step_number, step_name, display_title, description, expected_input) VALUES
  (1, 'interrogate',      'Discovery',           'Interactive session where CCPM researches your idea, presents features and journeys for confirmation, and collects infrastructure preferences.',                    'Topic description, feature review (keep/remove/modify/add), authentication method, user scale, permissions model, deployment target, integrations'),
  (2, 'extract-findings', 'Extracting Scope',    'Queries the database for confirmed features, journeys, and infrastructure choices, then generates a set of scope documents.',                                      'Session name'),
  (3, 'scope-research',   'Researching Gaps',    'Scans scope documents for unknowns and TBDs, runs targeted web searches, and writes recommendations for each gap.',                                               'Session name'),
  (4, 'roadmap-generate', 'Building Roadmap',    'Prioritizes features using MoSCoW and RICE scoring, maps dependencies, and sequences everything into phased milestones with exit criteria.',                      'Session name'),
  (5, 'scope-decompose',  'Decomposing Scope',   'Breaks the scope into independent, well-bounded PRD proposals with dependency graph and execution order.',                                                        'Session name'),
  (6, 'scope-generate',   'Generating PRDs',     'Creates a full PRD file for each item in the decomposition, complete with requirements, acceptance criteria, and dependency references.',                          'Session name (loops per PRD from decomposition)'),
  (7, 'prd-parse',        'Creating Epics',      'Converts each PRD into a technical implementation epic with architecture decisions, task breakdown, and effort estimates.',                                        'Feature name (loops per backlog PRD)'),
  (8, 'batch-process',    'Building Project',    'Processes all backlog PRDs in dependency order, running implementation for each one.',                                                                             'None (automatic)'),
  (9, 'build-deployment', 'Building Images',     'Builds container images for all services and pushes them to the configured registry.',                                                                                'Session name'),
  (10, 'deploy',          'Deploying',           'Deploys the built images to Kubernetes, applies manifests, and verifies pods are running.',                                                                           'Session name');

CREATE TABLE IF NOT EXISTS sessions (
  session_id   TEXT PRIMARY KEY,
  status       TEXT NOT NULL DEFAULT 'pending',
  current_step INTEGER NOT NULL DEFAULT 0,
  started_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  completed_at TEXT,
  final_url    TEXT,
  error        TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id    TEXT NOT NULL REFERENCES sessions(session_id),
  process_step  INTEGER NOT NULL REFERENCES pipeline_steps(step_number),
  message_source TEXT NOT NULL CHECK (message_source IN ('user', 'ccpm')),
  message_content TEXT NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
CREATE INDEX IF NOT EXISTS idx_messages_session_step ON messages(session_id, process_step);
SQL
}

# ============================================================
# DB Helpers
# ============================================================

db() {
  sqlite3 -batch "$DB_PATH" "$1"
}

db_scalar() {
  sqlite3 -batch -noheader "$DB_PATH" "$1" | tr -d '[:space:]'
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Escape single quotes for SQL insertion
sql_escape() {
  echo "$1" | sed "s/'/''/g"
}

# ============================================================
# Session Management
# ============================================================

create_session() {
  local session_id="$1"
  local now
  now=$(now_utc)

  # Check if session already exists
  local existing
  existing=$(db_scalar "SELECT COUNT(*) FROM sessions WHERE session_id = '$session_id';")
  if [ "$existing" -gt 0 ]; then
    # Resume existing session
    db "UPDATE sessions SET status = 'running', updated_at = '$now' WHERE session_id = '$session_id';"
    return 0
  fi

  db "INSERT INTO sessions (session_id, status, current_step, started_at, updated_at)
      VALUES ('$session_id', 'running', 0, '$now', '$now');"
}

update_session() {
  local session_id="$1"
  local field="$2"
  local value="$3"
  local now
  now=$(now_utc)
  local escaped
  escaped=$(sql_escape "$value")
  db "UPDATE sessions SET $field = '$escaped', updated_at = '$now' WHERE session_id = '$session_id';"
}

set_session_step() {
  local session_id="$1"
  local step="$2"
  local now
  now=$(now_utc)
  db "UPDATE sessions SET current_step = $step, updated_at = '$now' WHERE session_id = '$session_id';"
}

set_session_status() {
  local session_id="$1"
  local status="$2"
  local now
  now=$(now_utc)
  local extra=""
  if [ "$status" = "complete" ] || [ "$status" = "failed" ]; then
    extra=", completed_at = '$now'"
  fi
  db "UPDATE sessions SET status = '$status', updated_at = '$now' $extra WHERE session_id = '$session_id';"
}

set_session_error() {
  local session_id="$1"
  local error="$2"
  local escaped
  escaped=$(sql_escape "$error")
  db "UPDATE sessions SET error = '$(echo "$escaped" | head -c 2000)' WHERE session_id = '$session_id';"
}

set_session_url() {
  local session_id="$1"
  local url="$2"
  update_session "$session_id" "final_url" "$url"
}

# ============================================================
# Message Logging
# ============================================================

# Log a message to the conversation
# Usage: msg <session_id> <step_number> <source> <content>
msg() {
  local session_id="$1"
  local step="$2"
  local source="$3"
  local content="$4"
  local escaped
  escaped=$(sql_escape "$content")
  # Truncate to 50k chars to prevent DB bloat
  escaped=$(echo "$escaped" | head -c 50000)
  db "INSERT INTO messages (session_id, process_step, message_source, message_content)
      VALUES ('$session_id', $step, '$source', '$escaped');"
}

# Convenience wrappers
msg_ccpm() {
  msg "$1" "$2" "ccpm" "$3"
}

msg_user() {
  msg "$1" "$2" "user" "$3"
}

# ============================================================
# Step Implementations
# ============================================================

run_step_1_interrogate() {
  local session="$1"
  local conv=".claude/interrogations/$session/conversation.md"

  # Check if already complete
  if [ -f "$conv" ]; then
    local status
    status=$(grep "^Status:" "$conv" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
    if [ "$status" = "complete" ]; then
      msg_ccpm "$session" 1 "Interrogation already complete, skipping."
      return 0
    fi
  fi

  msg_ccpm "$session" 1 "Starting interactive discovery session. Launching Claude for interrogation."

  if [ -t 0 ]; then
    echo ""
    echo "=== Interactive Step: Discovery ==="
    echo ""
    echo "Claude will start an interactive session."
    echo "Run:  /pm:interrogate $session"
    echo "When done, exit Claude (Ctrl+C or /exit)."
    echo ""
    read -p "Press Enter to launch Claude... "
    claude --dangerously-skip-permissions || true
  else
    claude --dangerously-skip-permissions --print "/pm:interrogate $session"
  fi

  # Verify completion
  if [ -f "$conv" ]; then
    local status
    status=$(grep "^Status:" "$conv" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
    if [ "$status" = "complete" ]; then
      # Log the conversation into messages table
      import_conversation "$session" "$conv"
      msg_ccpm "$session" 1 "Discovery complete."
      return 0
    fi
  fi

  msg_ccpm "$session" 1 "Interrogation did not complete."
  return 1
}

# Import conversation.md exchanges into messages table
import_conversation() {
  local session="$1"
  local conv_file="$2"

  [ -f "$conv_file" ] || return 0

  local current_source=""
  local current_content=""

  while IFS= read -r line; do
    if [[ "$line" == "**Claude:"* ]]; then
      # Flush previous message
      if [ -n "$current_source" ] && [ -n "$current_content" ]; then
        if [ "$current_source" = "ccpm" ]; then
          msg_ccpm "$session" 1 "$current_content"
        else
          msg_user "$session" 1 "$current_content"
        fi
      fi
      current_source="ccpm"
      current_content=$(echo "$line" | sed 's/^\*\*Claude:\*\* *//')
    elif [[ "$line" == "**User:"* ]]; then
      # Flush previous message
      if [ -n "$current_source" ] && [ -n "$current_content" ]; then
        if [ "$current_source" = "ccpm" ]; then
          msg_ccpm "$session" 1 "$current_content"
        else
          msg_user "$session" 1 "$current_content"
        fi
      fi
      current_source="user"
      current_content=$(echo "$line" | sed 's/^\*\*User:\*\* *//')
    elif [ -n "$current_source" ] && [ -n "$line" ]; then
      current_content="$current_content $line"
    fi
  done < "$conv_file"

  # Flush last message
  if [ -n "$current_source" ] && [ -n "$current_content" ]; then
    if [ "$current_source" = "ccpm" ]; then
      msg_ccpm "$session" 1 "$current_content"
    else
      msg_user "$session" 1 "$current_content"
    fi
  fi
}

run_step_2_extract_findings() {
  local session="$1"
  msg_ccpm "$session" 2 "Extracting scope documents from database..."
  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:extract-findings $session" 2>&1) || {
    msg_ccpm "$session" 2 "Extract findings failed."
    return 1
  }
  msg_ccpm "$session" 2 "Scope documents generated in .claude/scopes/$session/"
}

run_step_3_scope_research() {
  local session="$1"
  msg_ccpm "$session" 3 "Scanning scope for unknowns and researching answers..."
  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:scope-research $session" 2>&1) || {
    msg_ccpm "$session" 3 "Scope research failed."
    return 1
  }
  msg_ccpm "$session" 3 "Research complete. Results in .claude/scopes/$session/research.md"
}

run_step_4_roadmap_generate() {
  local session="$1"
  msg_ccpm "$session" 4 "Generating phased MVP roadmap with RICE scoring..."
  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:roadmap-generate $session" 2>&1) || {
    msg_ccpm "$session" 4 "Roadmap generation failed."
    return 1
  }
  msg_ccpm "$session" 4 "Roadmap generated: .claude/scopes/$session/07_roadmap.md"
}

run_step_5_scope_decompose() {
  local session="$1"
  msg_ccpm "$session" 5 "Decomposing scope into independent PRD proposals..."
  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:scope-decompose $session" 2>&1) || {
    msg_ccpm "$session" 5 "Scope decomposition failed."
    return 1
  }
  msg_ccpm "$session" 5 "Decomposition complete: .claude/scopes/$session/decomposition.md"
}

run_step_6_scope_generate() {
  local session="$1"
  local decomp=".claude/scopes/$session/decomposition.md"

  if [ ! -f "$decomp" ]; then
    msg_ccpm "$session" 6 "decomposition.md not found."
    return 1
  fi

  # Extract PRD names from decomposition.md
  local prds=()
  while IFS= read -r line; do
    local prd_name
    prd_name=$(echo "$line" | sed 's/^### PRD: //' | tr -d '[:space:]')
    if [ -n "$prd_name" ]; then
      prds+=("$prd_name")
    fi
  done < <(grep "^### PRD:" "$decomp" 2>/dev/null)

  if [ ${#prds[@]} -eq 0 ]; then
    msg_ccpm "$session" 6 "No PRDs found in decomposition.md."
    return 1
  fi

  msg_ccpm "$session" 6 "Generating ${#prds[@]} PRDs from decomposition..."

  local generated=0
  local failed=0

  for prd_name in "${prds[@]}"; do
    msg_ccpm "$session" 6 "Generating PRD: $prd_name"

    if claude --dangerously-skip-permissions --print "/pm:scope-generate $session $prd_name" 2>&1; then
      generated=$((generated + 1))
      msg_ccpm "$session" 6 "PRD generated: $prd_name → .claude/prds/${prd_name}.md"
    else
      failed=$((failed + 1))
      msg_ccpm "$session" 6 "Failed to generate PRD: $prd_name"
    fi
  done

  msg_ccpm "$session" 6 "PRD generation complete. Generated: $generated, Failed: $failed"

  [ "$generated" -gt 0 ] && return 0
  return 1
}

run_step_7_prd_parse() {
  local session="$1"

  local prds=()
  for f in .claude/prds/*.md; do
    [ -f "$f" ] || continue
    if grep -q "^status: backlog" "$f" 2>/dev/null; then
      local name
      name=$(basename "$f" .md)
      prds+=("$name")
    fi
  done

  if [ ${#prds[@]} -eq 0 ]; then
    msg_ccpm "$session" 7 "No backlog PRDs found."
    return 1
  fi

  msg_ccpm "$session" 7 "Parsing ${#prds[@]} PRDs into technical epics..."

  local parsed=0
  local failed=0

  for prd_name in "${prds[@]}"; do
    msg_ccpm "$session" 7 "Parsing: $prd_name → epic"

    if claude --dangerously-skip-permissions --print "/pm:prd-parse $prd_name" 2>&1; then
      parsed=$((parsed + 1))
      msg_ccpm "$session" 7 "Epic created: .claude/epics/${prd_name}/epic.md"
    else
      failed=$((failed + 1))
      msg_ccpm "$session" 7 "Failed to parse: $prd_name"
    fi
  done

  msg_ccpm "$session" 7 "Epic creation complete. Parsed: $parsed, Failed: $failed"

  [ "$parsed" -gt 0 ] && return 0
  return 1
}

run_step_8_batch_process() {
  local session="$1"
  msg_ccpm "$session" 8 "Starting batch processing of all backlog PRDs in dependency order..."

  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:batch-process" 2>&1) || {
    msg_ccpm "$session" 8 "Batch processing failed."
    return 1
  }

  msg_ccpm "$session" 8 "Batch processing complete."
}

run_step_9_build_deployment() {
  local session="$1"
  msg_ccpm "$session" 9 "Building container images and pushing to registry..."

  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:build-deployment $session" 2>&1) || {
    msg_ccpm "$session" 9 "Image build failed."
    return 1
  }

  msg_ccpm "$session" 9 "Container images built and pushed."
}

run_step_10_deploy() {
  local session="$1"
  msg_ccpm "$session" 10 "Deploying to Kubernetes..."

  local output
  output=$(claude --dangerously-skip-permissions --print "/pm:deploy $session" 2>&1) || {
    msg_ccpm "$session" 10 "Deployment failed."
    return 1
  }

  # Try to extract the deployed URL from deploy output or K8s ingress
  local url=""
  url=$(echo "$output" | grep -oP 'https?://[^\s]+' | tail -1) || true
  if [ -z "$url" ]; then
    # Fallback: check ingress for the namespace
    url=$(kubectl get ingress -n "$session" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null) || true
    [ -n "$url" ] && url="https://$url"
  fi

  if [ -n "$url" ]; then
    set_session_url "$session" "$url"
    msg_ccpm "$session" 10 "Deployment complete. Live at: $url"
  else
    msg_ccpm "$session" 10 "Deployment complete. URL not detected — set manually with: sqlite3 $DB_PATH \"UPDATE sessions SET final_url = '<url>' WHERE session_id = '$session';\""
  fi
}

# ============================================================
# Step Dispatcher
# ============================================================

run_step() {
  local step_num="$1"
  local session="$2"

  case "$step_num" in
    1) run_step_1_interrogate "$session" ;;
    2) run_step_2_extract_findings "$session" ;;
    3) run_step_3_scope_research "$session" ;;
    4) run_step_4_roadmap_generate "$session" ;;
    5) run_step_5_scope_decompose "$session" ;;
    6) run_step_6_scope_generate "$session" ;;
    7) run_step_7_prd_parse "$session" ;;
    8) run_step_8_batch_process "$session" ;;
    9) run_step_9_build_deployment "$session" ;;
    10) run_step_10_deploy "$session" ;;
    *) echo "Unknown step: $step_num"; return 1 ;;
  esac
}

# ============================================================
# Pre-checks
# ============================================================

precheck_step() {
  local step_num="$1"
  local session="$2"

  case "$step_num" in
    1) return 0 ;;
    2)
      local conv=".claude/interrogations/$session/conversation.md"
      [ -f "$conv" ] || { echo "No conversation.md"; return 1; }
      ;;
    3)
      [ -d ".claude/scopes/$session" ] || { echo "No scope directory"; return 1; }
      ;;
    4)
      [ -f ".claude/scopes/$session/00_scope_document.md" ] || { echo "No scope document"; return 1; }
      ;;
    5)
      [ -f ".claude/scopes/$session/00_scope_document.md" ] || { echo "No scope document"; return 1; }
      ;;
    6)
      [ -f ".claude/scopes/$session/decomposition.md" ] || { echo "No decomposition.md"; return 1; }
      ;;
    7)
      local count
      count=$(ls -1 .claude/prds/*.md 2>/dev/null | wc -l)
      [ "$count" -gt 0 ] || { echo "No PRD files"; return 1; }
      ;;
    8)
      local backlog
      backlog=$(grep -rl "^status: backlog" .claude/prds/*.md 2>/dev/null | wc -l)
      [ "$backlog" -gt 0 ] || { echo "No backlog PRDs"; return 1; }
      ;;
    9)
      # build-deployment needs scope config
      [ -f ".claude/scopes/$session/00_scope_document.md" ] || { echo "No scope document"; return 1; }
      ;;
    10)
      # deploy needs scope config
      [ -f ".claude/scopes/$session/00_scope_document.md" ] || { echo "No scope document"; return 1; }
      ;;
  esac
  return 0
}

# ============================================================
# Pipeline Executor
# ============================================================

execute_pipeline() {
  local session="$1"
  local start_step="${2:-1}"

  init_db
  create_session "$session"

  echo "=== Scope Pipeline ==="
  echo "Session: $session"
  echo "DB:      $DB_PATH"
  echo ""

  msg_ccpm "$session" "$start_step" "Pipeline started from step $start_step."

  local failed=false

  for ((i = start_step; i <= TOTAL_STEPS; i++)); do
    local display_title
    display_title=$(db_scalar "SELECT display_title FROM pipeline_steps WHERE step_number = $i;")
    local step_name
    step_name=$(db_scalar "SELECT step_name FROM pipeline_steps WHERE step_number = $i;")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step $i/$TOTAL_STEPS: $display_title"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Pre-check
    local precheck_err
    if ! precheck_err=$(precheck_step "$i" "$session" 2>&1); then
      msg_ccpm "$session" "$i" "Pre-check failed: $precheck_err"
      set_session_status "$session" "failed"
      set_session_error "$session" "Step $i ($step_name) pre-check failed: $precheck_err"
      echo "❌ Pre-check failed: $precheck_err"
      failed=true
      break
    fi

    # Update session to current step
    set_session_step "$session" "$i"

    # Execute
    local exit_code=0
    if [ "$i" -eq 1 ]; then
      run_step "$i" "$session" || exit_code=$?
    else
      run_step "$i" "$session" 2>&1 | tee /dev/stderr || exit_code=${PIPESTATUS[0]}
    fi

    if [ "$exit_code" -ne 0 ]; then
      msg_ccpm "$session" "$i" "Step failed with exit code $exit_code."
      set_session_status "$session" "failed"
      set_session_error "$session" "Step $i ($step_name) failed"
      echo ""
      echo "❌ Step $i ($display_title) failed"
      echo ""
      echo "Resume: $0 --resume-from $i $session"
      failed=true
      break
    fi

    echo ""
    echo "✓ Step $i ($display_title) complete"
  done

  if [ "$failed" = false ]; then
    set_session_status "$session" "complete"
    msg_ccpm "$session" "$TOTAL_STEPS" "Pipeline complete."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Pipeline Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Session: $session"
    echo ""
    echo "Outputs:"
    echo "  Scope:  .claude/scopes/$session/"
    echo "  PRDs:   .claude/prds/"
    echo "  Epics:  .claude/epics/"
    echo ""
    echo "Status:  $0 --status $session"
  fi
}

# ============================================================
# Status Display
# ============================================================

show_status() {
  local session="$1"
  init_db

  local exists
  exists=$(db_scalar "SELECT COUNT(*) FROM sessions WHERE session_id = '$session';")
  if [ "$exists" -eq 0 ]; then
    echo "No session found: $session"
    return 1
  fi

  local status current started updated final_url error
  status=$(db_scalar "SELECT status FROM sessions WHERE session_id = '$session';")
  current=$(db_scalar "SELECT current_step FROM sessions WHERE session_id = '$session';")
  started=$(db_scalar "SELECT started_at FROM sessions WHERE session_id = '$session';")
  updated=$(db_scalar "SELECT updated_at FROM sessions WHERE session_id = '$session';")
  final_url=$(db_scalar "SELECT COALESCE(final_url,'') FROM sessions WHERE session_id = '$session';")
  error=$(db_scalar "SELECT COALESCE(error,'') FROM sessions WHERE session_id = '$session';")

  echo "=== Session Status ==="
  echo "Session:  $session"
  echo "Status:   $status"
  echo "Step:     $current / $TOTAL_STEPS"
  echo "Started:  $started"
  echo "Updated:  $updated"
  [ -n "$final_url" ] && echo "URL:      $final_url"
  echo ""
  echo "Steps:"

  sqlite3 -batch "$DB_PATH" \
    "SELECT step_number, display_title FROM pipeline_steps ORDER BY step_number;" \
    | while IFS='|' read -r num title; do
      local icon="○"
      if [ "$num" -lt "$current" ]; then
        icon="✓"
      elif [ "$num" -eq "$current" ] && [ "$status" = "running" ]; then
        icon="►"
      elif [ "$num" -eq "$current" ] && [ "$status" = "failed" ]; then
        icon="✗"
      fi
      printf "  %s %d. %s\n" "$icon" "$num" "$title"
    done

  if [ -n "$error" ]; then
    echo ""
    echo "Error: $error"
  fi

  # Message count
  local msg_count
  msg_count=$(db_scalar "SELECT COUNT(*) FROM messages WHERE session_id = '$session';")
  echo ""
  echo "Messages: $msg_count"
}

show_status_json() {
  local session="$1"
  init_db

  local exists
  exists=$(db_scalar "SELECT COUNT(*) FROM sessions WHERE session_id = '$session';")
  if [ "$exists" -eq 0 ]; then
    echo '{"error": "session not found"}'
    return 1
  fi

  local status current started updated completed final_url error
  status=$(db_scalar "SELECT status FROM sessions WHERE session_id = '$session';")
  current=$(db_scalar "SELECT current_step FROM sessions WHERE session_id = '$session';")
  started=$(db_scalar "SELECT started_at FROM sessions WHERE session_id = '$session';")
  updated=$(db_scalar "SELECT updated_at FROM sessions WHERE session_id = '$session';")
  completed=$(db_scalar "SELECT COALESCE(completed_at,'') FROM sessions WHERE session_id = '$session';")
  final_url=$(db_scalar "SELECT COALESCE(final_url,'') FROM sessions WHERE session_id = '$session';")
  error=$(db_scalar "SELECT COALESCE(error,'') FROM sessions WHERE session_id = '$session';")

  # Build JSON with python for safety (handles escaping)
  python3 -c "
import json, sqlite3, sys

conn = sqlite3.connect('$DB_PATH')
conn.row_factory = sqlite3.Row

# Session
session = {
    'session_id': '$session',
    'status': '$status',
    'current_step': $current,
    'total_steps': $TOTAL_STEPS,
    'started_at': '$started',
    'updated_at': '$updated',
    'completed_at': '$completed' or None,
    'final_url': '$final_url' or None,
    'error': '$error' or None
}

# Steps
steps = [dict(r) for r in conn.execute('SELECT * FROM pipeline_steps ORDER BY step_number')]
session['steps'] = steps

# Messages
msgs = [dict(r) for r in conn.execute(
    'SELECT id, process_step, message_source, message_content, created_at FROM messages WHERE session_id = ? ORDER BY id',
    ('$session',)
)]
session['messages'] = msgs

conn.close()
print(json.dumps(session, indent=2, default=str))
"
}

list_sessions() {
  init_db

  echo "=== Sessions ==="
  echo ""

  local count
  count=$(db_scalar "SELECT COUNT(*) FROM sessions;")

  if [ "$count" -eq 0 ]; then
    echo "No sessions found."
    return 0
  fi

  printf "%-25s %-10s %-6s %-22s %s\n" "SESSION" "STATUS" "STEP" "STARTED" "URL"
  printf "%-25s %-10s %-6s %-22s %s\n" "-------" "------" "----" "-------" "---"

  sqlite3 -batch "$DB_PATH" \
    "SELECT session_id, status, current_step || '/$TOTAL_STEPS', started_at, COALESCE(final_url,'') FROM sessions ORDER BY started_at DESC;" \
    | while IFS='|' read -r sid st prog start url; do
      printf "%-25s %-10s %-6s %-22s %s\n" "$sid" "$st" "$prog" "$start" "$url"
    done
}

# ============================================================
# Resume Logic
# ============================================================

get_resume_step() {
  local session="$1"
  init_db

  local exists
  exists=$(db_scalar "SELECT COUNT(*) FROM sessions WHERE session_id = '$session';")
  if [ "$exists" -eq 0 ]; then
    echo "1"
    return
  fi

  local current status
  current=$(db_scalar "SELECT current_step FROM sessions WHERE session_id = '$session';")
  status=$(db_scalar "SELECT status FROM sessions WHERE session_id = '$session';")

  if [ "$status" = "complete" ]; then
    echo "$((TOTAL_STEPS + 1))"
  elif [ "$status" = "failed" ]; then
    # Retry the failed step
    echo "$current"
  else
    echo "$((current + 1))"
  fi
}

# ============================================================
# CLI
# ============================================================

show_help() {
  cat <<'EOF'
Scope Pipeline - Interrogate to Batch Process

Usage:
  scope-pipeline.sh <session-name>                Full pipeline run
  scope-pipeline.sh --resume <session-name>       Resume from last incomplete step
  scope-pipeline.sh --resume-from <N> <session>   Resume from specific step (1-8)
  scope-pipeline.sh --status <session-name>       Show session status
  scope-pipeline.sh --status-json <session-name>  Full session JSON (for frontend)
  scope-pipeline.sh --sessions                    List all sessions
  scope-pipeline.sh --help                        This help

Steps:
  1. Discovery         Interactive interrogation session
  2. Extracting Scope  Generate scope documents from database
  3. Researching Gaps  Fill unknowns with web research
  4. Building Roadmap  RICE scoring and phased milestones
  5. Decomposing Scope Break scope into PRD proposals
  6. Generating PRDs   Create PRD files from decomposition
  7. Creating Epics    Parse PRDs into technical epics
  8. Building Project  Batch process all backlog PRDs
  9. Building Images   Build and push container images
 10. Deploying         Deploy to Kubernetes

SQLite DB: .claude/pipeline/scope-pipeline.db

Tables:
  pipeline_steps  Static reference (8 rows)
  sessions        One row per session
  messages        Conversation log (query by session_id)

Frontend queries:
  -- Full conversation for a session
  SELECT * FROM messages WHERE session_id = ? ORDER BY id;

  -- Current session state
  SELECT * FROM sessions WHERE session_id = ?;

  -- Step definitions (static)
  SELECT * FROM pipeline_steps ORDER BY step_number;
EOF
}

case "${1:-}" in
  --help|-h)
    show_help
    ;;
  --status|-s)
    [ -z "${2:-}" ] && { echo "Usage: $0 --status <session-name>"; exit 1; }
    show_status "$2"
    ;;
  --status-json)
    [ -z "${2:-}" ] && { echo "Usage: $0 --status-json <session-name>"; exit 1; }
    show_status_json "$2"
    ;;
  --sessions|--list|--runs)
    list_sessions
    ;;
  --resume)
    [ -z "${2:-}" ] && { echo "Usage: $0 --resume <session-name>"; exit 1; }
    session="$2"
    init_db
    step=$(get_resume_step "$session")
    if [ "$step" -gt "$TOTAL_STEPS" ]; then
      echo "Pipeline already complete for: $session"
      echo "Start fresh: $0 $session"
      exit 0
    fi
    echo "Resuming from step $step"
    execute_pipeline "$session" "$step"
    ;;
  --resume-from)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "Usage: $0 --resume-from <step> <session-name>"; exit 1; }
    step="$2"
    session="$3"
    if [ "$step" -lt 1 ] || [ "$step" -gt "$TOTAL_STEPS" ]; then
      echo "Step must be 1-$TOTAL_STEPS"
      exit 1
    fi
    execute_pipeline "$session" "$step"
    ;;
  "")
    show_help
    exit 1
    ;;
  --*)
    echo "Unknown option: $1"
    show_help
    exit 1
    ;;
  *)
    execute_pipeline "$1"
    ;;
esac
