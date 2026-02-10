# Bonsai Developer OS — Technical Architecture

Date: 2026-02-04

> **Architecture note:** Bonsai is a standalone application. There is no OpenClaw Gateway, no WebSocket RPC, no channel adapters, and no `openclaw.json`. Agents run in-process via a heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, which reads SQLite, runs agents, writes results, and exits. All agent-human communication happens via comments on tickets. The web app (Next.js) is the full UI. All data lives in `~/.bonsai/`.

## Executive Summary

Bonsai Developer OS is a standalone application that provides per-project agent isolation, a web-based UI, and a non-programmer-friendly onboarding experience. Bonsai extracts its agent infrastructure from OpenClaw's codebase — the agent runner, tool system, Docker sandbox, session management, and system prompt builder. OpenClaw is **not a runtime dependency**; Bonsai owns all extracted code and evolves it independently.

**Key principle:** Bonsai is self-contained. All data lives in `~/.bonsai/`. Agents run in per-project Docker containers with workspace-scoped tools. The LLM conversation runs in Bonsai's process; tool execution (bash, file ops, git) runs inside the project's container.

**Key decision:** Extract from OpenClaw, don't wrap it. Each project has a **persona** (SOUL.md, settings), a **Docker container** (isolated dev environment), and one or more **agents** dispatched by Bonsai's heartbeat scheduler.

> **Lineage:** Bonsai's agent runner, tool system, and sandbox are derived from OpenClaw (MIT licensed). See `AGENT_EXTRACT_TODO.md` for the full extraction plan and source mapping.

---

## 1. Extracted Architecture

### What Bonsai Extracts from OpenClaw

Bonsai takes ownership of these components from OpenClaw's codebase:

| Component | Purpose | OpenClaw Origin |
|-----------|---------|----------------|
| Agent Runner | LLM conversation loop, tool dispatch, context management | `src/agents/pi-embedded-runner/` |
| Tool System | Bash execution, file read/write/edit, web search | `src/agents/pi-tools.ts`, `src/agents/bash-tools.*` |
| Docker Sandbox | Per-project container isolation, sandboxed tool execution | `src/agents/sandbox/` |
| System Prompt Builder | Constructs LLM prompt from persona, tools, context | `src/agents/system-prompt.ts` |
| Session Management | Transcripts, session state, session keys | `src/config/sessions/`, `src/routing/session-key.ts` |
| Tool Policy | Allow/deny lists, tool profiles per agent | `src/agents/tool-policy.ts` |
| Agent Events | Activity monitoring, run tracking | `src/infra/agent-events.ts` |
| Auth Profiles | API key storage, rotation, model resolution | `src/agents/auth-profiles/` |

### What Bonsai Does NOT Take

- Channel adapters (Telegram, Discord, Slack, etc.)
- CLI command framework
- Gateway server (Bonsai has its own Next.js app)
- Plugin/extension system
- Media pipeline, voice handling
- WebSocket RPC protocol
- Routing/bindings system

### Upstream Dependencies

Bonsai depends on these packages (same as OpenClaw uses):

| Package | Role |
|---------|------|
| `@mariozechner/pi-coding-agent` | Session manager, tool dispatch, context compaction |
| `@mariozechner/pi-ai` | LLM provider abstraction (Anthropic, OpenAI, etc.) |
| `@anthropic-ai/sdk` | Anthropic API client |

### How an Agent Runs in Bonsai

1. **Heartbeat** fires via `cron`/`launchd` — runs `bonsai heartbeat`
2. **Heartbeat** reads SQLite for tickets in a workable state
3. **Heartbeat** resolves the project's persona (SOUL.md), Docker container, and worktree
4. **Heartbeat** builds the tool set — bash, file ops, git, all scoped to the project's container
5. **Heartbeat** constructs the system prompt with persona + project context + ticket description
6. **AgentRunner** (extracted from OpenClaw) handles the LLM conversation loop
7. **LLM calls** happen from Bonsai's process (host) using configured API keys
8. **ToolExecutor** runs tools (bash, file ops) inside the project's Docker container via `docker exec`
9. **Results** are written as comments on the ticket in SQLite
10. **Agent** pushes work to verification, updates ticket state, exits

There is no persistent agent process. The heartbeat runs, does work, and exits. See **doc 13 (Agent Runtime)** for the full AgentRunner abstraction.

---

## 2. Per-Project Isolation Model (Extraction Reference)

### What OpenClaw Already Isolates Per-Agent

Each agent in OpenClaw's original model gets the following isolation. Bonsai preserves these boundaries but maps them to projects instead of agents:

| Resource | Bonsai Path | Extraction Origin |
|----------|------------|-------------------|
| Workspace | `~/.bonsai/projects/{projectSlug}/` | `src/agents/agent-scope.ts:146` |
| Sessions | `~/.bonsai/sessions/{projectId}/{ticketId}/` | `src/config/sessions/paths.ts:7-15` |
| Memory DB | `~/.bonsai/memory/{projectId}.sqlite` | `src/agents/memory-search.ts:104-106` |
| Auth creds | `{agentDir}/auth-profiles.json` | `src/agents/auth-profiles/constants.ts:4` |
| System prompt | `SOUL.md` in workspace | `src/agents/workspace.ts:23` |
| Bootstrap files | `MEMORY.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md` | `src/agents/workspace.ts:22-30` |
| Model config | Per-project in SQLite | `src/config/types.agents.ts:26` |
| Tool policies | Per-project in SQLite | `src/config/types.agents.ts:62` |
| Sandbox | Per-project in SQLite | `src/config/types.agents.ts:40-61` |
| Identity | Per-project in SQLite (name, avatar, emoji) | `src/config/types.agents.ts:32` |
| Memory search | Per-project in SQLite | `src/config/types.agents.ts:27` |
| Subagents | Per-project in SQLite | `src/config/types.agents.ts:35` |
| Heartbeat | Per-project in SQLite | `src/config/types.agents.ts:31` |

**Session keys embed the project and ticket ID** preventing cross-project session leakage:
```
bonsai:{projectId}:ticket:{ticketId}
```

**Memory cache keys** include the project ID:
```
{projectId}:{workspaceDir}:{settingsFingerprint}
```

### What's Global

| Resource | Notes |
|----------|-------|
| Config file | `~/.bonsai/config.json` — global Bonsai settings |
| SQLite database | `~/.bonsai/bonsai.db` — projects, tickets, comments |
| Personas | `~/.bonsai/personas/` — shared persona templates |
| Auth credentials | `~/.bonsai/vault.age` — encrypted secrets |
| Model catalog | Global defaults in config |

---

## 3. Bonsai Architecture

### Conceptual Model

```
┌─────────────────────────────────────────────────────────────────┐
│                       Bonsai Developer OS                        │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │           Web App (Next.js — full UI)                    │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │   │
│  │  │ Project A │  │ Project B │  │ Project C │  ...       │   │
│  │  │  Tickets  │  │  Tickets  │  │  Tickets  │            │   │
│  │  │  Comments │  │  Comments │  │  Comments │            │   │
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
│  │                                                           │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │   │
│  │  │ AgentRunner   │  │ ToolExecutor  │  │ Workspace     │  │   │
│  │  │ (LLM loop)   │  │ (Docker exec) │  │ Provider      │  │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  │   │
│  │                                                           │   │
│  │  Reads tickets → runs agents → writes comments → exits    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Filesystem (~/.bonsai/)                 │   │
│  │  projects/ │ personas/ │ sessions/ │ memory/ │ config     │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Data Model

Bonsai stores all structured state in SQLite (`~/.bonsai/bonsai.db`):

```typescript
interface BonsaiProject {
  id: string;                    // "proj_abc123"
  name: string;                  // "Frontend App"
  slug: string;                  // "frontend-app"
  githubRepo: string;            // "org/frontend-app"
  localPath: string;             // "~/.bonsai/projects/frontend-app"
  defaultBranch: string;         // "main"
  language: string;              // "typescript"
  persona: string;               // "developer"
  createdAt: string;
  settings: {
    model?: string;              // Override per-project
    toolProfile?: string;        // "developer" | "read-only" | custom
    sandbox?: string;            // "docker" | "none"
  };
}

interface BonsaiPersona {
  id: string;                    // "developer"
  name: string;                  // "Developer"
  role: string;                  // "Software development agent"
  model: string;                 // Preferred model
  soulTemplate: string;          // Path to SOUL.md template
}
```

---

## 4. Web App (Next.js)

The web app is the **full UI** for Bonsai. It is a Next.js application that handles:

- **Dashboard** — overview of all projects, recent ticket activity
- **Project boards** — per-project ticket management with columns (backlog, in-progress, verification, done)
- **Ticket detail** — view ticket, read agent comments, post human comments
- **Settings** — global Bonsai config, API keys, model selection, heartbeat schedule
- **Onboarding** — first-run wizard for auth + GitHub + first project (see doc 05)
- **Personas** — create/edit persona templates (SOUL.md, tools, model defaults)
- **Docs** — embedded documentation / knowledge base

There is no separate Gateway UI, no WebSocket connection to an external process, and no chat interface. All agent-human communication happens through comments on tickets.

### API Layer

The Next.js app provides API routes that read/write SQLite directly:

| Route | Purpose |
|-------|---------|
| `GET/POST /api/projects` | CRUD for projects |
| `GET/POST /api/projects/[id]/tickets` | CRUD for tickets within a project |
| `GET/POST /api/tickets/[id]/comments` | Read/post comments on a ticket |
| `GET/PUT /api/settings` | Global settings |
| `GET/POST /api/personas` | Persona management |
| `POST /api/heartbeat/trigger` | Manually trigger a heartbeat run |

---

## 5. Onboarding

See **doc 05 (Onboarding)** for the full onboarding wizard specification. The key simplifications from OpenClaw's TUI wizard:

- No gateway setup (no port, bind, auth token)
- No channel setup (no Discord/Slack/Telegram)
- No DM policy configuration
- No skills/hooks on first run
- Auto-install heartbeat scheduler (launchd on macOS, systemd on Linux)
- "Sign in with Claude" instead of choosing provider/profile

---

## 6. Persona System

Each persona defines agent behavior, tools, and model preferences. Personas are stored as templates at `~/.bonsai/personas/{id}/` and referenced by projects.

### Persona Files

```
~/.bonsai/personas/developer/
├── SOUL.md             # Agent persona and behavior instructions
├── MEMORY.md           # Default knowledge base (optional)
├── TOOLS.md            # Tool usage guidance (optional)
└── settings.json       # Model, tool profile, sandbox defaults
```

### SOUL.md per Persona

**Developer persona:**
```markdown
You are a developer working on the {project-name} repository.

Repository: {github-url}
Language: {detected-language}
Branch: {default-branch}

## Rules
- Only make changes within this repository
- Follow the project's existing code style and conventions
- Run tests before committing
- Create focused, well-described commits
- Communicate progress and questions via ticket comments
- Do NOT access files outside this repository
```

**Reviewer persona:**
```markdown
You are a code reviewer for the {project-name} repository.

## Rules
- Review PRs for correctness, style, and test coverage
- Post review comments on the ticket
- Do NOT modify code directly — suggest changes via comments
```

### settings.json per Persona

```json
{
  "model": { "primary": "claude-sonnet-4-20250514" },
  "tools": {
    "profile": "developer",
    "alsoAllow": [],
    "alsoDeny": []
  },
  "sandbox": { "type": "docker" },
  "memorySearch": { "enabled": true }
}
```

---

## 7. Technology Stack

### Core Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | TypeScript (ESM) | Strict mode, Node 22+ |
| Runtime | Node 22+ (Bun for dev) | Same compatibility as OpenClaw |
| Web framework | Next.js 15 | Full UI + API routes |
| Database | SQLite (node:sqlite) + sqlite-vec | Structured state + vector search |
| Validation | Zod 4 | Config and form validation |
| Logging | tslog | Subsystem-based logging |
| Testing | Vitest | 70% coverage thresholds |
| Linting | oxlint | Type-aware |
| Formatting | oxfmt | Consistent style |
| Build | tsc (backend), Next.js (frontend) | Output to `dist/` |
| Package manager | pnpm 10 | Workspace support |
| CLI | Commander 14 | `bonsai heartbeat`, `bonsai setup`, etc. |

### Patterns to Adopt

- **Dependency injection** via `createDefaultDeps()` — typed object, not IoC container
- **Config schema** via Zod with typed config objects
- **Structured logging** with subsystem prefixes: `"bonsai:projects: message"`
- **Files under 500 LOC** — extract helpers, don't create "V2" copies
- **Strict TypeScript** — no `any`, explicit type exports
- **Abstraction boundaries** — ToolExecutor, WorkspaceProvider, AgentRunner are interfaces for future containerization

### Bonsai Project Structure

```
bonsai/
├── package.json
├── tsconfig.json
├── pnpm-workspace.yaml
├── src/
│   ├── index.ts                    # Main entry
│   ├── cli/                        # CLI commands
│   │   ├── program.ts              # Commander setup
│   │   ├── heartbeat.ts            # `bonsai heartbeat` command
│   │   └── setup.ts                # `bonsai setup` command
│   ├── agent/                      # Extracted agent infrastructure
│   │   ├── runner.ts               # AgentRunner — LLM conversation loop
│   │   ├── tool-executor.ts        # ToolExecutor — runs tools in Docker
│   │   ├── workspace-provider.ts   # WorkspaceProvider — manages filesystems
│   │   ├── system-prompt.ts        # System prompt builder
│   │   ├── session.ts              # Session management
│   │   └── tool-policy.ts          # Tool allow/deny lists
│   ├── heartbeat/                  # Heartbeat scheduler
│   │   ├── scheduler.ts            # Reads SQLite, dispatches agent runs
│   │   ├── ticket-picker.ts        # Selects tickets needing work
│   │   └── result-writer.ts        # Writes comments back to tickets
│   ├── projects/                   # Project management
│   │   ├── create.ts               # Project creation wizard logic
│   │   ├── clone.ts                # Git clone + repo analysis
│   │   └── soul-generator.ts       # SOUL.md template generation
│   ├── personas/                   # Persona management
│   │   ├── create.ts
│   │   └── templates.ts
│   ├── config/                     # Bonsai's own config
│   │   ├── schema.ts               # Zod schema for ~/.bonsai/config.json
│   │   └── paths.ts                # Bonsai state paths
│   ├── db/                         # Database layer
│   │   ├── sqlite.ts               # SQLite setup + migrations
│   │   ├── projects.ts             # Project CRUD
│   │   ├── tickets.ts              # Ticket CRUD
│   │   └── comments.ts             # Comment CRUD
│   └── onboarding/                 # Web onboarding wizard
│       ├── global-setup.ts         # First-run global config
│       └── project-setup.ts        # Per-project wizard
├── app/                            # Next.js web app
│   ├── layout.tsx
│   ├── page.tsx                    # Dashboard
│   ├── projects/
│   │   └── [id]/
│   │       ├── page.tsx            # Project board
│   │       └── tickets/[tid]/
│   │           └── page.tsx        # Ticket detail + comments
│   ├── settings/
│   │   └── page.tsx                # Global settings
│   ├── personas/
│   │   └── page.tsx                # Persona manager
│   ├── onboarding/
│   │   └── page.tsx                # Setup wizard
│   └── api/                        # API routes
│       ├── projects/
│       ├── tickets/
│       ├── comments/
│       ├── settings/
│       └── heartbeat/
└── test/
```

---

## 8. Abstraction Boundaries

Bonsai defines three key abstraction interfaces designed for future containerization and scaling:

### ToolExecutor

Runs tools (bash, file ops, git) inside Docker containers scoped to a project.

```typescript
interface ToolExecutor {
  execute(tool: ToolCall, context: ProjectContext): Promise<ToolResult>;
  // Currently: `docker exec` into project container
  // Future: remote container orchestration (Kubernetes, cloud VMs)
}
```

### WorkspaceProvider

Manages project filesystems, git worktrees, and file access.

```typescript
interface WorkspaceProvider {
  getWorkspace(projectId: string): Promise<Workspace>;
  createWorktree(projectId: string, branch: string): Promise<string>;
  // Currently: local filesystem at ~/.bonsai/projects/
  // Future: cloud-hosted workspaces, remote filesystems
}
```

### AgentRunner

Handles the LLM conversation loop, tool dispatch, and context management.

```typescript
interface AgentRunner {
  run(ticket: Ticket, context: RunContext): Promise<RunResult>;
  // Currently: in-process, extracted from OpenClaw's pi-embedded-runner
  // Future: distributed agent pools, queued execution
}
```

See **doc 13 (Agent Runtime)** for the full AgentRunner specification and **doc 14 (Tool System)** for the ToolExecutor specification.

---

## 9. Integration Seams (Bonsai-Native Operations)

Everything Bonsai does is through its own database and filesystem — no external process communication:

| What Bonsai Does | How |
|-----------------|-----|
| Create project | Insert into SQLite + `git clone` into `~/.bonsai/projects/{name}` |
| Delete project | Remove from SQLite + workspace to OS trash |
| Set project persona | Update SQLite record, copy persona files to workspace |
| Set project model | Update SQLite record |
| Set project tools | Update SQLite record |
| Create SOUL.md | Write file to project workspace directory |
| Create MEMORY.md | Write file to project workspace directory |
| Run agent on ticket | Heartbeat reads ticket, calls AgentRunner in-process |
| Post comment | Insert comment into SQLite, agent reads on next run |
| List sessions | Query SQLite for sessions by project/ticket |
| Health check | Verify heartbeat scheduler is running (launchd/cron) |
| Read config | Load `~/.bonsai/config.json` |
| Write config | Write JSON to `~/.bonsai/config.json` |

---

## 10. Gaps and Considerations

### What Bonsai Must Build (Not in OpenClaw)

1. **Heartbeat scheduler** — cron/launchd integration, ticket picker, result writer
2. **Project data model** — project-to-persona mapping, GitHub metadata, board state in SQLite
3. **Ticket/comment system** — ticket CRUD, comment threads, agent-human communication
4. **Web app** — Next.js dashboard, project boards, ticket views, settings, onboarding
5. **Persona system** — persona templates, role definitions, SOUL.md generation
6. **GitHub integration** — token management, repo creation, PR workflows
7. **Non-programmer UX** — simplified tool permissions, security defaults, guided setup
8. **ToolExecutor/WorkspaceProvider/AgentRunner interfaces** — abstraction boundaries for containerization

### No Channel Integration

Bonsai does not integrate with Discord, Slack, Telegram, or any messaging platform. All agent-human communication is through comments on tickets in the web app.

**Future:** Channel support may be added for notifications only.

### Heartbeat is Not Real-Time

The heartbeat model means agents do not respond instantly. There is latency between a human posting a comment and the agent seeing it on the next heartbeat. This is by design — agents are autonomous workers, not chat assistants.

**Mitigation:** The web app can trigger a manual heartbeat via `POST /api/heartbeat/trigger` for cases where the user wants immediate agent attention.

---

## 11. Key OpenClaw Code References (Extraction Origins)

These references point to OpenClaw source files from which Bonsai's agent infrastructure was extracted:

| Area | File | What's There |
|------|------|-------------|
| Config schema (full) | `src/config/zod-schema.ts` | ~1000 LOC, all settings |
| Agent config types | `src/config/types.agents.ts:26-62` | Per-agent fields |
| Agent defaults | `src/config/types.agent-defaults.ts:1-263` | All per-agent defaults |
| Agent paths | `src/agents/agent-paths.ts:1-21` | Per-agent directory structure |
| Agent scope resolution | `src/agents/agent-scope.ts:136-156` | Config + path resolution |
| Workspace bootstrap | `src/agents/workspace.ts:22-30,118-130` | SOUL.md, `ensureAgentWorkspace()` |
| Session paths | `src/config/sessions/paths.ts:7-15,32-50` | Per-agent session storage |
| Session key format | `src/routing/session-key.ts:10,101-108,135-138` | Key builders |
| Memory manager | `src/memory/manager.ts` | Per-agent SQLite vector DB |
| Memory cache key | `src/memory/manager-cache-key.ts:54` | Includes agentId |
| Auth profiles | `src/agents/auth-profiles/constants.ts:4` | `AUTH_PROFILE_FILENAME` |
| Identity system | `src/agents/identity.ts:1-86` | Per-agent name/avatar |
| Config loading | `src/config/io.ts:187-527` | `loadConfig`, `writeConfigFile` |
| Config paths | `src/config/paths.ts:21,91-93,176` | State dir, config |

---

## 12. Summary

Bonsai Developer OS is a standalone application that extracts agent infrastructure from OpenClaw and runs it independently.

- Bonsai owns all agent infrastructure (runner, tools, sandbox, sessions)
- No Gateway, no WebSocket RPC, no channels, no chat interface
- Heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, agents run in-process, exit when done
- Two data layers: SQLite (structured state) + filesystem (content/artifacts/repos/sessions)
- Web app (Next.js) is the full UI for settings, projects, tickets, docs, onboarding
- All agent-human communication happens via comments on tickets
- ToolExecutor/WorkspaceProvider/AgentRunner abstraction boundaries for future containerization
- Each project maps to a persona with isolated workspace/sessions/memory
- Mirror OpenClaw's stack (TypeScript ESM, SQLite, Zod, Vitest, pnpm)
