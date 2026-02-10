# Managing Agents and Sessions Per Bonsai Project

Date: 2026-02-04

> **Architecture note:** Bonsai is a standalone application. There is no OpenClaw Gateway, no WebSocket RPC, no channel adapters, and no `openclaw.json`. Agents run in-process via a heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, which reads SQLite, runs agents, writes results, and exits. All agent-human communication happens via comments on tickets. The web app (Next.js) is the full UI. All data lives in `~/.bonsai/`. See **doc 13 (Agent Runtime)** for the heartbeat model and **doc 14 (Tool System)** for tool execution.

## Overview

This document is the operational handbook for how Bonsai creates, configures, and manages agents and sessions for each project. It covers the project lifecycle, session storage, bootstrap files, and the operations map. All operations are Bonsai-native — direct SQLite writes and filesystem operations. There is no Gateway RPC. References to OpenClaw source paths indicate extraction origins.

---

## 1. Agent Lifecycle

### 1.1 Creating a Project Agent

When a user creates a new Bonsai project, Bonsai inserts a project record into SQLite and bootstraps the workspace. Agent creation is Bonsai-native — just a project record in the database plus filesystem setup.

**SQLite insert** — create a project record:

```typescript
interface BonsaiProject {
  id: string;              // "proj_abc123"
  name: string;            // "My Project"
  slug: string;            // "my-project"
  persona: string;         // "developer"
  repo: {
    url: string;           // "https://github.com/org/my-project"
    defaultBranch: string; // "main"
  };
  settings: {
    model?: string;        // Override per-project
    toolProfile?: string;  // "developer" | "read-only" | custom
    sandbox?: string;      // "docker" | "none"
  };
  createdAt: string;
}
```

**Required fields:**
- `id` — auto-generated unique ID (e.g., `proj_abc123`)
- `name` — user-facing display name
- `slug` — URL-safe identifier, validated against `/^[a-z0-9][a-z0-9_-]{0,63}$/`
- `persona` — reference to a persona template in `~/.bonsai/personas/`

**File system side effects on creation:**

| What's created | Path | Purpose |
|---------------|------|---------|
| Project directory | `~/.bonsai/projects/{slug}/` | Cloned repo lives here |
| Project config | `~/.bonsai/projects/{slug}/.bonsai/project.json` | Project metadata |
| Workspace bootstrap | `~/.bonsai/projects/{slug}/.bonsai/SOUL.md`, etc. | Persona files copied from template |
| Sessions directory | `~/.bonsai/sessions/{projectId}/` | Session transcripts |
| Memory DB | `~/.bonsai/memory/{projectId}.sqlite` | Vector index for memory search |

**Extraction origins:**
- Directory creation: `src/agents/agent-scope.ts:136,149` (resolveAgentWorkspaceDir, resolveAgentDir)
- Session dir: `src/config/sessions/paths.ts:24-30` (resolveSessionTranscriptsDirForAgent)
- Bootstrap files: `src/agents/workspace.ts:118-130` (ensureAgentWorkspace)

### 1.2 Programmatic Project Creation (What Bonsai Actually Does)

Bonsai creates projects directly via SQLite and filesystem operations:

```typescript
// 1. Clone the repository
await gitClone(repoUrl, `~/.bonsai/projects/${slug}`);

// 2. Insert project record into SQLite
await db.projects.insert({
  id: generateId("proj"),
  name: "My Project",
  slug: "my-project",
  persona: "developer",
  repo: { url: repoUrl, defaultBranch: "main" },
  createdAt: new Date().toISOString(),
});

// 3. Copy persona files to workspace
await copyPersonaFiles("developer", `~/.bonsai/projects/${slug}/.bonsai/`);

// 4. Ensure workspace directory + bootstrap files exist
await ensureAgentWorkspace({
  dir: `~/.bonsai/projects/${slug}`,
  ensureBootstrapFiles: true,
});

// 5. Create sessions directory
await mkdir(`~/.bonsai/sessions/${projectId}/`, { recursive: true });
```

### 1.3 Updating a Project

Project updates are direct SQLite writes. Since agents run via the heartbeat model (not a persistent process), changes take effect on the **next heartbeat run**.

```typescript
await db.projects.update(projectId, {
  persona: "reviewer",
  settings: { model: "claude-opus-4-5-20251101" },
});
```

There is no hot-reload mechanism — the heartbeat reads fresh state from SQLite on every invocation.

### 1.4 Deleting a Project

**SQLite cleanup:**
1. Remove project record from `projects` table
2. Remove all tickets for the project from `tickets` table
3. Remove all comments for those tickets from `comments` table

**File system cleanup:**

| What's removed | Path | Method |
|---------------|------|--------|
| Project workspace | `~/.bonsai/projects/{slug}/` | Moved to OS trash |
| Sessions | `~/.bonsai/sessions/{projectId}/` | Moved to OS trash |
| Memory DB | `~/.bonsai/memory/{projectId}.sqlite` | Moved to OS trash |

Files are **moved to trash, not permanently deleted**. This allows recovery.

Extraction origin: `src/commands/agents.commands.delete.ts:20` (agentsDeleteCommand)

### 1.5 Listing Projects

All project listing is via direct SQLite queries:

```typescript
// List all projects
const projects = await db.projects.list();

// Get a specific project
const project = await db.projects.get(projectId);

// List projects with ticket counts
const projectsWithStats = await db.projects.listWithStats();
```

---

## 2. Session Management

### 2.1 Session Data Model

Each session corresponds to an agent working on a specific ticket. Sessions track the LLM conversation transcript and metadata:

```typescript
type SessionEntry = {
  sessionId: string;          // UUID — identifies the transcript
  projectId: string;          // Which project this session belongs to
  ticketId: string;           // Which ticket this session is for
  updatedAt: number;          // Timestamp of last update

  // Agent config overrides (per-session)
  modelOverride?: string;
  providerOverride?: string;
  thinkingLevel?: string;
  verboseLevel?: string;

  // Token accounting
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;

  // Compaction
  compactionCount?: number;

  // UI
  label?: string;             // User-friendly label
};
```

Extraction origin: `src/config/sessions/types.ts:26-90`

### 2.2 Session Storage

**Store file per project:**
```
~/.bonsai/sessions/{projectId}/sessions.json
```

**Transcript files per session (one per ticket):**
```
~/.bonsai/sessions/{projectId}/{ticketId}.jsonl
~/.bonsai/sessions/{projectId}/{ticketId}-topic-{topicId}.jsonl
```

**Store format:** JSON object keyed by session key:
```json
{
  "bonsai:proj_abc123:ticket:tkt_001": {
    "sessionId": "a1b2c3d4-...",
    "projectId": "proj_abc123",
    "ticketId": "tkt_001",
    "updatedAt": 1707000000000,
    "label": "Fix login bug"
  },
  "bonsai:proj_abc123:ticket:tkt_002": {
    "sessionId": "e5f6g7h8-...",
    "projectId": "proj_abc123",
    "ticketId": "tkt_002",
    "updatedAt": 1707000001000,
    "label": "Add dark mode"
  }
}
```

**Transcript format:** JSONL (first line is header):
```jsonl
{"type":"session","version":1,"id":"a1b2c3d4-...","timestamp":"2026-02-04T12:00:00Z"}
{"message":{"role":"user","content":"Fix the login bug","timestamp":1707000000000}}
{"message":{"role":"assistant","content":"I'll look at...","timestamp":1707000001000}}
```

**Extraction origins:**
- Store path: `src/config/sessions/paths.ts:32-34` (resolveDefaultSessionStorePath)
- Transcript path: `src/config/sessions/paths.ts:36-50` (resolveSessionTranscriptPath)
- Store load: `src/config/sessions/store.ts:99-163` (loadSessionStore, 45s TTL cache)
- Store write: `src/config/sessions/store.ts:241-248` (saveSessionStore, file-locked, atomic)

### 2.3 Session Key Format

Session keys embed the project and ticket ID, enforcing per-project/per-ticket isolation:

```
bonsai:{projectId}:ticket:{ticketId}
```

**Examples:**
| Key | Meaning |
|-----|---------|
| `bonsai:proj_abc123:ticket:tkt_001` | Session for ticket tkt_001 in project proj_abc123 |
| `bonsai:proj_abc123:ticket:tkt_042` | Session for ticket tkt_042 in project proj_abc123 |
| `bonsai:proj_def456:ticket:tkt_001` | Session for ticket tkt_001 in a different project |

**Key building function:**

```typescript
function buildSessionKey(projectId: string, ticketId: string): string {
  return `bonsai:${projectId}:ticket:${ticketId}`;
}
```

Extraction origin: `src/routing/session-key.ts:101-108,135-154`

### 2.4 Session Operations (Direct DB)

All session operations are direct database/filesystem operations. There is no RPC layer.

**List sessions for a project:**
```typescript
const sessions = await loadSessionStore(
  `~/.bonsai/sessions/${projectId}/sessions.json`
);
```

**Create/update a session (on agent run):**
```typescript
await updateSessionStore(storePath, (store) => {
  const key = buildSessionKey(projectId, ticketId);
  store[key] = {
    sessionId: crypto.randomUUID(),
    projectId,
    ticketId,
    updatedAt: Date.now(),
    label: ticket.title,
  };
});
```

**Get transcript for a ticket:**
```typescript
const transcript = await readTranscript(
  `~/.bonsai/sessions/${projectId}/${ticketId}.jsonl`
);
```

**Delete a session:**
```typescript
await updateSessionStore(storePath, (store) => {
  delete store[buildSessionKey(projectId, ticketId)];
});
// Archive transcript file
await rename(transcriptPath, `${transcriptPath}.deleted.${Date.now()}`);
```

### 2.5 Session Store Concurrency

The session store uses **file-based locking** for safe concurrent access (important since multiple heartbeat runs could overlap):

```typescript
// Atomic read-modify-write
await updateSessionStore(storePath, (store) => {
  const key = buildSessionKey(projectId, ticketId);
  store[key].label = "Updated label";
});
```

**Locking mechanics** (extraction origin: `src/config/sessions/store.ts:269-294`):
1. Acquire lock file: `{storePath}.lock` (exclusive create via `"wx"` flag)
2. Re-read store inside lock (prevents stale reads)
3. Apply mutation
4. Write to temp file then atomic rename
5. Release lock

**Cache:** 45-second TTL (configurable). Invalidated on write or file mtime change.

### 2.6 What Happens to Sessions When a Project Is Deleted

1. Sessions directory is **moved to OS trash** (not permanently deleted)
2. Session entries remain in the store file for recovery
3. SQLite records (project, tickets, comments) are deleted
4. No automatic cleanup of in-flight runs — heartbeat handles abort if running

---

## 3. Workspace and Bootstrap Files

### 3.1 Bootstrap File List

These files live in the project's workspace directory and are loaded on **every agent run** (every heartbeat invocation for that ticket):

| File | Purpose | Loaded for subagents? |
|------|---------|----------------------|
| `SOUL.md` | Agent persona and behavior instructions | No |
| `MEMORY.md` / `memory.md` | Knowledge base (also vector-indexed) | No |
| `AGENTS.md` | Subagent definitions | Yes |
| `TOOLS.md` | Tool usage guidance | Yes |
| `IDENTITY.md` | Agent identity/role | No |
| `USER.md` | User context info | No |
| `HEARTBEAT.md` | Periodic task instructions | No |
| `BOOTSTRAP.md` | Workspace initialization notes | No |

**Extraction origin:** `src/agents/workspace.ts:224-278` (loadWorkspaceBootstrapFiles)

### 3.2 How SOUL.md Becomes the System Prompt

1. On each agent run, `resolveBootstrapContextForRun()` reads all bootstrap files from disk
2. Files are truncated to max chars (default: 20,000 chars) — 70% head, 20% tail
3. System prompt is assembled in `buildAgentSystemPrompt()`:
   - `# Project Context` header
   - If SOUL.md is present, a special instruction is injected: "embody its persona and tone"
   - Each file rendered as `## {filename}\n\n{content}`
   - Ticket description and recent comments are appended as context
4. Prompt is locked for the duration of the run

**Critical behavior: SOUL.md is loaded fresh on every run. No restart required.**

If Bonsai writes a new `SOUL.md` to the workspace, the agent picks it up on the **next heartbeat run**.

**Extraction origins:**
- Loading: `src/agents/workspace.ts` (loadWorkspaceBootstrapFiles)
- Context assembly: `src/agents/pi-embedded-runner/run/attempt.ts` lines 184-191
- System prompt: `src/agents/system-prompt.ts` lines 497-514
- Truncation: `src/agents/pi-embedded-helpers/bootstrap.ts` lines 72-89

### 3.3 MEMORY.md and Vector Indexing

MEMORY.md is **dual-purpose**:
1. Injected into the system prompt (like other bootstrap files)
2. Chunked and embedded into `~/.bonsai/memory/{projectId}.sqlite` for semantic search

**Reindexing triggers:**
- File watcher (chokidar) detects changes to `MEMORY.md`, `memory.md`, or `memory/` directory
- On session start if `memorySearch.sync.onSessionStart` is enabled
- On search if dirty flag is set and `sync.onSearch` is enabled
- Periodic interval (`sync.intervalMinutes`)
- Full reindex on: model change, provider change, auth key change, chunk settings change

**Extraction origin:** `src/memory/manager.ts`

### 3.4 Bonsai's SOUL.md Generation

For each project, Bonsai writes a SOUL.md scoped to that project:

```markdown
You are a developer working exclusively on the {project-name} repository.

Repository: {github-url}
Language: {detected-language}
Branch: {default-branch}
Local path: {workspace-path}

## Rules
- Only make changes within this repository
- Follow the project's existing code style and conventions
- Run tests before committing
- Create focused, well-described commits
- Communicate progress and questions via comments on the ticket
- Do NOT access files outside this repository

## Communication
- All communication with humans happens via comments on tickets
- Post progress updates as comments when starting and finishing work
- Ask clarifying questions as comments — the human will respond on the next review
- When work is complete, push to verification and post a summary comment

## Project Context
{auto-generated from repo analysis}
```

**Where to write:** `~/.bonsai/projects/{slug}/.bonsai/SOUL.md`

---

## 4. Communication Model

### 4.1 Comments on Tickets

All agent-human communication happens via comments on tickets. There is no chat interface, no DM system, and no channel integration.

**Comment structure:**
```typescript
interface TicketComment {
  id: string;              // "cmt_abc123"
  ticketId: string;        // "tkt_001"
  author: "human" | "agent";
  content: string;         // Markdown content
  createdAt: string;       // ISO timestamp
  metadata?: {
    runId?: string;        // Which heartbeat run created this
    model?: string;        // Which model was used
    tokens?: number;       // Total tokens used
  };
}
```

**How it works:**
1. Human creates a ticket in the web app
2. On next heartbeat, agent picks up the ticket
3. Agent works the ticket, posting comments as it goes (progress, questions, results)
4. When done, agent pushes ticket to "verification" state and posts a summary comment
5. Human reviews in the web app, posts response comments if needed
6. On next heartbeat, agent sees new comments and responds

### 4.2 Ticket States

| State | Who Sets It | Meaning |
|-------|------------|---------|
| `backlog` | Human | Ticket created, not yet assigned |
| `ready` | Human/Agent | Ticket ready for agent to pick up |
| `in-progress` | Agent | Agent is actively working on it |
| `verification` | Agent | Agent completed work, awaiting human review |
| `needs-info` | Agent | Agent has a question, waiting for human response |
| `done` | Human | Human verified, work is complete |

---

## 5. Complete Bonsai Operations Map

### Project Creation

| Step | Bonsai Action | Method |
|------|--------------|--------|
| 1 | Clone repo | `git clone` into `~/.bonsai/projects/{slug}` |
| 2 | Analyze repo | Read files, detect language/framework |
| 3 | Create project record | Insert into SQLite `projects` table |
| 4 | Copy persona files | Copy from `~/.bonsai/personas/{persona}/` to workspace |
| 5 | Write SOUL.md | Generate project-scoped persona file |
| 6 | Write MEMORY.md | Seed with project documentation |
| 7 | Create sessions dir | `mkdir ~/.bonsai/sessions/{projectId}/` |

### Agent Run (Heartbeat)

| Step | Bonsai Action | Method |
|------|--------------|--------|
| 1 | Heartbeat fires | `cron`/`launchd` runs `bonsai heartbeat` |
| 2 | Read pending tickets | Query SQLite for tickets in `ready`/`needs-info` state with new comments |
| 3 | For each ticket | Load project, persona, bootstrap files |
| 4 | Build system prompt | Persona + project context + ticket + recent comments |
| 5 | Run AgentRunner | In-process LLM conversation loop |
| 6 | Execute tools | ToolExecutor runs in Docker container |
| 7 | Write results | Post comments on ticket via SQLite insert |
| 8 | Update ticket state | Set to `verification`, `needs-info`, or keep `in-progress` |
| 9 | Save session | Write transcript to `~/.bonsai/sessions/{projectId}/{ticketId}.jsonl` |
| 10 | Exit | Heartbeat process terminates |

### Managing Sessions

| Operation | Method |
|-----------|--------|
| List project sessions | `loadSessionStore(~/.bonsai/sessions/{projectId}/sessions.json)` |
| Get transcript | Read `~/.bonsai/sessions/{projectId}/{ticketId}.jsonl` |
| Delete session | Remove from store + archive transcript file |
| Compact session | Trim transcript lines, update compaction count |

### Project Deletion

| Step | Bonsai Action | Method |
|------|--------------|--------|
| 1 | Remove project | Delete from SQLite `projects` table |
| 2 | Remove tickets | Delete from SQLite `tickets` table |
| 3 | Remove comments | Delete from SQLite `comments` table |
| 4 | Clean up workspace | `~/.bonsai/projects/{slug}/` to OS trash |
| 5 | Clean up sessions | `~/.bonsai/sessions/{projectId}/` to OS trash |
| 6 | Clean up memory | `~/.bonsai/memory/{projectId}.sqlite` to OS trash |

---

## 6. Multi-Agent Per Project

A single Bonsai project can have multiple personas assigned for different roles:

```json
{
  "id": "proj_abc123",
  "name": "My App",
  "personas": ["developer", "reviewer"]
}
```

**Key behavior:**
- Both personas share the same workspace (same repo)
- Each gets **separate** sessions and memory per ticket
- Different tool profiles enforce role separation (developer can write, reviewer is read-only)
- The heartbeat scheduler decides which persona to dispatch based on ticket state and type

**Subagent isolation:** When an agent spawns subagents, only `AGENTS.md` and `TOOLS.md` are loaded. The subagent does **not** inherit `SOUL.md` or `MEMORY.md`, preventing personality pollution.

Extraction origin: `src/agents/workspace.ts:280-288` (filterBootstrapFilesForSession, SUBAGENT_BOOTSTRAP_ALLOWLIST)

---

## 7. Authorization and Scopes

Since Bonsai is a local application with no external gateway, authorization is simpler:

| Scope | Who | Access |
|-------|-----|--------|
| Web app | Human (local browser) | Full read/write to all projects, tickets, settings |
| Heartbeat | System (cron/launchd) | Full read/write to SQLite + filesystem |
| API routes | Web app | Authenticated via session cookie (local only) |

**API key management:**
- LLM API keys (Anthropic, OpenAI, etc.) are stored in `~/.bonsai/vault.age` (encrypted)
- GitHub tokens are stored in the vault
- Keys are decrypted at heartbeat runtime and passed to the AgentRunner

There is no multi-user authentication in v1 — Bonsai is a single-user local application.

---

## 8. Cross-References

- **Doc 01 (Project Isolation)** — isolation boundaries, per-project config, filesystem layout
- **Doc 02 (Technical Architecture)** — overall architecture, tech stack, abstraction boundaries
- **Doc 05 (Onboarding)** — first-run wizard, project creation wizard
- **Doc 06 (Work Scheduler)** — ticket prioritization, heartbeat scheduling
- **Doc 08 (Git Operations)** — automated git workflows
- **Doc 09 (Personas)** — persona system, SOUL.md templates, project manager
- **Doc 13 (Agent Runtime)** — AgentRunner abstraction, heartbeat model, in-process execution
- **Doc 14 (Tool System)** — ToolExecutor abstraction, Docker sandbox, tool policies
- **Doc 15 (Agent Teams)** — multi-persona collaboration, team sessions, inter-agent messaging
