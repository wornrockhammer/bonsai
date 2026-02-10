# Bonsai Filesystem Layout — Design Document

Date: 2026-02-04

## Overview

The Bonsai **mount** is a git-tracked filesystem that serves as the single source of truth for Bonsai data. It is separate from the installed Bonsai application and can be located anywhere on disk.

**Design principles:**
- Files over database when content benefits from git tracking
- SQLite stores paths, metadata, and indexes — not duplicated content
- Git provides time travel, recovery, and audit history
- Structure supports multiple projects with isolated workspaces

**Separation of concerns:**
- **Bonsai mount** — User data, projects, tickets, personas
- **Bonsai app** — Installed application (separate location)
- **OpenClaw** — Lives in its own install directory with its own config

---

## 1. Mount Location

**Default:** `~/.bonsai`

**Configurable:** Users can set a custom mount path during first-run setup or in settings. The app stores the mount path in its own config (outside the mount).

```typescript
// App config (outside mount, e.g., ~/Library/Application Support/Bonsai/app.json)
{
  "mountPath": "~/.bonsai",
  "version": "1.0.0"
}
```

---

## 2. Directory Structure

```
~/.bonsai/                              # Mount root — git tracked
├── .git/                               # Bonsai's git (time travel, recovery)
├── .gitignore                          # Ignores projects/, logs/, temp files
│
├── personas/                           # SYSTEM-LEVEL agent templates
│   ├── developer/
│   │   ├── SOUL.md                    # Core persona instructions
│   │   ├── MEMORY.md                  # Pre-loaded knowledge (optional)
│   │   ├── IDENTITY.md                # Agent identity (optional)
│   │   ├── TOOLS.md                   # Tool permissions (optional)
│   │   └── settings.json              # Model, tools, behavior config
│   ├── reviewer/
│   │   └── ...
│   └── researcher/
│       └── ...
│
├── projects/                           # Cloned repos (gitignored from bonsai git)
│   └── {project-slug}/
│       ├── .git/                      # Project's own git
│       ├── .worktrees/                # Ticket worktrees (git worktrees)
│       │   └── {ticket-id}/           # Isolated worktree per ticket
│       ├── .bonsai/                   # Project-specific Bonsai files
│       │   ├── project.json           # Project metadata (persona reference)
│       │   └── tickets/               # Physical ticket files
│       │       ├── ticket-abc123.md
│       │       └── ticket-def456.md
│       └── (repo source files)
│
├── config.json                         # Global Bonsai settings
├── bonsai.db                           # SQLite database (indexes, metadata)
├── vault.age                           # Encrypted secrets (age format)
├── vault-key.txt                       # Age private key (mode 0600)
│
└── logs/                               # Application logs (gitignored)
    └── bonsai.log
```

**Key point:** Persona files (SOUL.md, MEMORY.md, etc.) live at `~/.bonsai/personas/` — they are NOT copied to projects. Projects reference a persona by name in `project.json`.

---

## 3. Personas

Personas are **system-level** agent templates stored at `~/.bonsai/personas/`. Each persona contains all the standard OpenClaw workspace files (SOUL.md, MEMORY.md, TOOLS.md, etc.) plus Bonsai-specific identity (name, gender, profile picture).

When creating a project, users select a persona. The project **references** the persona — files are NOT copied. At runtime, Bonsai loads the persona files and injects project/ticket context.

### 3.1 Persona Structure

Personas contain all the standard OpenClaw agent workspace files plus Bonsai-specific identity:

```
personas/{persona-name}/
├── SOUL.md           # Core personality and instructions
├── MEMORY.md         # Pre-loaded knowledge and context
├── IDENTITY.md       # Name, emoji, avatar (OpenClaw format)
├── TOOLS.md          # Tool permissions and policies
├── AGENTS.md         # Subagent definitions
├── USER.md           # User context template
├── HEARTBEAT.md      # Scheduled tasks (optional)
├── BOOTSTRAP.md      # First-run setup (optional)
├── settings.json     # Model, tools, sandbox config
└── persona.json      # Bonsai identity (name, gender, profile picture)
```

### 3.2 SOUL.md

The agent's core identity — who they are, how they work, what rules they follow.

```markdown
# Developer

You are a software developer focused on writing clean, maintainable code.

## Core Principles
- Write code that is easy to read and understand
- Follow existing patterns in the codebase
- Test your changes before committing
- Create focused, atomic commits

## Working Style
- Start by understanding the existing code
- Ask clarifying questions when requirements are ambiguous
- Break large tasks into smaller, manageable steps
- Document non-obvious decisions in comments

## Commit Format
Always use conventional commits:
- feat: new feature
- fix: bug fix
- refactor: code change that neither fixes nor adds
- docs: documentation only
- test: adding or updating tests
```

### 3.3 MEMORY.md

Pre-loaded knowledge the agent should have.

```markdown
# Knowledge Base

## Common Patterns
- API routes are in `src/api/`
- React components are in `src/components/`
- Tests are colocated with source files as `*.test.ts`

## Style Guide
- Use TypeScript strict mode
- Prefer functional components with hooks
- Use Tailwind for styling
```

### 3.4 settings.json

OpenClaw agent configuration:

```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514",
    "fallbacks": ["claude-haiku-4-20250514"]
  },
  "tools": {
    "profile": "coding",
    "alsoAllow": ["web.search", "web.fetch"],
    "deny": []
  },
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "rw"
  },
  "memorySearch": {
    "enabled": true
  },
  "subagents": {
    "allowAgents": ["*"]
  }
}
```

### 3.5 persona.json

Bonsai-specific identity (generated or customized):

```json
{
  "name": "Devon",
  "gender": "neutral",
  "profilePicture": "devon-avatar.png",
  "description": "A software developer focused on clean, maintainable code",
  "createdAt": "2026-02-04T10:00:00Z",
  "generatedWith": "stable-diffusion"
}
```

Profile pictures can be:
- Auto-generated during persona creation
- Uploaded by user
- Selected from a library

### 3.6 Built-in Personas

Bonsai ships with these personas:

| Persona | Purpose | Tools Profile |
|---------|---------|---------------|
| `developer` | Full-stack development, writes and modifies code | `coding` |
| `reviewer` | Code review, reads but doesn't modify code | `minimal` |
| `researcher` | Research and documentation, explores and summarizes | `minimal` + web |
| `devops` | Infrastructure, CI/CD, deployment | `full` |

Users can create custom personas in `~/.bonsai/personas/`.

### 3.7 Persona Files Reference

| File | Purpose | OpenClaw Equivalent |
|------|---------|---------------------|
| `SOUL.md` | Core personality, instructions | System prompt |
| `MEMORY.md` | Pre-loaded knowledge | Indexed into memory search |
| `IDENTITY.md` | Name, emoji, avatar | `identity` config |
| `TOOLS.md` | Tool permissions | `tools.allow`/`tools.deny` |
| `AGENTS.md` | Subagent definitions | `subagents` config |
| `USER.md` | User context template | User info injection |
| `HEARTBEAT.md` | Scheduled tasks | `heartbeat` config |
| `settings.json` | Model, tools, sandbox | Agent config fields |
| `persona.json` | Bonsai identity | Bonsai-only (name, gender, avatar) |

### 3.8 Persona Usage (System Level)

Personas are **system-level** resources at `~/.bonsai/personas/`. Projects **reference** a persona but don't copy the files.

```typescript
async function createProject(name: string, persona: string): Promise<void> {
  const projectPath = path.join(mount, "projects", slugify(name));
  const bonsaiPath = path.join(projectPath, ".bonsai");

  // Create project config referencing the persona
  await fs.mkdir(bonsaiPath, { recursive: true });
  await fs.writeFile(
    path.join(bonsaiPath, "project.json"),
    JSON.stringify({
      id: generateId(),
      name,
      slug: slugify(name),
      persona,  // Reference to ~/.bonsai/personas/{persona}/
      created: new Date().toISOString(),
    }, null, 2)
  );

  await fs.mkdir(path.join(bonsaiPath, "tickets"), { recursive: true });
}
```

At runtime, Bonsai loads the persona files from `~/.bonsai/personas/{persona}/` and injects project/ticket context. This keeps personas reusable across projects.

### 3.9 Persona Injection Mechanism

**The Problem:** OpenClaw reads bootstrap files (SOUL.md, MEMORY.md, etc.) directly from the agent's workspace directory. But Bonsai stores personas at `~/.bonsai/personas/` and projects at `~/.bonsai/projects/`. How do persona files reach OpenClaw?

**The Solution:** Use OpenClaw's **`extraSystemPrompt`** parameter.

OpenClaw's Gateway RPC `agent` method accepts an `extraSystemPrompt` parameter that injects additional content into the agent's system prompt. Bonsai uses this to inject persona content without modifying any files.

**Code reference:** `src/gateway/server-methods/agent.ts:83` — `extraSystemPrompt?: string`

**Injection Flow:**

```
1. User triggers ticket work in Bonsai UI
2. Bonsai resolves project → persona reference
3. Bonsai reads persona files from ~/.bonsai/personas/{persona}/
   - SOUL.md
   - MEMORY.md
   - TOOLS.md
   - IDENTITY.md
4. Bonsai reads ticket context from project
   - Ticket description
   - TODO checklist
   - Research/plan documents
5. Bonsai composes a combined prompt:
   - Persona instructions (SOUL.md)
   - Persona knowledge (MEMORY.md)
   - Project context (repo info, conventions)
   - Ticket context (what to do)
6. Bonsai calls Gateway RPC:
   await gateway.agent({
     agentId: "default",
     sessionKey: `agent:default:bonsai:${projectId}:ticket:${ticketId}`,
     message: userMessage,
     extraSystemPrompt: composedPrompt,  // <-- Injected here
   });
7. OpenClaw merges extraSystemPrompt with any workspace files
8. Agent executes with full context
```

**Composition Function:**

```typescript
async function composePersonaPrompt(
  personaPath: string,
  project: Project,
  ticket: Ticket
): Promise<string> {
  const parts: string[] = [];

  // Load persona files
  const soul = await readFileIfExists(path.join(personaPath, "SOUL.md"));
  const memory = await readFileIfExists(path.join(personaPath, "MEMORY.md"));
  const tools = await readFileIfExists(path.join(personaPath, "TOOLS.md"));
  const identity = await readFileIfExists(path.join(personaPath, "IDENTITY.md"));

  // Persona section
  if (soul) {
    parts.push("# Persona\n\n" + soul);
  }
  if (identity) {
    parts.push("# Identity\n\n" + identity);
  }
  if (memory) {
    parts.push("# Knowledge Base\n\n" + memory);
  }
  if (tools) {
    parts.push("# Tool Guidelines\n\n" + tools);
  }

  // Project section
  parts.push(`# Project Context

Repository: ${project.repo.url}
Branch: ${project.repo.defaultBranch}
Language: ${project.language || "Unknown"}
Local path: ${project.path}

Only make changes within this repository. Follow existing code conventions.`);

  // Ticket section
  parts.push(`# Current Task

Ticket: ${ticket.id}
Title: ${ticket.title}

## Description

${ticket.description}

## Acceptance Criteria

${ticket.acceptanceCriteria || "See description above."}`);

  return parts.join("\n\n---\n\n");
}
```

**Why This Approach:**

| Approach | Pros | Cons |
|----------|------|------|
| **extraSystemPrompt (chosen)** | No file copying, no symlinks, clean separation | Prompt can get large |
| Copy files to workspace | OpenClaw sees files natively | Duplicates data, sync issues |
| Symlinks | Single source of truth | Cross-platform issues, git confusion |
| Modify OpenClaw | Could add persona resolution | Violates "no OC modifications" principle |

**Trade-off: Prompt Size**

Composing persona + project + ticket context into `extraSystemPrompt` can create large prompts. Mitigations:

1. **Truncation** — Limit MEMORY.md to first N characters (similar to OpenClaw's `bootstrapMaxChars`)
2. **Selective loading** — Only load files relevant to the task type
3. **Caching** — Cache composed prompts per persona+project (invalidate on file change)

**What OpenClaw Still Provides:**

Even with `extraSystemPrompt`, OpenClaw can still read from the **project workspace** (the cloned repo). If the project has a `CLAUDE.md` or project-specific instructions, OpenClaw loads them from the workspace. Bonsai's injection is **additive**.

---

## 4. Projects

Each project is a cloned git repository with Bonsai-specific files in a `.bonsai/` subdirectory.

### 4.1 Project Structure

```
projects/{project-slug}/
├── .git/                          # Project's git repository
├── .worktrees/                    # Git worktrees for tickets
│   ├── ticket-abc123/             # Worktree for ticket abc123
│   │   └── (full repo checkout)
│   └── ticket-def456/
│       └── ...
├── .bonsai/                       # Bonsai project files
│   ├── project.json              # Project metadata (includes persona reference)
│   └── tickets/                  # Physical ticket files
│       ├── ticket-abc123.md
│       └── ticket-def456.md
└── (repo source files)
```

**Note:** Persona files (SOUL.md, MEMORY.md, etc.) are at system level in `~/.bonsai/personas/`. The project's `project.json` references which persona to use.

### 4.2 project.json

```json
{
  "id": "proj_abc123",
  "name": "My App",
  "slug": "my-app",
  "persona": "developer",
  "repo": {
    "url": "https://github.com/user/my-app",
    "defaultBranch": "main"
  },
  "created": "2026-02-04T10:00:00Z"
}
```

The `persona` field references a system-level persona at `~/.bonsai/personas/{persona}/`. Model and tool settings come from the persona's `settings.json`.

### 4.3 Worktrees

Each ticket gets its own git worktree for isolated development. See `08-git-operations.md` for details.

```
.worktrees/
├── ticket-abc123/         # Branch: ticket/abc123
│   ├── .git               # Worktree git link
│   └── (full repo)
└── ticket-def456/         # Branch: ticket/def456
    └── ...
```

---

## 5. Tickets

Tickets use a **file + SQLite** hybrid model:
- **Files** — Physical ticket content (git-tracked, human-editable)
- **SQLite** — Indexes and metadata (fast queries, state tracking)

### 5.1 Physical Ticket File

```
projects/my-app/.bonsai/tickets/ticket-abc123.md
```

```markdown
---
id: ticket-abc123
type: feature
title: Add OAuth login
created: 2026-02-04T10:00:00Z
---

## Description

Add Google and GitHub OAuth login options to the app.
Users should be able to link multiple providers to one account.

## Acceptance Criteria

- [ ] User can sign in with Google
- [ ] User can sign in with GitHub
- [ ] User can link both providers to same account
- [ ] Existing email/password users can link OAuth
- [ ] All tests pass

## Notes

Optional section for additional context, links, attachments.
```

### 5.2 SQLite Index

```sql
-- Tickets table indexes the physical files
CREATE TABLE tickets (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  state TEXT NOT NULL,  -- backlog, research, ready, in_progress, done
  priority INTEGER DEFAULT 0,
  file_path TEXT NOT NULL,  -- path to .md file
  worktree_path TEXT,  -- path to worktree (if active)
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE INDEX idx_tickets_project_state ON tickets(project_id, state);
CREATE INDEX idx_tickets_priority ON tickets(priority DESC);
```

### 5.3 Benefits of Hybrid

| Aspect | File | SQLite |
|--------|------|--------|
| Content editing | Human can edit .md directly | — |
| Git tracking | Full diff history | — |
| Query "all in-progress tickets" | — | Fast indexed query |
| Sort by priority | — | ORDER BY priority |
| State transitions | — | UPDATE state = 'done' |

**No duplication:** SQLite stores `file_path`, not content. Content lives in one place.

---

## 6. Internal Files

### 6.1 config.json

Global Bonsai configuration. Git-tracked for recovery.

```json
{
  "version": "1.0.0",
  "scheduler": {
    "maxConcurrentAgents": "auto",
    "detectedConcurrency": 2
  },
  "ui": {
    "theme": "system"
  }
}
```

**Note:** OpenClaw configuration lives in OpenClaw's install directory, not here.

### 6.2 bonsai.db (SQLite)

Stores indexes and metadata. See `XX-database-schema.md` for full schema.

**Tables:**
- `projects` — Project metadata (references project.json paths)
- `tickets` — Ticket state, priority, paths to ticket files
- `comments` — Anchored comments on tickets/documents
- `agent_runs` — Agent execution history

### 6.3 vault.age / vault-key.txt

Encrypted secrets storage. See `05-onboarding-wizard.md` Section 4 for details.

### 6.4 logs/

Application logs. Gitignored — not tracked.

```
logs/
├── bonsai.log              # Main application log
└── agent-runs/             # Per-run agent logs
    ├── run-abc123.log
    └── run-def456.log
```

---

## 7. Git Tracking

### 7.1 What's Tracked

The bonsai mount is itself a git repository for time travel and recovery.

**Tracked:**
- `personas/` — All persona files
- `config.json` — Global settings
- `bonsai.db` — Database (binary, but git handles it)
- `vault.age` — Encrypted secrets

**Gitignored:**
- `projects/` — Each project has its own git
- `logs/` — Logs don't need versioning
- `vault-key.txt` — Private key must NOT be in git
- `*.tmp`, `*.lock` — Temporary files

### 7.2 .gitignore

```gitignore
# Projects have their own git
projects/

# Logs don't need versioning
logs/

# Private key must not be tracked
vault-key.txt

# Temporary files
*.tmp
*.lock
*.swp
.DS_Store
```

### 7.3 Automatic Commits

Bonsai automatically commits to the mount git on significant events:

| Event | Commit Message |
|-------|----------------|
| Persona created/modified | `persona: update {name}` |
| Settings changed | `config: update settings` |
| Database checkpoint | `db: checkpoint` |

**Note:** Project/ticket changes are tracked in the project's own git, not the mount git.

---

## 8. File vs Database Decision Guide

| Data Type | Storage | Reason |
|-----------|---------|--------|
| Agent instructions (SOUL, MEMORY) | Files | Human-editable, git-diffable |
| Project config | Files (`project.json`) | Human-readable, git-tracked |
| Ticket content | Files (`.md`) | Git-diffable, human-editable |
| Ticket state/priority | SQLite | Fast queries, indexes |
| Secrets | Files (`vault.age`) | Encrypted blob, git-tracked |
| Global config | Files (`config.json`) | Human-editable |
| Comments | SQLite | Relational (ticket → comments) |
| Agent run history | SQLite | Time-series queries |

**Rule of thumb:**
- If humans might edit it → File
- If it needs complex queries → SQLite index
- If it's large content → File (store path in SQLite)
- Content lives in files; metadata/state lives in SQLite

---

## 9. Initialization

### 9.1 First-Run Mount Setup

```typescript
async function initializeMount(mountPath: string): Promise<void> {
  // Create directory structure
  await fs.mkdir(mountPath, { recursive: true });
  await fs.mkdir(path.join(mountPath, "personas"));
  await fs.mkdir(path.join(mountPath, "projects"));
  await fs.mkdir(path.join(mountPath, "logs"));

  // Copy built-in personas
  await copyBuiltinPersonas(path.join(mountPath, "personas"));

  // Create empty config
  await fs.writeFile(
    path.join(mountPath, "config.json"),
    JSON.stringify({ version: "1.0.0" }, null, 2)
  );

  // Initialize SQLite
  await initializeDatabase(path.join(mountPath, "bonsai.db"));

  // Initialize git (using execFile for safety)
  await execFile("git", ["init"], { cwd: mountPath });
  await fs.writeFile(path.join(mountPath, ".gitignore"), GITIGNORE_CONTENT);
  await execFile("git", ["add", "-A"], { cwd: mountPath });
  await execFile("git", ["commit", "-m", "init: initialize bonsai mount"], { cwd: mountPath });
}
```

### 9.2 Mount Validation

On app startup, validate the mount:

```typescript
async function validateMount(mountPath: string): Promise<MountStatus> {
  const checks = {
    exists: await fs.pathExists(mountPath),
    isGitRepo: await fs.pathExists(path.join(mountPath, ".git")),
    hasConfig: await fs.pathExists(path.join(mountPath, "config.json")),
    hasDatabase: await fs.pathExists(path.join(mountPath, "bonsai.db")),
    hasPersonas: await fs.pathExists(path.join(mountPath, "personas")),
  };

  if (Object.values(checks).every(Boolean)) {
    return { valid: true };
  }

  return { valid: false, missing: checks };
}
```

---

## 10. Security Considerations

| File | Protection |
|------|------------|
| `vault-key.txt` | Mode 0600, gitignored, never committed |
| `vault.age` | Encrypted with age, safe to commit |
| `bonsai.db` | Contains metadata only, not secrets |
| `projects/` | May contain sensitive code — in project git, not mount git |

**Critical:** The `vault-key.txt` must never be committed to git. The `.gitignore` excludes it, but this is a critical security boundary.
