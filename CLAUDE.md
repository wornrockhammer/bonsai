# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

Monorepo with three packages:

- **`webapp/`** — Next.js 16 web application (primary codebase). All `npm` commands below run from here.
- **`agent/`** — Standalone TypeScript agent runtime (`@bonsai/agent`). Must be built and npm-linked before the webapp can use it.
- **`www/`** — Marketing/docs website (separate Next.js app, rarely touched).
- **`docs/`** — 20 architecture documents covering design decisions and system internals.

## Commands

### Webapp (run from `webapp/`)

```bash
npm run dev              # Start dev server (port 3000, binds 0.0.0.0)
npm run build            # Production build
npm run lint             # ESLint
npm run db:push          # Apply schema changes (drizzle-kit push)
npm run db:reset         # Clean dev DB reset (BONSAI_ENV=dev)
npm run db:reset-test    # Reset dev DB with sample data
npm run db:seed          # Add sample data to existing DB
npm run db:studio        # Open Drizzle Studio web UI
```

### Agent (run from `agent/`)

```bash
npm run build            # Compile TypeScript + copy bin
npm run dev              # TypeScript watch mode
npm test                 # Vitest run (all tests)
npm run test:watch       # Vitest watch mode
npm run typecheck        # Type-check without emitting
```

### Agent ↔ Webapp Linkage

The webapp imports `@bonsai/agent` via npm link. After agent changes:

```bash
cd agent && npm run build && npm link
cd ../webapp && npm link @bonsai/agent
```

### Heartbeat CLI

```bash
bonsai-heartbeat               # Run dispatcher once
bonsai-heartbeat --limit 5     # Dispatch up to 5 tickets per phase
bonsai-heartbeat --env dev     # Use development database
```

## Architecture

### Three-Phase Ticket Workflow

Tickets progress through: **research → plan → build → test → ship**

Each phase has a human approval gate. Agents are dispatched as detached Claude CLI processes (fire-and-forget) and report back via HTTP webhooks to the webapp API.

- **Research phase**: Read-only tools (Read, Grep, Glob, safe Bash). Produces a research document.
- **Plan phase**: Read-only + AskUserQuestion. Produces an implementation plan.
- **Build phase**: Full tool access (Write, Edit, Bash). Executes the approved plan.

### Agent Dispatch

The heartbeat dispatcher (`agent/src/lib/dispatcher.ts`, ~1100 lines) runs on a 60-second schedule via launchd (macOS) or cron (Linux). It queries the SQLite DB for tickets in each phase, spawns detached Claude CLI processes, and enforces timeouts (5 min for research/plan, 10 min for implementation, 30 min hard limit).

Agents communicate back via:
- `POST /api/tickets/[id]/report` — progress updates
- `POST /api/tickets/[id]/agent-complete` — completion notification

Session files live at `~/.bonsai/sessions/{ticketId}-agent-{timestamp}/`.

### Data Storage

Three storage layers:
- **SQLite** (`bonsai.db` / `bonsai-dev.db` in `webapp/`) — all structured data (tickets, personas, projects, comments, etc.)
- **Filesystem** (`~/.bonsai/sessions/`) — agent session outputs, logs, prompts
- **Encrypted vault** (`~/.bonsai/vault.age`) — API keys and tokens, using age-encryption (X25519 + ChaCha20-Poly1305). Private key at `~/.bonsai/vault-key.txt` (0600).

### Database

- Drizzle ORM + better-sqlite3 (synchronous). Schema at `webapp/src/db/schema.ts`.
- `BONSAI_ENV=dev` selects `bonsai-dev.db`; otherwise uses `bonsai.db`. Set in `webapp/.env.development`.
- WAL mode and foreign keys enabled.
- **Important**: `drizzle-kit push` has bugs with existing column migrations. Use raw `ALTER TABLE` for adding columns to existing databases. Must apply to both `bonsai.db` and `bonsai-dev.db` if both exist.
- DB scripts use `npx tsx` as the runner.

### Key Tables

| Table | Purpose |
|---|---|
| `tickets` | Work items with state machine, lifecycle tracking, merge tracking |
| `personas` | AI agents with role, personality, skills (JSON), project scope |
| `roles` | Role archetypes with system prompts, tool permissions, skill definitions |
| `projects` | GitHub-linked projects with local path |
| `comments` | Ticket discussion (human/agent/system authors) |
| `ticket_documents` | Research docs, implementation plans, critiques |
| `ticket_audit_log` | Immutable event timeline (survives ticket deletion) |
| `project_notes` | Voice/text/image notes on desktop |
| `extracted_items` | Work items extracted from notes via AI |

## Tech Stack

- **Frontend**: Next.js 16, React 19 (with React Compiler), Tailwind CSS 4
- **Backend**: Next.js App Router API routes
- **Database**: SQLite via Drizzle ORM + better-sqlite3
- **Agent**: TypeScript, Vitest, Zod, Anthropic SDK
- **Encryption**: age-encryption package
- **Path alias**: `@/*` maps to `webapp/src/*`

## Code Patterns

- Frontend components are `"use client"` with inline styles using CSS variables: `--text-primary`, `--text-secondary`, `--text-muted`, `--accent-blue`, `--bg-input`, `--border-medium`
- API routes follow Next.js App Router conventions (`route.ts` files with exported GET/POST/PUT/DELETE)
- Agent dispatch uses shell redirection to files (not pipe FDs) because `claude -p` spawns tool subprocesses that inherit pipe FDs, causing spawn/close hangs
- Board view polls every 15 seconds via `useEffect` in `board-view.tsx`
- Persona `personality` field and role `skill_definitions` are used in agent system prompts (see `src/lib/prompt-builder.ts`)
