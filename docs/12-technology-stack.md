# Bonsai Technology Stack

Date: 2026-02-04

> **Architecture note (2026-02-04):** Bonsai is fully self-contained. There is no OpenClaw Gateway, no WebSocket RPC, and no `openclaw.json`. The architecture is: **Web App** (Next.js) for all UI + **Heartbeat** (cron/launchd) for agent execution. Two data layers: SQLite for structured state, filesystem for content/artifacts/repos/sessions. Agents run in-process via the heartbeat model. All agent-human communication happens via comments on tickets. Some design patterns trace their extraction origin to OpenClaw, but Bonsai has zero runtime dependency on OpenClaw. See `13-agent-runtime.md` for agent runtime details and `14-tool-system.md` for the tool system.

## Overview

Bonsai is a **Web App + Heartbeat** architecture:

- **Web App** -- User-facing interface for project management, ticket boards, settings, onboarding, and agent communication (via ticket comments)
- **Heartbeat** -- System-level process (cron/launchd/systemd) that periodically wakes, runs agents against actionable tickets, and exits

Two data layers:
- **SQLite** (via Prisma) -- Structured state: projects, tickets, comments, agent runs, configuration
- **Filesystem** -- Content and artifacts: cloned repos, SOUL.md/MEMORY.md, agent sessions, logs

The stack is chosen for TypeScript consistency, modern React patterns, and local-first data storage.

---

## Core Stack

| Layer | Technology | Version |
|-------|------------|---------|
| Framework | Next.js | 15.x |
| UI Library | React | 19.x |
| Language | TypeScript | 5.x |
| Styling | Tailwind CSS | 4.x |
| Database | SQLite (via Prisma) | - |
| ORM | Prisma | 6.x |
| CLI | Commander | 12.x |
| Logging | tslog | 4.x |
| Runtime | Node.js | 22.x |

---

## Framework: Next.js 15

### Why Next.js

- **API Routes** -- Built-in API layer for system calls without separate backend
- **Server Components** -- Reduce client bundle, fetch data on server
- **TypeScript-first** -- Matches the TypeScript codebase throughout
- **File-based routing** -- Simple, predictable structure
- **Middleware** -- Auth, logging, request processing

### App Router Structure

```
bonsai/
+-- app/
|   +-- layout.tsx              # Root layout
|   +-- page.tsx                # Dashboard
|   +-- projects/
|   |   +-- page.tsx            # Project list
|   |   +-- [slug]/
|   |       +-- page.tsx        # Project board
|   |       +-- tickets/
|   |           +-- [id]/
|   |               +-- page.tsx # Ticket detail
|   +-- settings/
|   |   +-- page.tsx            # Settings
|   +-- api/
|       +-- projects/
|       |   +-- route.ts        # CRUD projects
|       +-- tickets/
|       |   +-- route.ts        # CRUD tickets
|       +-- heartbeat/
|       |   +-- route.ts        # Heartbeat status & control
|       +-- vault/
|           +-- route.ts        # Key vault management
+-- components/                  # Shared UI components
+-- lib/                         # Utilities, db client
+-- cli/                         # CLI commands (heartbeat, etc.)
+-- prisma/
    +-- schema.prisma           # Database schema
```

### Configuration

```typescript
// next.config.ts
import type { NextConfig } from 'next';

const config: NextConfig = {
  experimental: {
    serverActions: {
      bodySizeLimit: '2mb',
    },
  },
  // Local-only, no CDN
  images: {
    unoptimized: true,
  },
};

export default config;
```

---

## UI: React 19

### Why React 19

- **Server Components** -- Default for Next.js App Router
- **Actions** -- Form handling without client JS
- **use() hook** -- Simplified async data in components
- **Concurrent features** -- Suspense, transitions stable

### Security Patches

Always run latest patch version:

```json
{
  "dependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  }
}
```

Enable Dependabot or Renovate for automated security updates.

### Component Patterns

```typescript
// Server Component (default)
async function ProjectBoard({ slug }: { slug: string }) {
  const project = await db.project.findUnique({ where: { slug } });
  const tickets = await db.ticket.findMany({ where: { projectId: project.id } });

  return <Board project={project} tickets={tickets} />;
}

// Client Component (interactive)
'use client';

function TicketCard({ ticket }: { ticket: Ticket }) {
  const [isDragging, setIsDragging] = useState(false);
  // ...
}
```

---

## Styling: Tailwind CSS 4

### Why Tailwind 4

- **CSS-first config** -- No JavaScript config file
- **Native CSS variables** -- Dynamic theming
- **Container queries** -- Built-in responsive components
- **Smaller runtime** -- No purge step needed

### Setup

```css
/* app/globals.css */
@import "tailwindcss";

@theme {
  /* Custom colors from UI spec */
  --color-gray-950: #0A0A0C;
  --color-gray-900: #111114;
  --color-gray-800: #17171B;
  --color-gray-700: #1E1E23;
  /* ... see 11-ui-design-spec.md */
}
```

### Fonts

```css
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

@theme {
  --font-sans: 'Inter', system-ui, sans-serif;
}
```

---

## Database: SQLite + Prisma

### Why SQLite

- **Local-first** -- No external database server
- **Single file** -- Easy backup, portable
- **Fast reads** -- Excellent for read-heavy workloads
- **Embedded** -- Ships with the app

### Why Prisma

- **Type-safe queries** -- Full TypeScript integration
- **Migrations** -- Schema versioning
- **SQLite support** -- First-class driver
- **Query builder** -- No raw SQL needed

### Schema

```prisma
// prisma/schema.prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = "file:../../bonsai.db"
}

model Project {
  id        String   @id @default(cuid())
  slug      String   @unique
  name      String
  persona   String   @default("developer")
  repoUrl   String?
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  tickets   Ticket[]
}

model Ticket {
  id          String       @id @default(cuid())
  projectId   String
  project     Project      @relation(fields: [projectId], references: [id])

  type        TicketType   @default(FEATURE)
  state       TicketState  @default(BACKLOG)
  subState    String?

  title       String
  description String

  researchDocId String?
  planDocId     String?
  todoDocId     String?

  createdAt   DateTime     @default(now())
  updatedAt   DateTime     @updatedAt

  documents   Document[]
  comments    Comment[]
  agentRuns   AgentRun[]
}

enum TicketType {
  FEATURE
  BUG
  CHORE
}

enum TicketState {
  BACKLOG
  RESEARCH
  READY
  IN_PROGRESS
  DONE
}

model Document {
  id        String       @id @default(cuid())
  ticketId  String
  ticket    Ticket       @relation(fields: [ticketId], references: [id])

  type      DocumentType
  content   String
  status    DocumentStatus @default(DRAFT)
  version   Int          @default(1)

  createdAt DateTime     @default(now())
  updatedAt DateTime     @updatedAt
}

enum DocumentType {
  RESEARCH
  IMPLEMENTATION_PLAN
  TODO
}

enum DocumentStatus {
  DRAFT
  READY
  APPROVED
}

model Comment {
  id        String   @id @default(cuid())
  ticketId  String
  ticket    Ticket   @relation(fields: [ticketId], references: [id])

  authorType String  // "human" | "agent"
  authorId   String
  authorName String

  content    String
  resolved   Boolean @default(false)

  parentId   String?
  parent     Comment?  @relation("CommentThread", fields: [parentId], references: [id])
  replies    Comment[] @relation("CommentThread")

  createdAt  DateTime @default(now())
}

model AgentRun {
  id         String   @id @default(cuid())
  ticketId   String
  ticket     Ticket   @relation(fields: [ticketId], references: [id])

  task       String
  status     String   // "running" | "completed" | "failed"

  sessionKey String

  startedAt  DateTime @default(now())
  completedAt DateTime?

  inputTokens  Int @default(0)
  outputTokens Int @default(0)
}

model Persona {
  id          String @id @default(cuid())
  slug        String @unique
  name        String
  gender      String?
  color       String?

  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt
}
```

### Database Location

```
~/.bonsai/
+-- bonsai.db               # SQLite database (structured state)
+-- config.json             # Bonsai configuration
+-- vault.age               # Encrypted credentials
+-- vault-key.txt           # age private key (mode 0600)
+-- projects/               # Cloned repos (filesystem layer)
+-- agents/                 # Agent sessions and memory (filesystem layer)
+-- logs/                   # Heartbeat and agent logs
```

### Client Setup

```typescript
// lib/db.ts
import { PrismaClient } from '@prisma/client';

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined;
};

export const db = globalForPrisma.prisma ?? new PrismaClient({
  datasources: {
    db: {
      url: `file:${process.env.BONSAI_DATA_DIR ?? '~/.bonsai'}/bonsai.db`,
    },
  },
});

if (process.env.NODE_ENV !== 'production') {
  globalForPrisma.prisma = db;
}
```

---

## Linting & Code Quality

### ESLint Configuration

```javascript
// eslint.config.js
import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import react from 'eslint-plugin-react';
import reactHooks from 'eslint-plugin-react-hooks';
import complexity from 'eslint-plugin-complexity';
import functional from 'eslint-plugin-functional';

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  {
    plugins: {
      react,
      'react-hooks': reactHooks,
      complexity,
      functional,
    },
    rules: {
      // TypeScript strict
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unused-vars': 'error',
      '@typescript-eslint/strict-boolean-expressions': 'error',

      // React
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',

      // Complexity limits
      'complexity': ['error', { max: 10 }],
      'max-depth': ['error', 3],
      'max-lines-per-function': ['error', { max: 50, skipBlankLines: true, skipComments: true }],
      'max-params': ['error', 4],
      'max-nested-callbacks': ['error', 3],

      // Functional programming
      'functional/no-let': 'warn',
      'functional/prefer-readonly-type': 'warn',
      'functional/no-loop-statements': 'warn',
      'functional/immutable-data': 'warn',
    },
  },
);
```

### Complexity Rules Explained

| Rule | Limit | Purpose |
|------|-------|---------|
| `complexity` | 10 | Cyclomatic complexity per function |
| `max-depth` | 3 | Nesting depth (if/for/while) |
| `max-lines-per-function` | 50 | Lines per function |
| `max-params` | 4 | Function parameters |
| `max-nested-callbacks` | 3 | Callback nesting |

### TypeScript Configuration

```json
// tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "ES2022"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./*"]
    },

    // Strict mode extras
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

### Prettier

```json
// .prettierrc
{
  "semi": true,
  "singleQuote": true,
  "tabWidth": 2,
  "trailingComma": "es5",
  "printWidth": 100
}
```

### Pre-commit Hooks

```json
// package.json
{
  "scripts": {
    "lint": "eslint . --max-warnings 0",
    "lint:fix": "eslint . --fix",
    "typecheck": "tsc --noEmit",
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "check": "pnpm lint && pnpm typecheck && pnpm format:check"
  }
}
```

```bash
# .husky/pre-commit
pnpm check
```

---

## Functional Programming Patterns

### State Management Philosophy

Prefer **immutable data** and **pure functions**. Avoid class-based state, mutation, and side effects in business logic.

### Immutable State with Zustand

```typescript
// stores/tickets.ts
import { create } from 'zustand';
import { immer } from 'zustand/middleware/immer';

interface TicketsState {
  readonly tickets: ReadonlyArray<Ticket>;
  readonly isLoading: boolean;
}

interface TicketsActions {
  setTickets: (tickets: ReadonlyArray<Ticket>) => void;
  addTicket: (ticket: Ticket) => void;
  updateTicket: (id: string, updates: Partial<Ticket>) => void;
  moveTicket: (id: string, newState: TicketState) => void;
}

export const useTicketsStore = create<TicketsState & TicketsActions>()(
  immer((set) => ({
    tickets: [],
    isLoading: false,

    setTickets: (tickets) =>
      set((state) => {
        state.tickets = tickets;
      }),

    addTicket: (ticket) =>
      set((state) => {
        state.tickets.push(ticket);
      }),

    updateTicket: (id, updates) =>
      set((state) => {
        const index = state.tickets.findIndex((t) => t.id === id);
        if (index !== -1) {
          state.tickets[index] = { ...state.tickets[index], ...updates };
        }
      }),

    moveTicket: (id, newState) =>
      set((state) => {
        const index = state.tickets.findIndex((t) => t.id === id);
        if (index !== -1) {
          state.tickets[index].state = newState;
        }
      }),
  }))
);
```

### Pure Functions for Business Logic

```typescript
// lib/tickets/transitions.ts

// Pure function - no side effects, same input = same output
export const canTransition = (
  ticket: Readonly<Ticket>,
  targetState: TicketState
): boolean => {
  const transitions: Record<TicketState, ReadonlyArray<TicketState>> = {
    BACKLOG: ['RESEARCH'],
    RESEARCH: ['READY', 'BACKLOG'],
    READY: ['IN_PROGRESS', 'BACKLOG'],
    IN_PROGRESS: ['DONE', 'READY'],
    DONE: [],
  };

  return transitions[ticket.state]?.includes(targetState) ?? false;
};

// Pure function - returns new object, doesn't mutate
export const applyTransition = (
  ticket: Readonly<Ticket>,
  targetState: TicketState
): Ticket => {
  if (!canTransition(ticket, targetState)) {
    throw new Error(`Invalid transition: ${ticket.state} -> ${targetState}`);
  }

  return {
    ...ticket,
    state: targetState,
    updatedAt: new Date(),
  };
};
```

### Functional Data Transformations

```typescript
// lib/tickets/grouping.ts

// Use map/filter/reduce instead of loops
export const groupByState = (
  tickets: ReadonlyArray<Ticket>
): Readonly<Record<TicketState, ReadonlyArray<Ticket>>> => {
  return tickets.reduce(
    (acc, ticket) => ({
      ...acc,
      [ticket.state]: [...(acc[ticket.state] ?? []), ticket],
    }),
    {} as Record<TicketState, Ticket[]>
  );
};

// Compose small functions
export const getReadyTickets = (tickets: ReadonlyArray<Ticket>): ReadonlyArray<Ticket> =>
  tickets.filter((t) => t.state === 'READY');

export const sortByCreatedAt = (tickets: ReadonlyArray<Ticket>): ReadonlyArray<Ticket> =>
  [...tickets].sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());

export const getReadyTicketsSorted = (tickets: ReadonlyArray<Ticket>): ReadonlyArray<Ticket> =>
  sortByCreatedAt(getReadyTickets(tickets));
```

### Option/Result Pattern for Errors

```typescript
// lib/result.ts
type Result<T, E = Error> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };

const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

// Usage
export const parseTicketId = (input: string): Result<string, string> => {
  if (!input.startsWith('tkt_')) {
    return err('Invalid ticket ID format');
  }
  return ok(input);
};

// Consuming
const result = parseTicketId(userInput);
if (result.ok) {
  console.log(result.value);
} else {
  console.error(result.error);
}
```

---

## Architecture: Web App + Heartbeat

### Web App (Next.js)

The user-facing application handles all UI: settings, projects, tickets, docs, onboarding, and agent communication (via ticket comments).

```
+---------------------------------------------------+
|                   Web App                          |
|  +---------------------------------------------+  |
|  |           Next.js (App Router)              |  |
|  +---------------------------------------------+  |
|  |  Pages          |  API Routes               |  |
|  |  - Dashboard    |  - /api/projects          |  |
|  |  - Board        |  - /api/tickets           |  |
|  |  - Ticket       |  - /api/heartbeat         |  |
|  |  - Settings     |  - /api/vault             |  |
|  +---------------------------------------------+  |
|                      |                             |
|                      v                             |
|  +---------------------------------------------+  |
|  |              Prisma + SQLite                |  |
|  +---------------------------------------------+  |
+---------------------------------------------------+
```

### Heartbeat (Background Service)

The heartbeat is a short-lived process fired by the system scheduler. It is NOT a long-running daemon.

```
+---------------------------------------------------+
|         Heartbeat (cron/launchd/systemd)           |
|                                                   |
|  launchd/systemd timer (every 60s)                |
|            |                                       |
|            v                                       |
|  +---------------------------------------------+  |
|  |          bonsai heartbeat                    |  |
|  +---------------------------------------------+  |
|  |                                             |  |
|  |  1. Query SQLite for actionable tickets     |  |
|  |  2. Pick highest priority work              |  |
|  |  3. Run AgentRunner in-process              |  |
|  |  4. AgentRunner uses ToolExecutor           |  |
|  |  5. Write results to SQLite + filesystem    |  |
|  |  6. Exit                                    |  |
|  |                                             |  |
|  +-----+-------------------+-------------------+  |
|        |                   |                       |
|        v                   v                       |
|  +----------+    +------------------+              |
|  | Agent    |    | ToolExecutor     |              |
|  | Runner   |    | (git, fs, shell) |              |
|  +----------+    +------------------+              |
|                                                   |
+---------------------------------------------------+
```

The ToolExecutor, WorkspaceProvider, and AgentRunner form abstraction boundaries designed for future containerization. See `13-agent-runtime.md` for details.

### Two Data Layers

```
+--------------------------+     +---------------------------+
|     SQLite (Prisma)      |     |     Filesystem            |
|   Structured State       |     |   Content & Artifacts     |
+--------------------------+     +---------------------------+
| - Projects               |     | - ~/.bonsai/projects/     |
| - Tickets                |     |   (cloned repos)          |
| - Comments               |     | - ~/.bonsai/agents/       |
| - Documents              |     |   (sessions, memory)      |
| - Agent Runs             |     | - SOUL.md, MEMORY.md      |
| - Personas               |     | - ~/.bonsai/logs/         |
| - Configuration metadata |     | - ~/.bonsai/config.json   |
+--------------------------+     +---------------------------+
```

### Heartbeat Service Management

The heartbeat is managed by the operating system's native service manager. No PM2, no ecosystem config.

**macOS (launchd):**
```xml
<!-- ~/Library/LaunchAgents/com.bonsai.heartbeat.plist -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.bonsai.heartbeat</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/bonsai</string>
    <string>heartbeat</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>StandardOutPath</key>
  <string>~/.bonsai/logs/heartbeat.log</string>
  <key>StandardErrorPath</key>
  <string>~/.bonsai/logs/heartbeat.err</string>
</dict>
</plist>
```

**Linux (systemd):**
```ini
# ~/.config/systemd/user/bonsai-heartbeat.timer
[Unit]
Description=Bonsai Heartbeat Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
```

See `13-agent-runtime.md` for the full heartbeat implementation and `05-onboarding-wizard.md` for how the service is installed during onboarding.

### CLI (Commander)

The `bonsai` CLI is built with Commander and provides commands for managing the heartbeat, running manual operations, and debugging.

```typescript
// cli/index.ts
import { Command } from 'commander';

const program = new Command();

program
  .name('bonsai')
  .description('AI-powered developer workspace')
  .version('1.0.0');

program
  .command('heartbeat')
  .description('Run a single heartbeat cycle (query tickets, run agents, exit)')
  .action(async () => {
    await runHeartbeat();
  });

program
  .command('heartbeat install')
  .description('Install the heartbeat service (launchd on macOS, systemd on Linux)')
  .action(async () => {
    await installHeartbeatService();
  });

program
  .command('token reset')
  .description('Reset the web UI authentication token')
  .action(async () => {
    await resetToken();
  });

program.parse();
```

---

## Security: Web UI Authentication

### Threat Model

Bonsai's Next.js app exposes API routes that can read/write projects, dispatch agents, and manage credentials. Without auth:

| Threat | Vector | Impact |
|--------|--------|--------|
| Local process SSRF | Any local process can call `localhost:3000/api/*` | Read/write projects, dispatch agents |
| Shared workstation | Another user opens `localhost:3000` | Full access to all projects |
| Browser extension | Malicious extension calls API | Data exfiltration |
| Network exposure | Accidentally bound to `0.0.0.0` | Full remote access |

### Auth Strategy: Startup Token (v1)

Modeled after Jupyter Notebook's token auth. On startup, Bonsai generates a random token and displays it in the terminal. The token is required for all requests.

```typescript
// lib/auth/token.ts
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const TOKEN_PATH = path.join(
  process.env.HOME ?? "~",
  ".bonsai",
  "web-token"
);

export function getOrCreateToken(): string {
  // Reuse existing token if process was restarted
  if (fs.existsSync(TOKEN_PATH)) {
    return fs.readFileSync(TOKEN_PATH, "utf-8").trim();
  }

  const token = randomBytes(32).toString("hex");
  fs.mkdirSync(path.dirname(TOKEN_PATH), { recursive: true });
  fs.writeFileSync(TOKEN_PATH, token, { mode: 0o600 });
  return token;
}

export function validateToken(request: Request): boolean {
  const token = getOrCreateToken();

  // Check cookie first
  const cookie = request.headers.get("cookie");
  if (cookie?.includes(`bonsai_token=${token}`)) return true;

  // Check Authorization header (for API calls)
  const auth = request.headers.get("authorization");
  if (auth === `Bearer ${token}`) return true;

  // Check query param (for initial browser redirect)
  const url = new URL(request.url);
  if (url.searchParams.get("token") === token) return true;

  return false;
}
```

### Next.js Middleware

```typescript
// middleware.ts
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { validateToken, getOrCreateToken } from "@/lib/auth/token";

export function middleware(request: NextRequest) {
  // Allow the login page itself
  if (request.nextUrl.pathname === "/login") {
    return NextResponse.next();
  }

  // Allow health check
  if (request.nextUrl.pathname === "/api/health") {
    return NextResponse.next();
  }

  if (!validateToken(request)) {
    // API routes -> 401
    if (request.nextUrl.pathname.startsWith("/api/")) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    // Pages -> redirect to login
    return NextResponse.redirect(new URL("/login", request.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
```

### Login Flow

```
Terminal output on startup:
+------------------------------------------------------+
|  Bonsai running at http://localhost:3000              |
|                                                      |
|  Open in browser:                                    |
|  http://localhost:3000?token=a1b2c3d4e5f6...         |
|                                                      |
|  Token saved to ~/.bonsai/web-token                  |
+------------------------------------------------------+
```

1. User clicks the tokenized URL -> sets `bonsai_token` cookie -> redirects to dashboard
2. Subsequent requests use the cookie (no token in URL)
3. API clients use `Authorization: Bearer <token>` header
4. Token persists across server restarts (stored in `~/.bonsai/web-token`)
5. `bonsai token reset` CLI command generates a new token

### Binding

```typescript
// next.config.ts -- always bind to localhost
const config: NextConfig = {
  // ...
};

// In server startup:
// next dev --hostname 127.0.0.1
// next start --hostname 127.0.0.1
```

The server binds to `127.0.0.1` only (not `0.0.0.0`). Network exposure requires explicit opt-in via `--hostname 0.0.0.0` flag.

### v2 Considerations

| Feature | v1 | v2 |
|---------|----|----|
| Auth method | Startup token | + passkey / system keychain |
| Binding | localhost only | + Tailscale / LAN with mTLS |
| Multi-user | Single user | User accounts with roles |
| Session management | Cookie (no expiry) | + expiry + refresh |

---

## Dependencies

### Production

```json
{
  "dependencies": {
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "@prisma/client": "^6.0.0",
    "zustand": "^5.0.0",
    "immer": "^10.0.0",
    "@dnd-kit/core": "^6.0.0",
    "@dnd-kit/sortable": "^8.0.0",
    "lucide-react": "^0.400.0",
    "commander": "^12.0.0",
    "tslog": "^4.0.0",
    "zod": "^3.0.0",
    "age-encryption": "^0.1.0"
  }
}
```

**Notable inclusions:**
- `commander` -- CLI framework for `bonsai heartbeat`, `bonsai token reset`, etc.
- `tslog` -- Structured logging for heartbeat and agent runs
- `age-encryption` -- Vault encryption (see `05-onboarding-wizard.md`)

**Notable exclusions:**
- No `ws` (WebSocket client) -- no gateway, no WebSocket RPC
- No `cron` (job scheduler library) -- heartbeat is managed by launchd/systemd, not in-process cron

### Development

```json
{
  "devDependencies": {
    "typescript": "^5.0.0",
    "prisma": "^6.0.0",
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "eslint": "^9.0.0",
    "typescript-eslint": "^8.0.0",
    "eslint-plugin-react": "^7.0.0",
    "eslint-plugin-react-hooks": "^5.0.0",
    "eslint-plugin-functional": "^7.0.0",
    "prettier": "^3.0.0",
    "tailwindcss": "^4.0.0",
    "husky": "^9.0.0"
  }
}
```

**Notable exclusions from dev dependencies:**
- No `@types/ws` -- no WebSocket usage

---

## Summary

| Concern | Solution |
|---------|----------|
| Framework | Next.js 15 (App Router) |
| UI | React 19 + Server Components |
| Styling | Tailwind CSS 4 |
| Database | SQLite via Prisma (structured state) |
| Filesystem | Repos, sessions, artifacts (content layer) |
| State | Zustand + Immer (immutable) |
| CLI | Commander |
| Logging | tslog |
| Linting | ESLint strict + complexity rules |
| Types | TypeScript strict mode |
| Patterns | Functional, immutable, pure functions |
| Background | Heartbeat via launchd/systemd (no PM2) |
| Agent execution | In-process via AgentRunner (see 13-agent-runtime.md) |
| Tool system | ToolExecutor abstraction (see 14-tool-system.md) |

The stack prioritizes:
1. **TypeScript consistency** throughout the entire codebase
2. **Local-first** data storage (SQLite + filesystem, no cloud dependencies)
3. **Functional patterns** for predictable state
4. **Strict linting** for code quality
5. **Modern React** with Server Components
6. **Simplicity** -- heartbeat model over long-running daemons, no WebSocket/Gateway complexity
