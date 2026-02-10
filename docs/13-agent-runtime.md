# Bonsai Agent Runtime — Design Document

Date: 2026-02-04 (updated 2026-02-05)

## Overview

The agent runtime is the background system that does the actual work. It runs on a heartbeat — a periodic trigger (cron, launchd, systemd timer) that wakes the system, lets agents work, and exits. There is no long-running agent daemon.

Agents are autonomous. They pick tickets from their board, push work toward completion, communicate with humans via comments on tickets, and move tickets to verification when acceptance criteria are met. The human's role is to define work and review results.

**Key constraints:**
- Must work on macOS and Linux from day one, Windows eventually
- No persistent background process for agent work — wake, work, exit
- All inter-user/agent communication happens via comments on tickets
- Architecture must support adding container/workspace security later without rewrite

**Two processes, loosely coupled through SQLite:**
- **Web app** (Next.js, always running) — the entire UI for settings, projects, tickets, comments, onboarding, docs, status. See [12-technology-stack.md](./12-technology-stack.md).
- **Heartbeat** (cron/launchd/systemd, periodic) — wakes, reads DB, runs agents, writes results, exits. Stateless between invocations.

**Two data layers:**
- **SQLite** (structured state) — projects, tickets, comments, agent runs, config
- **Filesystem** (content + artifacts) — git repos, session transcripts, SOUL.md, logs

---

## 1. Heartbeat Model

### How It Works

A system-level scheduler fires `bonsai heartbeat` at a fixed interval (default: every 60 seconds). Each invocation is a short-lived process:

```
cron/launchd/systemd fires
  → bonsai heartbeat
    → acquire lock (~/.bonsai/heartbeat.lock)
    → read DB: find tickets that need agent work
    → for each active project with work to do:
        → resolve workspace
        → pick highest priority ticket
        → run agent (LLM loop + tool execution)
        → write results to DB
        → write comments if needed
    → release lock
    → exit
```

### Why Not a Daemon

| Concern | Daemon | Heartbeat |
|---------|--------|-----------|
| Crash recovery | Must implement restart logic, watchdog | Next cron tick picks up naturally |
| Memory | Holds agent state in RAM between runs | Fresh process each time, no leaks |
| Complexity | Process management, signal handling, health checks | Just a CLI command |
| Platform support | Different daemon patterns per OS | Cron/launchd/systemd all trigger the same command |
| Debugging | Attach to running process | Read logs, run manually |

The web app (Next.js) is the only long-running process. Agent work is batch-processed.

### Lock File

Prevents overlapping heartbeats when a previous run is still working:

```typescript
import { open, readFile, unlink } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";

async function acquireHeartbeatLock(): Promise<FileHandle | null> {
  const lockPath = join(bonsaiDir, "heartbeat.lock");
  try {
    const handle = await open(lockPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL);
    await handle.write(String(process.pid));
    return handle;
  } catch {
    // Lock exists — check if owning process is alive
    const pid = parseInt(await readFile(lockPath, "utf-8"), 10);
    if (!isProcessAlive(pid)) {
      await unlink(lockPath);
      return acquireHeartbeatLock(); // Retry once
    }
    return null; // Another heartbeat is running
  }
}
```

### Heartbeat Duration

Each beat is capped. If the agent is mid-work when the cap hits, it saves a checkpoint (the LLM session transcript persists on disk) and exits. The next beat resumes.

| Setting | Default | Notes |
|---------|---------|-------|
| `heartbeat.intervalSec` | 60 | How often the trigger fires |
| `heartbeat.maxDurationSec` | 1800 (30 min) | Hard cap per beat |
| `heartbeat.maxConcurrentAgents` | auto (based on RAM) | How many projects to work in parallel per beat |

---

## 2. Agent Autonomy

### What Agents Do

Agents are workers, not assistants. They don't wait for instructions — they have a board and they work it.

Each heartbeat, an agent:

1. **Reads its board** — queries tickets assigned to it (or unassigned in its project)
2. **Picks work** by priority:
   - Tickets with unresolved human comments (highest — human is waiting)
   - Tickets in IN_PROGRESS with pending work
   - Tickets in RESEARCH that need exploration
   - Unassigned tickets it can pick up
3. **Works the ticket** based on its state:
   - **RESEARCH** — explore codebase, read docs, write a plan, move to IN_PROGRESS
   - **IN_PROGRESS** — implement, write tests, commit, push. Check acceptance criteria.
   - **Returned from VERIFICATION** — read human feedback, address it, resubmit
4. **Communicates via comments** — asks questions, posts status updates, responds to feedback
5. **Moves the ticket forward** — when all acceptance criteria are met, moves to VERIFICATION

### Ticket Lifecycle

```
BACKLOG → RESEARCH → IN_PROGRESS → VERIFICATION → DONE
 human     agent       agent         human         human
 creates   explores    implements    reviews       accepts
 ticket    codebase    + tests       the work      or rejects
           + plans     + commits
                       + pushes
```

The agent pushes tickets rightward. The human creates, reviews, and accepts.

### Comments as Communication

There is no chat interface. All agent-human communication is comments on tickets.

**Agent → Human:**
- Questions when blocked: "The spec doesn't define error format — should I use RFC 9457 problem+json?"
- Status updates: "Implemented auth flow. Tests passing. Working on edge cases next."
- Completion notes: "All acceptance criteria met. PR #42 ready for review."

**Human → Agent:**
- Answers to questions: "Use problem+json."
- Feedback on work: "The error messages are too technical for end users."
- Direction changes: "Switch from REST to GraphQL for this endpoint."

**Priority impact:**

| Comment scenario | Agent behavior |
|-----------------|----------------|
| Human replied to agent's question | Top priority — unblock and resume |
| Human left feedback on VERIFICATION ticket | High priority — address and resubmit |
| Agent left question, no reply yet | Skip this ticket, work on something else |
| No comments, work in progress | Normal priority — continue |

When an agent is blocked, it leaves a comment and moves to the next ticket. It never sits idle.

---

## 3. Tech Stack

### Runtime

| Component | Technology | Notes |
|-----------|------------|-------|
| Language | TypeScript (ESM) | Same as web app |
| Runtime | Node.js 22+ | Native SQLite, fs/promises |
| CLI framework | Commander 14 | `bonsai heartbeat`, `bonsai status`, etc. |
| Database | SQLite via Prisma | Shared DB with web app (`~/.bonsai/bonsai.db`) |
| Logging | tslog | Writes to `~/.bonsai/logs/` |
| LLM SDK | @anthropic-ai/sdk | Anthropic first, multi-provider later |
| Agent loop | Extracted from OpenClaw | `pi-embedded-runner` conversation loop |
| Tool dispatch | Extracted from OpenClaw | Tool system with ToolExecutor abstraction |
| Git | git CLI via ToolExecutor | Worktree management, commits, pushes |
| Config | Zod schemas | Validated config at `~/.bonsai/config.json` |

### Primary Reference: NanoClaw

NanoClaw (https://github.com/gavrielc/nanoclaw) is a 3,174-line Claude assistant that runs agents in isolated containers using Claude Agent SDK. It solves many of the same problems Bonsai needs — container isolation, agent execution, task scheduling, filesystem IPC — in a minimal codebase. See [AGENT_EXTRACT_TODO.md](./AGENT_EXTRACT_TODO.md) for detailed extraction mapping.

| NanoClaw Component | Lines | Bonsai Uses |
|-------------------|-------|-------------|
| Container runner (`container-runner.ts`) | 489 | Container isolation for agent execution |
| Agent runner (`container/agent-runner/src/index.ts`) | 289 | Claude Agent SDK `query()` integration |
| IPC MCP server (`container/agent-runner/src/ipc-mcp.ts`) | 321 | Agent-to-host communication |
| Task scheduler (`task-scheduler.ts`) | 178 | Reference for heartbeat scheduling |
| Mount security (`mount-security.ts`) | 413 | Filesystem security model |

### Secondary Reference: OpenClaw

OpenClaw (https://github.com/openclaw/openclaw) has more comprehensive infrastructure if needed:

| Component | OpenClaw Source | What Bonsai Uses |
|-----------|----------------|-----------------|
| Agent runner | `src/agents/pi-embedded-runner/` | LLM conversation loop, tool dispatch |
| Tool system | `src/agents/pi-tools.ts` | Tool definitions, execution framework |
| System prompt builder | `src/agents/system-prompt.ts` | Prompt assembly from components |
| Session management | `src/config/sessions/` | Transcript persistence between heartbeats |

### Key Dependencies

| Package | Role | Decision |
|---------|------|----------|
| `@anthropic-ai/claude-agent-sdk` | Agent execution (used by NanoClaw) | **Primary** — use directly |
| `@anthropic-ai/sdk` | Anthropic API client | Depend |
| `@mariozechner/pi-coding-agent` | OpenClaw session/tool dispatch | Evaluate — may not need if using Agent SDK directly |
| `@mariozechner/pi-ai` | LLM provider abstraction | Evaluate — may not need if using Agent SDK directly |

---

## 4. Abstraction Boundaries

These interfaces exist from day one. V1 has simple implementations. V2 swaps in secure ones. The agent runner never changes.

### 4.1 ToolExecutor

All agent tool execution goes through this interface. The agent never touches the filesystem or spawns processes directly.

```typescript
interface ExecOpts {
  cwd: string;
  timeout?: number;
  env?: Record<string, string>;
}

interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

interface ToolExecutor {
  exec(cmd: string, args: string[], opts: ExecOpts): Promise<ExecResult>;
  readFile(path: string): Promise<string>;
  writeFile(path: string, content: string): Promise<void>;
  listFiles(pattern: string): Promise<string[]>;
  fileExists(path: string): Promise<boolean>;
}
```

**V1: `LocalToolExecutor`**
- `exec()` → `execFile()` (not `exec()` — avoids shell injection) with `cwd` set to project directory
- Path validation: reject paths outside project root (no `../` traversal)
- File ops: `node:fs/promises` scoped to project directory

**V2: `DockerToolExecutor`**
- `exec()` → `docker exec <container> <cmd>`
- File ops → `docker exec <container> cat/tee` or volume mount
- Full filesystem isolation — the container only has the project workspace

**V3 (future): `RemoteToolExecutor`**
- Same interface, execution happens on a remote machine
- Enables distributed agent workers

### 4.2 WorkspaceProvider

Resolves where a project's code lives and how to execute commands there.

```typescript
interface Workspace {
  projectId: string;
  rootPath: string;
  executor: ToolExecutor;
  branch: string;
  remote: string;
}

interface WorkspaceProvider {
  resolve(projectId: string): Promise<Workspace>;
  cleanup(projectId: string): Promise<void>;
}
```

**V1: `LocalWorkspaceProvider`**
- `rootPath` → `~/.bonsai/projects/{slug}`
- `executor` → `LocalToolExecutor` scoped to that path
- `branch` → reads from git, creates worktree if needed

**V2: `ContainerWorkspaceProvider`**
- Ensures a Docker container exists for the project
- Mounts the repo into the container (or clones inside it)
- `executor` → `DockerToolExecutor` connected to that container
- Container has project-specific toolchain (language, deps) pre-installed

### 4.3 AgentRunner

The boundary between "decide what to do" and "do the work." Today it's an in-process function call. Tomorrow it could be a child process or a container entrypoint.

```typescript
interface AgentRunParams {
  projectId: string;
  ticketId: string;
  task: string;
  workspace: Workspace;
  systemPrompt: string;
  sessionDir: string;
  maxDurationMs: number;
}

interface AgentRunResult {
  status: "completed" | "blocked" | "timeout" | "error";
  comments: Array<{ content: string; type: "question" | "status" | "completion" }>;
  ticketStateChange?: string;
  tokensUsed: { input: number; output: number };
}

interface AgentRunner {
  run(params: AgentRunParams): Promise<AgentRunResult>;
}
```

**V1: `InProcessAgentRunner`**
- Calls the extracted LLM conversation loop directly
- Tools execute via the `workspace.executor`
- Session transcript persists to `sessionDir`

**V2: `IsolatedAgentRunner`**
- Spawns a child process for the agent run
- Or runs the agent loop inside the project's Docker container
- LLM API calls can originate from inside or outside the sandbox

### 4.4 Why These Boundaries Matter

Without them, v1 code ends up with:
- Process spawn calls scattered through the runner
- Hardcoded paths like `~/.bonsai/projects/${slug}/src/...`
- Agent code that assumes local filesystem access
- Git operations that assume they're running on the host

Adding containers later would require rewriting the runner, the tools, and the git operations. With the interfaces, you swap `LocalToolExecutor` for `DockerToolExecutor` and everything else stays the same.

---

## 5. Platform Support

### macOS (Day One)

**Heartbeat trigger:** launchd (LaunchAgent)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.bonsai.heartbeat</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BONSAI_BIN}</string>
    <string>heartbeat</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>StandardOutPath</key>
  <string>${HOME}/.bonsai/logs/heartbeat.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/.bonsai/logs/heartbeat.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>BONSAI_DATA_DIR</key>
    <string>${HOME}/.bonsai</string>
  </dict>
</dict>
</plist>
```

**Install location:** `~/Library/LaunchAgents/com.bonsai.heartbeat.plist`

**Management:**
```bash
bonsai service install    # writes plist, runs launchctl load
bonsai service uninstall  # launchctl unload, removes plist
bonsai service status     # launchctl list | grep bonsai
bonsai service logs       # tail ~/.bonsai/logs/heartbeat.*.log
```

**Web app:** Separate launchd service for `next start`, or user runs `bonsai start` manually.

### Linux (Day One)

**Heartbeat trigger:** systemd user timer

```ini
# ~/.config/systemd/user/bonsai-heartbeat.timer
[Unit]
Description=Bonsai agent heartbeat trigger

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
```

```ini
# ~/.config/systemd/user/bonsai-heartbeat.service
[Unit]
Description=Bonsai agent heartbeat

[Service]
Type=oneshot
ExecStart=${BONSAI_BIN} heartbeat
Environment=BONSAI_DATA_DIR=%h/.bonsai
Environment=PATH=/usr/local/bin:/usr/bin:/bin
StandardOutput=append:%h/.bonsai/logs/heartbeat.stdout.log
StandardError=append:%h/.bonsai/logs/heartbeat.stderr.log
```

**Install location:** `~/.config/systemd/user/`

**Management:**
```bash
bonsai service install    # writes unit files, systemctl --user enable --now
bonsai service uninstall  # systemctl --user disable --now, removes files
bonsai service status     # systemctl --user status bonsai-heartbeat.timer
bonsai service logs       # journalctl --user -u bonsai-heartbeat
```

**Web app:** Separate systemd user service for the Next.js server.

### Windows (Future)

**Heartbeat trigger:** Task Scheduler

```powershell
# Created by: bonsai service install
$action = New-ScheduledTaskAction -Execute "bonsai.exe" -Argument "heartbeat"
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "BonsaiHeartbeat" -Action $action -Trigger $trigger -Settings $settings
```

**What needs to change for Windows:**
- Path separator handling in WorkspaceProvider (`path.join` handles this)
- Lock file implementation (Windows file locking differs)
- Service install/uninstall commands
- Shell execution in ToolExecutor (PowerShell vs bash)
- Git operations work the same (git CLI is cross-platform)

**What doesn't change:**
- The heartbeat logic itself
- The AgentRunner interface and implementations
- The database layer (SQLite + Prisma work on Windows)
- The LLM API calls
- The comment system

### Platform Abstraction

```typescript
interface PlatformService {
  installHeartbeat(config: HeartbeatConfig): Promise<void>;
  uninstallHeartbeat(): Promise<void>;
  heartbeatStatus(): Promise<ServiceStatus>;
  logPath(): string;
}

function getPlatformService(): PlatformService {
  switch (process.platform) {
    case "darwin": return new MacOSLaunchdService();
    case "linux":  return new LinuxSystemdService();
    case "win32":  return new WindowsTaskSchedulerService();
    default:       throw new Error(`Unsupported platform: ${process.platform}`);
  }
}
```

Each platform service only handles the scheduling mechanism. The heartbeat command itself is identical across platforms.

---

## 6. Session Persistence

Agent work spans multiple heartbeats. A ticket that takes 2 hours of agent work might be spread across many beats. Session state must persist between them.

### What Persists

| Data | Storage | Survives restart |
|------|---------|-----------------|
| LLM conversation transcript | `~/.bonsai/sessions/{projectId}/{ticketId}/transcript.json` | Yes |
| Agent's working context | Encoded in the transcript (context compaction) | Yes |
| Ticket state changes | SQLite database | Yes |
| Comments written | SQLite database | Yes |
| Git commits/branches | Git repo on disk | Yes |
| In-flight tool execution | Lost — re-evaluated on next beat | No |

### Session Directory Layout

```
~/.bonsai/
├── bonsai.db                          # SQLite database
├── config.json                        # User config
├── heartbeat.lock                     # Prevents overlapping beats
├── logs/
│   ├── heartbeat.stdout.log
│   └── heartbeat.stderr.log
├── sessions/
│   ├── {projectId}/
│   │   ├── {ticketId}/
│   │   │   ├── transcript.json        # LLM conversation history
│   │   │   └── metadata.json          # Token counts, timestamps
│   │   └── .../
│   └── .../
└── projects/
    ├── {project-slug}/                # Cloned git repos
    └── .../
```

### Resume Behavior

When the agent picks up a ticket it previously worked on:

1. Load the transcript from `sessions/{projectId}/{ticketId}/`
2. The LLM sees the full conversation history (with context compaction if needed)
3. The agent continues where it left off — it knows what it already did
4. New tool calls and responses append to the transcript

This is handled by the extracted OpenClaw session management. The session key format:

```
bonsai:{projectId}:ticket:{ticketId}
```

---

## 7. Filesystem Layout

```
~/.bonsai/
├── bonsai.db                          # All Bonsai state (projects, tickets, comments, runs)
├── config.json                        # Validated by Zod schema
├── heartbeat.lock                     # PID lock file
├── web-token                          # Auth token for web UI (mode 0600)
├── logs/
│   ├── heartbeat.stdout.log           # Agent runtime logs
│   ├── heartbeat.stderr.log           # Agent runtime errors
│   └── web.log                        # Web app logs
├── sessions/
│   └── {projectId}/
│       └── {ticketId}/
│           ├── transcript.json
│           └── metadata.json
└── projects/
    ├── my-app/                        # Cloned repos
    ├── api-service/
    └── .../
```

All data under `~/.bonsai/`. Portable — back up this directory and you have everything.

---

## 8. Heartbeat Command

### CLI Interface

```bash
bonsai heartbeat              # Run one heartbeat cycle (cron calls this)
bonsai heartbeat --once       # Same as above, explicit
bonsai heartbeat --dry-run    # Show what work would be done, don't execute
bonsai status                 # Show current agent status, queue, recent runs
bonsai service install        # Install platform-specific heartbeat trigger
bonsai service uninstall      # Remove heartbeat trigger
bonsai service status         # Check if heartbeat is installed and running
bonsai service logs           # Tail heartbeat logs
```

### Heartbeat Flow

```typescript
async function heartbeat(opts: HeartbeatOpts): Promise<void> {
  const lock = await acquireHeartbeatLock();
  if (!lock) {
    log.info("Another heartbeat is running, skipping");
    return;
  }

  try {
    const startTime = Date.now();
    const maxDuration = config.heartbeat.maxDurationSec * 1000;

    const projects = await db.project.findMany({ where: { active: true } });

    for (const project of projects) {
      if (Date.now() - startTime > maxDuration) {
        log.info("Heartbeat duration cap reached, exiting");
        break;
      }

      const ticket = await pickTicket(project.id);
      if (!ticket) continue;

      const workspace = await workspaceProvider.resolve(project.id);
      const systemPrompt = buildSystemPrompt(project, ticket);
      const task = buildTask(ticket);

      await db.agentRun.create({
        data: {
          ticketId: ticket.id,
          task: task.type,
          status: "running",
          sessionKey: `bonsai:${project.id}:ticket:${ticket.id}`,
        },
      });

      const result = await agentRunner.run({
        projectId: project.id,
        ticketId: ticket.id,
        task: task.prompt,
        workspace,
        systemPrompt,
        sessionDir: join(bonsaiDir, "sessions", project.id, ticket.id),
        maxDurationMs: Math.min(
          maxDuration - (Date.now() - startTime),
          15 * 60 * 1000
        ),
      });

      await handleResult(ticket, result);
    }
  } finally {
    await releaseHeartbeatLock(lock);
  }
}
```

### Picking a Ticket

```typescript
async function pickTicket(projectId: string): Promise<Ticket | null> {
  // Priority 1: Tickets with unresolved human comments (human is waiting)
  const withHumanComments = await db.ticket.findFirst({
    where: {
      projectId,
      state: { in: ["RESEARCH", "IN_PROGRESS"] },
      comments: { some: { authorType: "human", resolved: false } },
    },
    orderBy: { updatedAt: "desc" },
  });
  if (withHumanComments) return withHumanComments;

  // Priority 2: Tickets returned from verification (human reviewed)
  const returnedFromVerification = await db.ticket.findFirst({
    where: {
      projectId,
      state: "IN_PROGRESS",
      subState: "returned",
    },
    orderBy: { updatedAt: "desc" },
  });
  if (returnedFromVerification) return returnedFromVerification;

  // Priority 3: Tickets in progress with pending work
  const inProgress = await db.ticket.findFirst({
    where: {
      projectId,
      state: "IN_PROGRESS",
      subState: { not: "blocked" },
    },
    orderBy: { updatedAt: "asc" }, // Oldest first (prevent starvation)
  });
  if (inProgress) return inProgress;

  // Priority 4: Tickets in research
  const research = await db.ticket.findFirst({
    where: {
      projectId,
      state: "RESEARCH",
    },
    orderBy: { createdAt: "asc" },
  });
  if (research) return research;

  return null;
}
```

### Handling Results

```typescript
async function handleResult(
  ticket: Ticket,
  result: AgentRunResult
): Promise<void> {
  // Write any comments the agent produced
  for (const comment of result.comments) {
    await db.comment.create({
      data: {
        ticketId: ticket.id,
        authorType: "agent",
        authorId: ticket.projectId,
        authorName: "Agent",
        content: comment.content,
        resolved: false,
      },
    });
  }

  // Update ticket state if agent moved it
  if (result.ticketStateChange) {
    await db.ticket.update({
      where: { id: ticket.id },
      data: { state: result.ticketStateChange as TicketState },
    });
  }

  // Record the run
  await db.agentRun.updateMany({
    where: { ticketId: ticket.id, status: "running" },
    data: {
      status: result.status,
      completedAt: new Date(),
      inputTokens: result.tokensUsed.input,
      outputTokens: result.tokensUsed.output,
    },
  });
}
```

---

## 9. V1 vs V2 Comparison

| Concern | V1 (Minimal) | V2 (Secure) |
|---------|-------------|-------------|
| Tool execution | `LocalToolExecutor` — execFile on host, path validation | `DockerToolExecutor` — docker exec in container |
| Workspace | Local directory under `~/.bonsai/projects/` | Docker volume or bind mount |
| Agent process | In-process function call | Child process or container entrypoint |
| Filesystem isolation | Path validation only (reject `../`) | Physical container boundary |
| Network isolation | None | Docker network policies |
| Dependency isolation | Shared host toolchain | Per-project container images |
| Git operations | Host git CLI | Git inside container |
| Platform | macOS + Linux | macOS + Linux + Windows |

### What V1 Must Not Do

To avoid making V2 a rewrite:

- **Never** let agent code spawn processes directly — always go through `ToolExecutor`
- **Never** hardcode filesystem paths in the runner — always resolve through `WorkspaceProvider`
- **Never** store mutable state inside project directories — use the database
- **Never** assume the agent runs on the same machine as the code — keep the execution boundary clean
- **Never** let the LLM see absolute paths — use project-relative paths in prompts and tool results

---

## 10. Dependencies

### Agent Runtime (new packages beyond web app)

```json
{
  "dependencies": {
    "@anthropic-ai/sdk": "^1.0.0",
    "@mariozechner/pi-coding-agent": "latest",
    "@mariozechner/pi-ai": "latest",
    "commander": "^14.0.0",
    "tslog": "^4.0.0"
  }
}
```

### Shared with Web App

```json
{
  "dependencies": {
    "@prisma/client": "^6.0.0",
    "zod": "^3.0.0"
  }
}
```

### Package Structure

The agent runtime and web app live in the same monorepo but are separate entry points:

```
bonsai/
├── package.json              # Workspace root
├── pnpm-workspace.yaml
├── apps/
│   ├── web/                  # Next.js web app
│   │   ├── package.json
│   │   └── ...
│   └── cli/                  # CLI + heartbeat + service management
│       ├── package.json
│       └── src/
│           ├── index.ts      # CLI entry (commander)
│           ├── heartbeat.ts  # Heartbeat command
│           ├── status.ts     # Status command
│           └── service/
│               ├── install.ts
│               ├── platform.ts
│               ├── launchd.ts
│               ├── systemd.ts
│               └── taskscheduler.ts
├── packages/
│   ├── core/                 # Shared types, DB client, config
│   │   ├── package.json
│   │   └── src/
│   │       ├── db.ts
│   │       ├── config.ts
│   │       └── types.ts
│   ├── agent/                # Agent runner, tools, session management
│   │   ├── package.json
│   │   └── src/
│   │       ├── runner.ts             # AgentRunner interface + InProcessAgentRunner
│   │       ├── tools/
│   │       │   ├── executor.ts       # ToolExecutor interface
│   │       │   ├── local.ts          # LocalToolExecutor
│   │       │   └── docker.ts         # DockerToolExecutor (v2, stubbed)
│   │       ├── workspace/
│   │       │   ├── provider.ts       # WorkspaceProvider interface
│   │       │   ├── local.ts          # LocalWorkspaceProvider
│   │       │   └── container.ts      # ContainerWorkspaceProvider (v2, stubbed)
│   │       ├── prompt.ts             # System prompt builder
│   │       └── session.ts            # Session persistence
│   └── platform/             # OS-specific service management
│       ├── package.json
│       └── src/
│           ├── service.ts
│           ├── launchd.ts
│           ├── systemd.ts
│           └── taskscheduler.ts
└── prisma/
    └── schema.prisma         # Shared database schema
```

---

## 11. Cross-References

| Topic | Document |
|-------|----------|
| Tool system (all tools, profiles, CLI tools) | [14-tool-system.md](./14-tool-system.md) |
| Extraction plan (NanoClaw + OpenClaw) | [AGENT_EXTRACT_TODO.md](./AGENT_EXTRACT_TODO.md) |
| Project isolation model | [01-project-isolation-architecture.md](./01-project-isolation-architecture.md) |
| Technical architecture | [02-technical-architecture.md](./02-technical-architecture.md) |
| Session management details | [03-agent-session-management.md](./03-agent-session-management.md) |
| Onboarding (heartbeat install) | [05-onboarding-wizard.md](./05-onboarding-wizard.md) |
| Scheduler / priority logic | [06-work-scheduler.md](./06-work-scheduler.md) |
| Technology stack + DB schema | [12-technology-stack.md](./12-technology-stack.md) |
| Personas | [09-personas.md](./09-personas.md) |
| Agent teams (multi-persona collaboration) | [15-agent-teams.md](./15-agent-teams.md) |
| UI design | [11-ui-design-spec.md](./11-ui-design-spec.md) |
