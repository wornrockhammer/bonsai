# Bonsai — Agent Runtime Extraction

Date: 2026-02-04 (updated 2026-02-05)

Bonsai will build its agent runtime by extracting from existing open-source agent infrastructure. Two codebases are relevant: **NanoClaw** (preferred — small, clean, already uses Claude Agent SDK) and **OpenClaw** (large, comprehensive, more to extract from if needed).

---

## Architecture Decision

**Old model:** Bonsai wraps OpenClaw via Gateway RPC ("decoration pattern"). Requires OpenClaw installed.

**New model:** Bonsai extracts the agent runner, tool system, sandbox, and session management. No external runtime dependency. Bonsai is a standalone application.

**Why:** Full control over the agent interface — tool implementations, sandbox behavior, workspace isolation, system prompt construction. No version coupling to external releases.

---

## NanoClaw — Preferred Extraction Source

**Repo:** https://github.com/gavrielc/nanoclaw (MIT, 3,174 LOC total)

NanoClaw is a personal Claude assistant that runs agents in isolated containers. It solves many of the same problems Bonsai needs to solve, in a codebase small enough to understand in minutes. Uses Claude Agent SDK directly.

### Architecture

```
Input --> SQLite --> Polling loop --> Container (Claude Agent SDK) --> Response
```

Single Node.js process. Agents execute in ephemeral Linux containers (Apple Container on macOS, Docker on Linux). IPC via filesystem. No daemons, no queues.

### Key Files to Study/Extract

| File | Lines | What | Relevance to Bonsai |
|------|-------|------|-------------------|
| `src/container-runner.ts` | 489 | Spawns containers, builds mount configs, parses output | **Core** — container isolation for agent execution |
| `container/agent-runner/src/index.ts` | 289 | Agent runner using Claude Agent SDK `query()` | **Core** — reference for how to call Claude Agent SDK |
| `container/agent-runner/src/ipc-mcp.ts` | 321 | MCP server inside container for IPC tools | **Useful** — agent-to-host communication pattern |
| `src/task-scheduler.ts` | 178 | Cron/interval/once task execution | **Useful** — maps to Bonsai's heartbeat scheduler |
| `src/mount-security.ts` | 413 | Validates mounts against external allowlist | **Useful** — filesystem security model |
| `src/db.ts` | 396 | SQLite operations (better-sqlite3) | **Reference** — same DB tech as Bonsai |
| `src/index.ts` | 848 | Main app, message routing, IPC watcher | **Study** — overall architecture pattern |
| `src/config.ts` | 47 | Configuration constants | **Reference** |
| `src/types.ts` | 79 | TypeScript interfaces | **Reference** |

### Key Patterns Worth Adopting

1. **Claude Agent SDK integration** — Uses `@anthropic-ai/claude-agent-sdk` with `query()`, allowed tools (Bash, Read, Write, Edit, Glob, Grep, WebSearch, WebFetch), session resumption, custom MCP servers, and hooks. Runs with `permissionMode: 'bypassPermissions'`.

2. **Container isolation** — Each agent invocation gets a fresh ephemeral container. Security boundary is filesystem mounts — agents can only access what's explicitly mounted. Mount allowlist stored at `~/.config/nanoclaw/mount-allowlist.json` (outside project root, never mounted into containers — agents can't modify their own security config).

3. **Filesystem-based IPC** — Agents write JSON files to `/workspace/ipc/messages/` and `/workspace/ipc/tasks/`. Host polls every 1 second. Atomic writes via temp-file-then-rename. Simple, no network complexity.

4. **Per-context memory** — Each context gets its own `CLAUDE.md` memory file the agent can read/update. Maps to Bonsai's per-project SOUL.md concept.

5. **Sentinel-based output parsing** — Container output bracketed with `---NANOCLAW_OUTPUT_START---` / `---NANOCLAW_OUTPUT_END---` for robust JSON extraction from stdout.

6. **Conversation archiving** — Uses Claude Agent SDK's `PreCompact` hook to archive transcripts before context compaction.

### NanoClaw Dependencies

| Package | Role |
|---------|------|
| `@anthropic-ai/claude-agent-sdk` (v0.2.29) | Agent execution inside containers |
| `better-sqlite3` | SQLite (same as Bonsai) |
| `cron-parser` | Scheduled task cron expressions |
| `pino` | Structured logging |
| `zod` v4 | Schema validation |

### What Bonsai Takes from NanoClaw vs Builds Itself

| Component | NanoClaw Has It | Bonsai Adapts |
|-----------|----------------|---------------|
| Container runner | Yes — Apple Container + Docker | Adapt for Bonsai workspace/project model |
| Claude Agent SDK integration | Yes — clean 289-line runner | Adapt with Bonsai-specific tools (ticket updates, board ops) |
| IPC system | Yes — filesystem-based | Adapt for Bonsai agent → webapp communication |
| Task scheduler | Yes — cron/interval/once | Replace with Bonsai's heartbeat model |
| Mount security | Yes — external allowlist | Adapt for per-project workspace isolation |
| WhatsApp I/O | Yes | **Skip** — Bonsai uses ticket comments, not chat |
| Per-group memory | Yes — CLAUDE.md per group | Adapt to per-project SOUL.md |
| Message polling loop | Yes — 2s poll on SQLite | Adapt to heartbeat trigger model |

---

## OpenClaw — Secondary Extraction Source

OpenClaw is a larger project (52+ modules, 45+ dependencies) with comprehensive agent infrastructure. Use as reference for anything NanoClaw doesn't cover.

**Repo:** https://github.com/openclaw/openclaw

---

## What to Extract (from OpenClaw, if needed)

### 1. Agent Runner (core)

The LLM conversation loop that sends messages, receives responses, executes tools, and manages context.

| Source | What | Why |
|--------|------|-----|
| `src/agents/pi-embedded-runner/run.ts` | `runEmbeddedPiAgent()` — main entry point | Heart of agent execution |
| `src/agents/pi-embedded-runner/run/attempt.ts` | `runEmbeddedAttempt()` — single attempt | Builds tools, prompt, runs session |
| `src/agents/pi-embedded-runner/run/params.ts` | `RunEmbeddedPiAgentParams` | Parameter types |
| `src/agents/pi-embedded-runner/types.ts` | `EmbeddedPiRunResult` | Result types |
| `src/agents/pi-embedded-runner/runs.ts` | Active run tracking | Concurrency control |

**Upstream dependency:** `@mariozechner/pi-coding-agent` (Pi SDK) — manages the LLM session, tool dispatch, context compaction. Need to evaluate whether to depend on this package or extract from it too.

### 2. Tool System

The tools agents use — bash execution, file operations, web search, etc.

| Source | What | Why |
|--------|------|-----|
| `src/agents/pi-tools.ts` | `createOpenClawCodingTools()` — tool assembly | Builds the full tool set |
| `src/agents/bash-tools.exec.ts` | Bash/exec tool — host and Docker modes | Core agent capability |
| `src/agents/bash-tools.shared.ts` | Docker exec argument builder | Sandbox execution |
| `src/agents/pi-tools.read.ts` | File read tool | Workspace file access |
| `src/agents/pi-tools.write.ts` | File write/edit tools | Workspace file modification |
| `src/agents/tool-policy.ts` | Tool profiles and allow/deny resolution | Controls what agents can do |

**Bonsai customizations needed:**
- Replace/restrict bash tool for workspace-scoped execution
- Add Bonsai-specific tools (ticket status updates, board operations, project queries)
- Remove tools Bonsai doesn't need (messaging, voice, channel tools)

### 3. Docker Sandbox

Per-project container isolation for agent tool execution.

| Source | What | Why |
|--------|------|-----|
| `src/agents/sandbox/types.ts` | Sandbox config types | Configuration surface |
| `src/agents/sandbox/docker.ts` | Container create/start/exec | Container lifecycle |
| `src/agents/sandbox/manage.ts` | `resolveSandboxContext()` | Sandbox resolution per run |
| `src/agents/sandbox/paths.ts` | Sandbox path validation | Prevents filesystem escape |
| `src/agents/sandbox/registry.ts` | Container tracking JSON | Persistent container state |
| `src/agents/sandbox/prune.ts` | Auto-cleanup of idle containers | Maintenance |

**Bonsai customizations needed:**
- Add "project" scope (today: session/agent/shared)
- Project-specific Docker images (repo + deps pre-installed)
- Worktree management inside containers
- Git operations inside containers

### 4. System Prompt Builder

Constructs the full system prompt from structured components.

| Source | What | Why |
|--------|------|-----|
| `src/agents/system-prompt.ts` | `buildAgentSystemPrompt()` | Prompt assembly (470 LOC) |
| `src/agents/bootstrap-files.ts` | `resolveBootstrapContextForRun()` | Loads SOUL.md, AGENTS.md, etc. |
| `src/agents/workspace.ts` | `loadWorkspaceBootstrapFiles()` | File loading from workspace |

**Bonsai customizations needed:**
- Inject persona content (SOUL.md) per agent without workspace file
- Add project/ticket context sections
- Remove sections Bonsai doesn't need (messaging, voice, channel-specific)

### 5. Session Management

Transcripts, session state, session keys.

| Source | What | Why |
|--------|------|-----|
| `src/routing/session-key.ts` | Session key building/parsing | Agent ID + session namespacing |
| `src/config/sessions/store.ts` | File-based session store with locking | Session persistence |
| `src/config/sessions/paths.ts` | Session path resolution | Per-agent storage layout |
| `src/config/sessions/transcript.ts` | Transcript append/read | Conversation history |
| `src/sessions/session-key-utils.ts` | Key parsing utilities | Pure functions |

**Bonsai customizations needed:**
- Store sessions in Bonsai's DB (Prisma/SQLite) instead of JSON files, or keep JSON files under `~/.bonsai/`
- Session key format: `agent:<worker>:bonsai:project:<projId>:ticket:<ticketId>`

### 6. Agent Events & Tracking

Event bus for monitoring agent activity.

| Source | What | Why |
|--------|------|-----|
| `src/infra/agent-events.ts` | `emitAgentEvent()`, `onAgentEvent()` | Agent activity monitoring |
| `src/infra/system-events.ts` | `enqueueSystemEvent()` | Inject context into agent prompts |
| `src/gateway/server-methods/agent-job.ts` | `waitForAgentJob()` | Run completion tracking |

### 7. LLM Provider Integration

Auth profiles, model resolution, API key management.

| Source | What | Why |
|--------|------|-----|
| `src/agents/auth-profiles/` | Auth profile management | API key storage and rotation |
| `src/agents/agent-scope.ts` | `resolveAgentModelPrimary()` | Model selection per agent |
| `src/config/types.agent-defaults.ts` | Model config types | Model/provider configuration |

**Upstream dependency:** `@mariozechner/pi-ai` — provider abstraction for Anthropic, OpenAI, Google, etc. Likely keep as a dependency rather than extract.

---

## What NOT to Extract

These are OpenClaw-specific and Bonsai doesn't need them:

- Channel adapters (Telegram, Discord, Slack, Signal, WhatsApp, etc.)
- CLI command framework (`src/cli/`, `src/commands/`)
- Web provider (`src/provider-web.ts`)
- Voice/call handling (`extensions/voice-call/`)
- Media pipeline (`src/media/`)
- Gateway server (`src/gateway/server*.ts`) — Bonsai has its own Next.js server
- Heartbeat runner (`src/infra/heartbeat-runner.ts`) — Bonsai has its own scheduler
- Channel routing (`src/routing/` except session keys)
- Plugin/extension system (`extensions/`)

---

## Upstream Dependencies to Evaluate

These npm packages are used by the extracted code. For each, decide: depend on it, or extract from it too.

| Package | Used By | Decision Needed |
|---------|---------|----------------|
| `@mariozechner/pi-coding-agent` | Runner, session manager, tool dispatch | **Critical** — core of agent execution. Depend on it or fork? |
| `@mariozechner/pi-ai` | LLM provider abstraction | Likely depend — clean interface to multiple providers |
| `@mariozechner/pi-agent-core` | Agent framework primitives | Evaluate — may be able to skip |
| `@anthropic-ai/sdk` | Anthropic API client | Depend |
| `openai` | OpenAI/compatible API client | Depend |

---

## Extraction Strategy

### Phase 1: Minimal Viable Extraction
- Extract runner + tool system + session management
- Depend on Pi SDK packages as-is
- Single LLM provider (Anthropic) to start
- No Docker sandbox yet — workspace-scoped tools only
- Bonsai can run an agent with custom SOUL.md in an isolated workspace

### Phase 2: Docker Sandbox
- Extract sandbox system
- Per-project Docker containers
- Worktree management inside containers
- Full filesystem isolation

### Phase 3: Independence
- Evaluate Pi SDK dependency — fork if needed for Bonsai-specific changes
- Add Bonsai-specific tools (ticket management, board updates)
- Custom system prompt optimized for Bonsai's workflow
- Multi-provider support

---

## Docs That Need Updating

These Bonsai design docs assume the old "decoration pattern" and need rewriting:

| Doc | What Changes |
|-----|-------------|
| `02-technical-architecture.md` | Remove decoration pattern, OpenClaw detection/install, Gateway RPC. Replace with extracted components architecture. |
| `01-project-isolation-architecture.md` | Remove "single OpenClaw installation" assumption. Isolation is now Bonsai-native. |
| `03-agent-session-management.md` | Remove Gateway RPC references. Sessions owned by Bonsai directly. |
| `05-onboarding-wizard.md` | Remove OpenClaw detection/installation steps. Bonsai is self-contained. |
| `06-work-scheduler.md` | Remove Gateway dispatch. Scheduler calls runner directly. |
| `12-technology-stack.md` | Add extracted OpenClaw components to dependency list. Remove Gateway integration. |

---

## Key Source Files Reference

| Area | OpenClaw Source | Lines |
|------|----------------|-------|
| Runner entry | `src/agents/pi-embedded-runner/run.ts` | `runEmbeddedPiAgent` L70 |
| Run attempt | `src/agents/pi-embedded-runner/run/attempt.ts` | `runEmbeddedAttempt` L50+ |
| Runner params | `src/agents/pi-embedded-runner/run/params.ts` | `RunEmbeddedPiAgentParams` L20 |
| Tool assembly | `src/agents/pi-tools.ts` | `createOpenClawCodingTools` L100+ |
| Bash tool | `src/agents/bash-tools.exec.ts` | Host + Docker exec L365+ |
| Docker sandbox | `src/agents/sandbox/docker.ts` | Container lifecycle |
| Sandbox types | `src/agents/sandbox/types.ts` | `SandboxConfig` |
| Sandbox tools | `src/agents/sandbox/manage.ts` | `resolveSandboxContext` |
| System prompt | `src/agents/system-prompt.ts` | `buildAgentSystemPrompt` L129 |
| Bootstrap files | `src/agents/bootstrap-files.ts` | `resolveBootstrapContextForRun` L41 |
| Workspace | `src/agents/workspace.ts` | Bootstrap file loading L224 |
| Session keys | `src/routing/session-key.ts` | Key building/parsing |
| Session store | `src/config/sessions/store.ts` | File store + locking |
| Agent events | `src/infra/agent-events.ts` | Event bus |
| Tool policy | `src/agents/tool-policy.ts` | Profiles + allow/deny |
| Auth profiles | `src/agents/auth-profiles/` | API key management |
