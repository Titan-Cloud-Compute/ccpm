# Scope Pipeline Specification

Orchestrates the full path from idea to deployed application. After the interactive discovery step, the remaining pipeline runs unattended through PRD generation, implementation, image builds, and Kubernetes deployment. All state and conversation history is tracked in a SQLite database that a frontend can query to render the user session.

## Pipeline Steps

| # | Command | Display Title | What Happens |
|---|---------|---------------|--------------|
| 1 | `interrogate` | Discovery | CCPM researches the user's idea, presents features/journeys for confirmation, collects infrastructure preferences |
| 2 | `extract-findings` | Extracting Scope | Queries database for confirmed data, generates scope documents |
| 3 | `scope-research` | Researching Gaps | Scans scope for unknowns/TBDs, runs web searches, writes recommendations |
| 4 | `roadmap-generate` | Building Roadmap | MoSCoW + RICE scoring, dependency mapping, phased milestones |
| 5 | `scope-decompose` | Decomposing Scope | Breaks scope into independent PRD proposals with dependency graph |
| 6 | `scope-generate` | Generating PRDs | Creates a full PRD file for each decomposition item |
| 7 | `prd-parse` | Creating Epics | Converts each PRD into a technical epic with architecture and tasks |
| 8 | `batch-process` | Building Project | Executes all backlog PRDs in dependency order |
| 9 | `build-deployment` | Building Images | Builds container images for all services and pushes to registry |
| 10 | `deploy` | Deploying | Deploys images to Kubernetes, applies manifests, verifies pods are running |

## Usage

```bash
# Full pipeline
./scope-pipeline.sh <session-name>

# Resume from last incomplete step
./scope-pipeline.sh --resume <session-name>

# Resume from specific step
./scope-pipeline.sh --resume-from <step-number> <session-name>

# Session status (human-readable)
./scope-pipeline.sh --status <session-name>

# Full session JSON (for frontend)
./scope-pipeline.sh --status-json <session-name>

# List all sessions
./scope-pipeline.sh --sessions
```

## User Input

The user provides input **only during step 1** (Discovery). Everything after runs unattended.

### Step 1: Discovery (interactive)

| Prompt | User Provides |
|--------|--------------|
| "What would you like to build?" | Topic description |
| 2-3 clarifying questions from `/dr-refine` | Answers to narrow scope |
| Feature/journey review | Confirm all, or KEEP/REMOVE/MODIFY/ADD |
| Authentication method | Selection (email/password, social, SSO, magic link, API key) |
| Expected user scale | Selection (100s, 1000s, 10000s+) |
| Permissions model | Same access or role-based (if roles, list them) |
| Deployment target | Selection (AWS, GCP, Vercel, self-hosted) |
| Third-party integrations | Multi-select (Stripe, Shopify, Slack, etc.) |

### Steps 2-10

No user input. Each step reads from the outputs of prior steps.

---

## SQLite Schema

Database location: `.claude/pipeline/scope-pipeline.db`

Three tables. The frontend reads `sessions` for state, `messages` for conversation history, and `pipeline_steps` for step metadata.

### `pipeline_steps`

Static reference table. 8 rows, seeded on first run, never changes.

```sql
CREATE TABLE pipeline_steps (
  step_number    INTEGER PRIMARY KEY,
  step_name      TEXT NOT NULL UNIQUE,     -- e.g. "interrogate"
  display_title  TEXT NOT NULL,            -- e.g. "Discovery" (shown in status bar)
  description    TEXT NOT NULL,            -- User-friendly paragraph explaining the step
  expected_input TEXT NOT NULL             -- What the user provides at this step
);
```

**Static data:**

| step_number | step_name | display_title | expected_input |
|-------------|-----------|---------------|----------------|
| 1 | interrogate | Discovery | Topic, feature review, auth, scale, permissions, deployment, integrations |
| 2 | extract-findings | Extracting Scope | Session name |
| 3 | scope-research | Researching Gaps | Session name |
| 4 | roadmap-generate | Building Roadmap | Session name |
| 5 | scope-decompose | Decomposing Scope | Session name |
| 6 | scope-generate | Generating PRDs | Session name (loops per PRD) |
| 7 | prd-parse | Creating Epics | Feature name (loops per PRD) |
| 8 | batch-process | Building Project | None |
| 9 | build-deployment | Building Images | Session name |
| 10 | deploy | Deploying | Session name |

### `sessions`

One row per session. Holds pipeline state and the final deployed URL.

```sql
CREATE TABLE sessions (
  session_id   TEXT PRIMARY KEY,          -- User-chosen name (e.g. "my-saas-app")
  status       TEXT NOT NULL,             -- pending | running | complete | failed
  current_step INTEGER NOT NULL,          -- 0 = not started, 1-10 = active/last step
  started_at   TEXT NOT NULL,             -- ISO 8601 UTC
  updated_at   TEXT NOT NULL,             -- ISO 8601 UTC
  completed_at TEXT,                      -- Set when status = complete or failed
  final_url    TEXT,                      -- Deployed site URL (set once at end)
  error        TEXT                       -- Error message if failed
);
```

### `messages`

Every message exchanged between the user and CCPM. The frontend queries this table by `session_id` to render the full conversation.

```sql
CREATE TABLE messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT NOT NULL REFERENCES sessions(session_id),
  process_step    INTEGER NOT NULL REFERENCES pipeline_steps(step_number),
  message_source  TEXT NOT NULL CHECK (message_source IN ('user', 'ccpm')),
  message_content TEXT NOT NULL,
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX idx_messages_session ON messages(session_id);
CREATE INDEX idx_messages_session_step ON messages(session_id, process_step);
```

**Column details:**

| Column | Description |
|--------|-------------|
| `session_id` | Links to `sessions.session_id` |
| `process_step` | Which pipeline step this message belongs to (1-8) |
| `message_source` | `user` for user input, `ccpm` for system output |
| `message_content` | The actual message text |
| `created_at` | UTC timestamp, auto-populated |

---

## Frontend Query Patterns

### Render full conversation for a session

```sql
SELECT process_step, message_source, message_content, created_at
FROM messages
WHERE session_id = ?
ORDER BY id;
```

### Get current session state (for status bar)

```sql
SELECT s.session_id, s.status, s.current_step,
       p.display_title, p.description,
       s.final_url
FROM sessions s
JOIN pipeline_steps p ON p.step_number = s.current_step
WHERE s.session_id = ?;
```

### Get step definitions (for progress indicator)

```sql
SELECT step_number, display_title, description, expected_input
FROM pipeline_steps
ORDER BY step_number;
```

### Get messages for a specific step

```sql
SELECT message_source, message_content, created_at
FROM messages
WHERE session_id = ? AND process_step = ?
ORDER BY id;
```

### Percentage complete (approximate)

```sql
SELECT ROUND(100.0 * current_step / 10, 0) AS pct
FROM sessions
WHERE session_id = ?;
```

### Write a user message (frontend → DB)

```sql
INSERT INTO messages (session_id, process_step, message_source, message_content)
VALUES (?, ?, 'user', ?);
```

### Write a CCPM message (pipeline → DB)

```sql
INSERT INTO messages (session_id, process_step, message_source, message_content)
VALUES (?, ?, 'ccpm', ?);
```

### JSON endpoint

```bash
./scope-pipeline.sh --status-json <session-name>
```

Returns the full session object with steps and messages:

```json
{
  "session_id": "my-saas-app",
  "status": "running",
  "current_step": 4,
  "total_steps": 10,
  "started_at": "2026-03-20T14:30:00Z",
  "updated_at": "2026-03-20T15:12:33Z",
  "completed_at": null,
  "final_url": null,
  "error": null,
  "steps": [
    {
      "step_number": 1,
      "step_name": "interrogate",
      "display_title": "Discovery",
      "description": "Interactive session where CCPM researches...",
      "expected_input": "Topic description, feature review..."
    }
  ],
  "messages": [
    {
      "id": 1,
      "process_step": 1,
      "message_source": "ccpm",
      "message_content": "What would you like to build?",
      "created_at": "2026-03-20T14:30:05Z"
    },
    {
      "id": 2,
      "process_step": 1,
      "message_source": "user",
      "message_content": "A marketplace for handmade goods",
      "created_at": "2026-03-20T14:30:42Z"
    }
  ]
}
```

---

## Pre-checks

Each step validates that its prerequisites exist before running.

| Step | Pre-check |
|------|-----------|
| 1 | None |
| 2 | `.claude/interrogations/{session}/conversation.md` exists |
| 3 | `.claude/scopes/{session}/` directory exists |
| 4 | `.claude/scopes/{session}/00_scope_document.md` exists |
| 5 | `.claude/scopes/{session}/00_scope_document.md` exists |
| 6 | `.claude/scopes/{session}/decomposition.md` exists |
| 7 | At least one `.claude/prds/*.md` file exists |
| 8 | At least one PRD with `status: backlog` exists |
| 9 | `.claude/scopes/{session}/00_scope_document.md` exists |
| 10 | `.claude/scopes/{session}/00_scope_document.md` exists |

## Failure and Resume

When a step fails:

1. A `ccpm` message is logged with the error
2. Session status is set to `failed`, `current_step` stays on the failed step
3. Pipeline halts
4. User is shown the resume command

Resume behavior:

- `--resume` detects the failed step from `sessions.current_step` and retries it
- `--resume-from N` forces restart from step N
- The existing session row is reused (same `session_id`), messages accumulate

---

## File Outputs by Step

```
.claude/
├── interrogations/{session}/
│   └── conversation.md              ← Step 1
├── scopes/{session}/
│   ├── 00_scope_document.md         ← Step 2
│   ├── 01_features.md               ← Step 2
│   ├── 02_user_journeys.md          ← Step 2
│   ├── 03_technical_ops.md          ← Step 2
│   ├── 04_nfr_requirements.md       ← Step 2
│   ├── 05_technical_architecture.md ← Step 2
│   ├── 06_risk_assessment.md        ← Step 2
│   ├── 07_gap_analysis.md           ← Step 2
│   ├── 08_test_plan.md              ← Step 2
│   ├── research.md                  ← Step 3
│   ├── 07_roadmap.md                ← Step 4
│   └── decomposition.md             ← Step 5
├── prds/
│   ├── {prd-1}.md                   ← Step 6
│   ├── {prd-2}.md                   ← Step 6
│   └── ...
├── epics/
│   ├── {prd-1}/epic.md              ← Step 7
│   ├── {prd-2}/epic.md              ← Step 7
│   └── ...
├── pipeline/
│   └── scope-pipeline.db            ← All steps (sessions, messages, step defs)
└── (container images pushed to registry) ← Step 9
    (pods deployed to Kubernetes)         ← Step 10
    (final_url set on sessions table)     ← Step 10
```
