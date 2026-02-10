# Project-Level Isolation Architecture

Date: 2026-02-04

> **Architecture note:** Bonsai is a standalone application. There is no OpenClaw Gateway, no WebSocket RPC, no channel adapters, and no `openclaw.json`. Agents run in-process via a heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, which reads SQLite, runs agents, writes results, and exits. All agent-human communication happens via comments on tickets. The web app (Next.js) is the full UI. All data lives in `~/.bonsai/`.

## Summary

Bonsai provides per-project isolation through extracted agent infrastructure and per-project Docker containers. Each project gets its own container (isolated filesystem), its own persona (SOUL.md), and one or more agents dispatched by Bonsai's heartbeat scheduler. All Bonsai data lives in `~/.bonsai/`.

This document covers the isolation boundaries, what each project gets, and the isolation model. References to OpenClaw source paths indicate where code was originally extracted from — OpenClaw is not a runtime dependency.

---

## Decision: Single Installation, Agent-Per-Project

### Why not separate installations?

- Duplicates auth profiles, plugin infrastructure, and scheduling N times
- No shared state — N processes on N ports
- Updates become N-fold, config drift inevitable
- The heartbeat scheduler is designed to multiplex agents; separate instances fight that design

### Why agent-per-project works

- Sessions, memory, workspaces, and auth are already isolated per agent
- Per-agent config overrides exist for models, tools, sandbox, and identity
- The only new concept needed is a "project" grouping above agents

---

## Existing Isolation Model (Extracted from OpenClaw)

The following isolation model was extracted from OpenClaw's codebase. These boundaries are now owned by Bonsai and enforced directly — there is no external gateway or routing layer.

### Per-Agent (Already Isolated)

| Resource | Storage Path | Extraction Origin |
|----------|-------------|-------------------|
| Workspace directory | `~/.bonsai/projects/{projectSlug}/` | `src/agents/agent-scope.ts:146` |
| Sessions & history | `~/.bonsai/sessions/{projectId}/{ticketId}/` | `src/config/sessions/paths.ts:7-15` |
| Memory/vector index | `~/.bonsai/memory/{projectId}.sqlite` | `src/agents/memory-search.ts:104-106` |
| Auth credentials | `{agentDir}/auth-profiles.json` | `src/agents/auth-profiles/constants.ts:4` |
| System prompt | `SOUL.md` in workspace | `src/agents/workspace.ts:23` |
| Bootstrap files | `SOUL.md`, `MEMORY.md`/`memory.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md` | `src/agents/workspace.ts:22-30` |
| Model config | Per-project in SQLite | `src/config/types.agents.ts:26` |
| Tool policies | Per-project in SQLite | `src/config/types.agents.ts:62` |
| Sandbox config | Per-project in SQLite | `src/config/types.agents.ts:40-61` |
| Identity | Per-project in SQLite (name, avatar, emoji) | `src/config/types.agents.ts:32` |
| Memory search settings | Per-project in SQLite | `src/config/types.agents.ts:27` |
| Subagent permissions | Per-project in SQLite | `src/config/types.agents.ts:35` |
| Heartbeat schedule | Per-project in SQLite | `src/config/types.agents.ts:31` |
| Context pruning | Global defaults in config | `src/config/types.agent-defaults.ts:130` |
| Compaction settings | Global defaults in config | `src/config/types.agent-defaults.ts:132` |

### Session Key Format

Sessions embed the project and ticket ID, preventing cross-project leakage:

```
bonsai:{projectId}:ticket:{ticketId}
```

Examples:
- `bonsai:proj_abc123:ticket:tkt_001`
- `bonsai:proj_def456:ticket:tkt_042`

Extraction origin: `src/routing/session-key.ts:135-138`

### Memory Cache Key

Memory manager caches are keyed per-project:

```
{projectId}:{workspaceDir}:{settingsFingerprint}
```

Two projects with identical settings still maintain independent memory indices.

Extraction origin: `src/memory/manager-cache-key.ts:54`

---

### Global/Shared (Not Per-Project)

| Resource | Location | Notes |
|----------|----------|-------|
| Config file | `~/.bonsai/config.json` | Global Bonsai settings |
| SQLite database | `~/.bonsai/bonsai.db` | Projects, tickets, metadata |
| Personas | `~/.bonsai/personas/` | Shared persona templates |
| Auth credentials | `~/.bonsai/vault.age` | Encrypted secrets (API keys, tokens) |
| Model catalog | Global defaults in config | Shared definitions |
| Browser infrastructure | Shared Playwright instance | If applicable |

---

## Bonsai Architecture

### Conceptual Model

```
┌─────────────────────────────────────────────────────────────────┐
│                       Bonsai Developer OS                        │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            Web App (Next.js — full UI)                   │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │   │
│  │  │ Project A │  │ Project B │  │ Project C │  ...       │   │
│  │  │  Tickets  │  │  Tickets  │  │  Tickets  │            │   │
│  │  └──────────┘  └──────────┘  └──────────┘             │   │
│  │                                                         │   │
│  │  Settings │ Onboarding │ Personas │ Docs                │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │ reads/writes                        │
│                           ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   SQLite (bonsai.db)                      │   │
│  │  Projects │ Tickets │ Comments │ Sessions │ Settings      │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │ reads/writes                        │
│                           ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Heartbeat (cron/launchd)                      │   │
│  │  `bonsai heartbeat` — runs periodically                   │   │
│  │                                                           │   │
│  │  1. Read SQLite for pending tickets                       │   │
│  │  2. For each ticket needing work:                         │   │
│  │     → Resolve persona (SOUL.md) + project context         │   │
│  │     → AgentRunner executes in-process                     │   │
│  │     → ToolExecutor runs tools in Docker container         │   │
│  │     → Results written as comments on ticket               │   │
│  │  3. Push to verification, update ticket state             │   │
│  │  4. Exit                                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Filesystem                              │   │
│  │  ~/.bonsai/                                                │   │
│  │  ├── projects/          # Cloned repos + .bonsai/ folders │   │
│  │  ├── personas/          # Persona templates (SOUL.md etc) │   │
│  │  ├── sessions/          # Session transcripts              │   │
│  │  ├── memory/            # Vector indexes per project       │   │
│  │  ├── config.json        # Global settings                  │   │
│  │  ├── bonsai.db          # SQLite database                  │   │
│  │  └── vault.age          # Encrypted secrets                │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Key points:**
- Personas are system-level at `~/.bonsai/personas/` — NOT copied to projects
- Projects reference a persona by name in their SQLite record
- At runtime, the heartbeat loads persona files and injects project/ticket context
- All agent-human communication is via comments on tickets — no chat interface, no channels
- Two data layers: SQLite (structured state) + filesystem (content/artifacts/repos/sessions)

### Per-Project Config

Projects have minimal config — just metadata and a persona reference:

```
~/.bonsai/projects/frontend-app/.bonsai/
├── project.json         # Project metadata + persona reference
└── tickets/             # Ticket files
```

**project.json:**
```json
{
  "id": "proj_abc123",
  "name": "Frontend App",
  "slug": "frontend-app",
  "persona": "developer",
  "repo": {
    "url": "https://github.com/org/frontend-app",
    "defaultBranch": "main"
  },
  "created": "2026-02-04T10:00:00Z"
}
```

All persona files (SOUL.md, MEMORY.md, TOOLS.md, etc.) are loaded from `~/.bonsai/personas/{persona}/` at runtime.

### Project Manager Persona

Bonsai creates a special **project manager** persona that serves as the top-level scheduler/orchestrator. This persona:

- Runs the work scheduler (see doc 06)
- Assigns tickets to appropriate personas
- Spins up other personas when tickets need work
- Coordinates across all projects

See **doc 09 (Personas)** for full details on the persona system including the project manager.

---

## Onboarding Flow (Web Wizard)

### First Run: Global Setup

Simplified web-based wizard (see doc 05 for full details):

1. **Claude Authentication** — Session ID or API key
2. **GitHub Token** — For cloning repos
3. **Health Check** — Verify heartbeat scheduler is configured
4. **Project Manager Created** — Special orchestrator persona

**Note:** No channel setup. No gateway. All human-agent communication happens through comments on tickets in the Bonsai web UI.

### Per-Project: New Project Wizard

1. **Repository Selection**
   - Existing: search your repos or paste URL
   - New: create via GitHub API
2. **Project Configuration**
   - Display name, persona choice
3. **Clone & Setup**
   - `git clone` into `~/.bonsai/projects/{name}`
   - Create project record in SQLite + project.json with persona reference
4. **Project Board Ready**
   - Open project board in Bonsai web app
   - Create tickets, agent works them autonomously via heartbeat

---

## What Bonsai Manages

### Bonsai Mount (~/.bonsai/)

Bonsai manages its own filesystem mount:

```
~/.bonsai/
├── personas/           # Agent templates (SOUL.md, MEMORY.md, etc.)
├── projects/           # Cloned repos with .bonsai/ folders
├── sessions/           # Session transcripts per project/ticket
├── memory/             # Vector indexes per project
├── config.json         # Bonsai settings
├── bonsai.db           # SQLite (projects, tickets, comments, metadata)
├── vault.age           # Encrypted secrets
└── vault-key.txt       # Age private key
```

### Per-Project Files

Each project has a `.bonsai/` folder:

```
~/.bonsai/projects/{slug}/.bonsai/
├── SOUL.md             # Agent persona (copied from template)
├── MEMORY.md           # Project knowledge
├── settings.json       # Model, tools, behavior
├── project.json        # Project metadata
└── tickets/            # Ticket files
```

### Abstraction Boundaries

Bonsai uses three abstraction layers designed for future containerization:

| Layer | Responsibility | Future |
|-------|---------------|--------|
| **ToolExecutor** | Runs tools (bash, file ops, git) inside Docker containers | Can swap to remote container orchestration |
| **WorkspaceProvider** | Manages project filesystems, git worktrees | Can swap to cloud-hosted workspaces |
| **AgentRunner** | LLM conversation loop, tool dispatch, context management | Can swap to distributed agent pools |

See **doc 13 (Agent Runtime)** and **doc 14 (Tool System)** for details on these boundaries.

---

## Gaps and Design Decisions

### 1. Project Grouping

The extracted agent model is flat — no concept of "this agent belongs to project X." Bonsai maintains project-to-persona mapping in its own SQLite database (`~/.bonsai/bonsai.db`).

### 2. Communication Model

All agent-human communication happens through comments on tickets. Agents are autonomous: they pick tickets, work them, and communicate progress/questions via comments. Humans review and respond through the web app. There is no chat interface, no DM system, and no channel integration.

### 3. Heartbeat Scheduling

The heartbeat model means agents are not persistent processes. `cron`/`launchd` fires `bonsai heartbeat` periodically. The heartbeat reads pending work from SQLite, runs agents in-process, writes results, and exits. Bonsai's work scheduler (doc 06) limits concurrent agents based on available resources.

### 4. No Channel Integration

Bonsai does not set up Discord/Slack/Telegram. All communication is through the web app and ticket comments.

**Future:** Channel support may be added later for notifications only.

---

## Key Code References (Extraction Origins)

These references point to OpenClaw source files from which Bonsai's agent infrastructure was extracted:

| Area | File | Line Reference |
|------|------|---------------|
| Agent config schema | `src/config/zod-schema.agents.ts` | Agent list + per-agent overrides |
| Agent defaults schema | `src/config/types.agent-defaults.ts:1-263` | All per-agent default fields |
| Agent path resolution | `src/agents/agent-scope.ts:136-156` | Resolves config + paths per agent |
| Agent directory paths | `src/agents/agent-paths.ts:1-21` | Per-agent directory structure |
| Workspace management | `src/agents/workspace.ts:22-30,118-130` | Bootstrap files, `ensureAgentWorkspace()` |
| Session paths | `src/config/sessions/paths.ts:7-15,32-50` | Per-agent session storage |
| Session key format | `src/routing/session-key.ts:10,101-108,135-138` | Key builders |
| Memory manager | `src/memory/manager.ts` | Per-agent SQLite vector DB |
| Memory cache key | `src/memory/manager-cache-key.ts:54` | Includes agentId in cache |
| Auth profiles | `src/agents/auth-profiles/constants.ts:4` | `AUTH_PROFILE_FILENAME` |
| Identity system | `src/agents/identity.ts:1-86` | Per-agent name/avatar |
| Config loader | `src/config/io.ts:187-527` | `loadConfig`, `writeConfigFile`, `createConfigIO` |
| Full config schema | `src/config/zod-schema.ts` | ~1000 LOC, all settings |

---

## Summary

Bonsai is a standalone application that extracts agent infrastructure from OpenClaw and runs it independently via a heartbeat model. There is no Gateway, no WebSocket RPC, no channels, and no chat interface.

Key principles:
1. Bonsai manages `~/.bonsai/` mount — all state is local
2. Two data layers: SQLite (structured state) + filesystem (content/artifacts/repos/sessions)
3. Heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, agents run in-process
4. Each project gets its own `.bonsai/` folder with persona files
5. SOUL.md scopes the agent's behavior to that project only
6. All agent-human communication happens via comments on tickets
7. Web app (Next.js) is the full UI for everything
8. ToolExecutor/WorkspaceProvider/AgentRunner abstraction boundaries for future containerization
9. Git operations are automated (see doc 08)
