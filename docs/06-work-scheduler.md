# Bonsai Work Scheduler — Design Document

Date: 2026-02-04

> **Architecture note (2026-02-04):** Bonsai is fully self-contained. There is no OpenClaw Gateway, no WebSocket RPC, and no persistent slot manager. The scheduler IS the heartbeat: `cron`/`launchd` fires `bonsai heartbeat`, which queries SQLite for actionable tickets, picks the highest priority, runs the agent in-process via AgentRunner, writes results back to SQLite and the filesystem, and exits. All agent-human communication happens via comments on tickets. Some design patterns in this doc trace their extraction origin to OpenClaw, but Bonsai has zero runtime dependency on OpenClaw. See `13-agent-runtime.md` for the heartbeat implementation and `14-tool-system.md` for the tool system.

## Overview

Bonsai manages multiple projects, each with multiple tickets in various states. API rate limits and local resources (RAM, CPU, Docker containers) limit how many agents can run concurrently. The **Work Scheduler** -- which is the heartbeat process itself -- orchestrates agent work across all projects, ensuring fair resource distribution while respecting priorities.

**Core problem:** You have 10 projects with 50 tickets total, but can only run 1-2 agents per heartbeat cycle. How do you cycle through the work?

**Core answer:** Each heartbeat cycle: query DB for actionable tickets, sort by priority, run the top N agents (bounded by resource limits), update DB, exit. The next heartbeat repeats the cycle.

---

## 1. Resource Model

### 1.1 Agent Memory Footprint

Each active agent consumes resources:

| Component | Memory | Notes |
|-----------|--------|-------|
| Node.js process | ~50 MB | Base overhead |
| Agent context | ~100-500 MB | Depends on context window |
| Memory search index | ~50-200 MB | Per-agent SQLite + embeddings |
| Tool sandbox (Docker) | ~200-500 MB | If using Docker sandbox |

**Conservative estimate:** ~500 MB per active agent

### 1.2 Concurrency Limits

```typescript
interface ResourceLimits {
  maxConcurrentAgents: number;  // e.g., 2-4 based on RAM
  maxAgentsPerProject: number;  // Usually 1
  reservedMemoryMB: number;     // Leave headroom for OS/apps
}

function calculateMaxAgents(totalRAM: number): number {
  const reservedMB = 2048;  // 2 GB for OS + other apps
  const perAgentMB = 500;
  const availableMB = totalRAM - reservedMB;
  return Math.max(1, Math.floor(availableMB / perAgentMB));
}

// 8 GB RAM -> 12 agents max (but we cap lower for responsiveness)
// 16 GB RAM -> 28 agents max
// Practical cap: 4 concurrent agents (context switches have overhead)
```

### 1.3 Agent Lifecycle in Heartbeat Model

```
  launchd/cron           Heartbeat Process
  fires timer   --->   +------------------+
                       | 1. Read SQLite   |
                       | 2. Find work     |
                       | 3. Run agent(s)  |
                       | 4. Write results |
                       | 5. Exit          |
                       +------------------+
                              |
                       (process exits cleanly)
                              |
  timer fires again --> (repeat)
```

Each agent within a heartbeat cycle is **ephemeral** -- it loads, does work, writes results, and its state is persisted to the filesystem. There are no persistent slots or long-running processes.

---

## 2. Work Queue Model

### 2.1 Actionable Ticket Query

Each heartbeat cycle queries SQLite for tickets that need agent work:

```typescript
async function findActionableTickets(): Promise<WorkItem[]> {
  const items: WorkItem[] = [];

  for (const project of await db.projects.list()) {
    const tickets = await db.tickets.listByProject(project.id);

    for (const ticket of tickets) {
      // Skip if agent already working on this ticket (from another heartbeat)
      if (ticket.hasActiveAgent) continue;

      // Skip states that don't need agent work
      if (ticket.state === "backlog" || ticket.state === "done") continue;
      if (ticket.state === "ready") continue;  // Waiting for human to start

      // Determine task type
      let taskType: WorkItem["taskType"] | null = null;

      if (ticket.state === "research") {
        if (!ticket.researchComplete) {
          taskType = "research";
        } else if (ticket.hasUnresolvedHumanComments) {
          taskType = "respond_to_comments";
        }
      } else if (ticket.state === "in_progress") {
        if (ticket.waitingForHuman) {
          continue;  // Can't proceed without human input
        } else if (ticket.hasUnresolvedHumanComments) {
          taskType = "respond_to_comments";
        } else if (ticket.hasPendingTodoItems) {
          taskType = ticket.lastAgentWorkAt ? "continue_work" : "implement";
        }
      }

      if (taskType) {
        items.push({
          id: `${ticket.id}-${taskType}`,
          projectId: project.id,
          ticketId: ticket.id,
          taskType,
          priority: calculatePriority(ticket, project),
          agentId: project.agentId,
        });
      }
    }
  }

  // Sort by priority descending
  items.sort((a, b) => b.priority - a.priority);
  return items;
}
```

### 2.2 Priority Calculation

```typescript
function calculatePriority(ticket: Ticket, project: Project): number {
  let priority = 0;

  // Base priority by state (In Progress > Research > Ready)
  const statePriority: Record<TicketState, number> = {
    "in_progress": 1000,
    "research": 500,
    "ready": 100,
    "backlog": 0,
    "done": 0,
  };
  priority += statePriority[ticket.state];

  // Boost for human interaction (agent asked question, human responded)
  if (ticket.hasUnresolvedAgentQuestion) {
    priority += 200;  // Agent is blocked, human answered -- high priority
  }

  // Boost for recent human activity
  const hoursSinceHumanActivity = (Date.now() - ticket.lastHumanActivityAt) / (1000 * 60 * 60);
  if (hoursSinceHumanActivity < 1) {
    priority += 150;  // Human is actively engaged
  } else if (hoursSinceHumanActivity < 4) {
    priority += 50;
  }

  // Ticket-level priority override
  priority += ticket.priorityBoost ?? 0;  // User can manually boost

  // Project-level priority
  priority += project.priorityBoost ?? 0;

  // Starvation prevention: boost tickets that haven't been worked on
  const hoursSinceAgentWork = (Date.now() - ticket.lastAgentWorkAt) / (1000 * 60 * 60);
  if (hoursSinceAgentWork > 24) {
    priority += 100;  // Prevent indefinite starvation
  }

  return priority;
}
```

### 2.3 Work Item Interface

```typescript
interface WorkItem {
  id: string;
  projectId: string;
  ticketId: string;
  taskType: "research" | "respond_to_comments" | "implement" | "continue_work";
  priority: number;        // Higher = more urgent
  agentId: string;         // Which agent handles this project
}
```

---

## 3. Heartbeat Scheduler

### 3.1 Architecture

The scheduler is the heartbeat itself. There is no separate long-running scheduler process, no persistent slots, no WebSocket connections.

```
  launchd/systemd timer (every 60s)
            |
            v
  +-------------------------------------------+
  |          bonsai heartbeat                  |
  +-------------------------------------------+
  |                                           |
  |  1. Query SQLite for actionable tickets   |
  |  2. Calculate priorities                  |
  |  3. Pick top N (bounded by resources)     |
  |  4. For each: lock ticket, run agent      |
  |  5. Agent reads ticket, does work         |
  |  6. Agent writes results (comments,       |
  |     code, commits) via ToolExecutor       |
  |  7. Unlock ticket, update lastAgentWorkAt |
  |  8. Exit                                  |
  |                                           |
  +-------------------------------------------+
            |
      (process exits)
```

See `13-agent-runtime.md` for the full heartbeat implementation, including the AgentRunner and ToolExecutor abstraction boundaries.

### 3.2 Heartbeat Entry Point

```typescript
/**
 * Main heartbeat entry point. Called by cron/launchd every 60 seconds.
 * Finds actionable work, runs agents, writes results, exits.
 */
async function heartbeat(): Promise<void> {
  const config = await loadConfig();  // ~/.bonsai/config.json
  const maxAgents = resolveMaxConcurrentAgents(config);

  // 1. Clean up any stale locks (from crashed previous heartbeats)
  await recoverStaleLocks();

  // 2. Find actionable tickets, sorted by priority
  const workItems = await findActionableTickets();

  if (workItems.length === 0) {
    return;  // Nothing to do, exit cleanly
  }

  // 3. Pick top N items, ensuring no duplicate agents
  const selectedWork = selectWork(workItems, maxAgents);

  // 4. Run agents concurrently (bounded)
  await Promise.all(
    selectedWork.map(async (work) => {
      await lockTicket(work.ticketId);
      try {
        await runAgentForTicket(work);
      } finally {
        await unlockTicket(work.ticketId);
      }
    })
  );
}

function selectWork(items: WorkItem[], maxAgents: number): WorkItem[] {
  const selected: WorkItem[] = [];
  const usedAgents = new Set<string>();

  for (const item of items) {
    if (selected.length >= maxAgents) break;

    // One agent can only work on one ticket at a time
    if (usedAgents.has(item.agentId)) continue;

    selected.push(item);
    usedAgents.add(item.agentId);
  }

  return selected;
}
```

### 3.3 Running an Agent for a Ticket

```typescript
async function runAgentForTicket(work: WorkItem): Promise<void> {
  const ticket = await db.tickets.findById(work.ticketId);
  const project = await db.projects.findById(work.projectId);

  // Build the prompt for this task type
  const prompt = buildAgentPrompt(ticket, work.taskType);

  // Run the agent in-process via AgentRunner
  // See 13-agent-runtime.md for AgentRunner details
  const result = await agentRunner.run({
    agentId: work.agentId,
    projectPath: project.localPath,
    prompt,
    sessionDir: `~/.bonsai/agents/${work.agentId}/sessions/`,
    timeout: config.heartbeat.agentTimeoutMs,
  });

  // Update ticket state based on result
  await db.tickets.update(work.ticketId, {
    lastAgentWorkAt: new Date(),
    hasActiveAgent: false,
  });

  // Record the agent run
  await db.agentRuns.create({
    ticketId: work.ticketId,
    task: work.taskType,
    status: result.status,  // "completed" | "blocked" | "failed"
    startedAt: result.startedAt,
    completedAt: result.completedAt,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  });
}
```

### 3.4 Agent Prompt Construction

```typescript
function buildAgentPrompt(ticket: Ticket, taskType: TaskType): string {
  const baseContext = `
## Current Task
You are working on ticket: ${ticket.title}

## Ticket State
State: ${ticket.state}
Type: ${ticket.type}

## Description
${ticket.description}

## Acceptance Criteria
${ticket.acceptanceCriteria.map(c => `- [ ] ${c.text}`).join("\n")}
`;

  switch (taskType) {
    case "research":
      return `${baseContext}

## Your Task
Research this ticket and create:
1. research.md - Your findings from exploring the codebase and external resources
2. implementation-plan.md - Detailed plan for implementing this feature

When complete, add a comment summarizing your findings and mark both documents as ready.
`;

    case "respond_to_comments":
      return `${baseContext}

## Your Task
The human has left comments that need your response:

${ticket.unresolvedComments.map(c => `
### Comment on ${c.anchor}:
${c.text}
`).join("\n")}

Please respond to each comment via ticket comments and update your documents if needed.
`;

    case "implement":
    case "continue_work":
      return `${baseContext}

## Your Task
Implement this ticket according to the approved plan.

## Research
${ticket.researchDocument}

## Implementation Plan
${ticket.implementationPlan}

## TODO Progress
${ticket.todoItems.map(t => `- [${t.done ? "x" : " "}] ${t.text}`).join("\n")}

Continue working through the TODO items. Commit your changes as you go.
When blocked or uncertain, add a comment on this ticket and wait for human input.
When complete, push to a feature branch and move the ticket to verification.
`;
  }
}
```

---

## 4. Stale Lock Recovery

If a previous heartbeat crashes mid-run, tickets may be left in a locked state. Each heartbeat starts by cleaning these up.

```typescript
async function recoverStaleLocks(): Promise<void> {
  const staleThresholdMs = 45 * 60 * 1000;  // 45 minutes

  const lockedTickets = await db.tickets.list({
    where: { hasActiveAgent: true },
  });

  for (const ticket of lockedTickets) {
    const lockAge = Date.now() - (ticket.agentLockedAt?.getTime() ?? 0);

    if (lockAge > staleThresholdMs) {
      await db.tickets.update(ticket.id, {
        hasActiveAgent: false,
        activeSlotId: null,
      });
    }
  }
}
```

---

## 5. Fairness and Starvation Prevention

### 5.1 Project Round-Robin

To prevent one project from monopolizing resources:

```typescript
class FairnessTracker {
  private projectLastServed: Map<string, Date> = new Map();

  adjustPriority(item: WorkItem, basePriority: number): number {
    const lastServed = this.projectLastServed.get(item.projectId);

    if (!lastServed) {
      // Never served -- boost priority
      return basePriority + 200;
    }

    const hoursSinceServed = (Date.now() - lastServed.getTime()) / (1000 * 60 * 60);

    // Boost based on time since last served
    return basePriority + Math.min(hoursSinceServed * 50, 300);
  }

  recordServed(projectId: string): void {
    this.projectLastServed.set(projectId, new Date());
  }
}
```

### 5.2 Starvation Prevention via Priority Aging

Tickets that have not been worked on for extended periods receive a priority boost (see `calculatePriority` in section 2.2). The `hoursSinceAgentWork > 24` check adds +100 priority, ensuring no ticket is starved indefinitely even when higher-priority work dominates.

---

## 6. State Persistence

### 6.1 Two Data Layers

Bonsai uses two data layers for all state:

| State | Storage | Layer |
|-------|---------|-------|
| Ticket state, priority, locks | `~/.bonsai/bonsai.db` (SQLite) | Structured state |
| Agent sessions | `~/.bonsai/agents/{id}/sessions/` | Filesystem |
| Agent memory | `~/.bonsai/agents/{id}/memory/` | Filesystem |
| Work artifacts (code, docs) | `~/.bonsai/projects/{name}/` | Filesystem |
| Agent run history | `~/.bonsai/bonsai.db` (SQLite) | Structured state |
| Project configuration | `~/.bonsai/bonsai.db` (SQLite) | Structured state |

### 6.2 No In-Memory State Between Heartbeats

Because the heartbeat process exits after each cycle, there is no in-memory state to lose. All state lives in SQLite or on the filesystem. This makes the system inherently crash-safe -- if a heartbeat crashes, the next one picks up from the persisted state.

---

## 7. Configuration

### 7.1 Auto-Detection at Install Time

During first-run setup, Bonsai detects machine specs and sets a recommended `maxConcurrentAgents`:

```typescript
import os from "node:os";

function detectRecommendedConcurrency(): number {
  const totalMemMB = os.totalmem() / (1024 * 1024);
  const cpuCores = os.cpus().length;

  // Memory-based calculation
  const reservedMB = 2048;  // Leave 2 GB for OS + apps
  const perAgentMB = 500;   // ~500 MB per active agent
  const memoryBasedMax = Math.floor((totalMemMB - reservedMB) / perAgentMB);

  // CPU-based cap (don't exceed physical cores / 2)
  const cpuBasedMax = Math.max(1, Math.floor(cpuCores / 2));

  // Practical cap for responsiveness
  const practicalCap = 4;

  const recommended = Math.min(memoryBasedMax, cpuBasedMax, practicalCap);
  return Math.max(1, recommended);  // At least 1
}

// Example results:
// MacBook Air M1 (8 GB, 8 cores) -> 2
// MacBook Pro M3 (16 GB, 12 cores) -> 3
// Desktop (32 GB, 16 cores) -> 4
// Server (64 GB, 32 cores) -> 4 (capped)
```

### 7.2 User Override

The auto-detected value can be overridden in Settings:

```
+-------------------------------------------------------------------+
|  Settings > Performance                                            |
+-------------------------------------------------------------------+
|                                                                     |
|  Concurrent Agents                                                  |
|  +---------------------------------------------------------------+ |
|  |  (*) Auto (recommended: 2)                                    | |
|  |  ( ) Manual: [ 3 v ]                                          | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  More agents = faster parallel work, but uses more RAM.             |
|  Your machine has 16 GB RAM and 12 CPU cores.                       |
|                                                                     |
|  Setting above 4 may cause slowdowns.                               |
|                                                                     |
+-------------------------------------------------------------------+
```

### 7.3 Config Schema

In `~/.bonsai/config.json`:
```json
{
  "heartbeat": {
    "intervalSeconds": 60,
    "maxConcurrentAgents": "auto",
    "detectedConcurrency": 2,
    "agentTimeoutMs": 1800000,
    "starvationBoostHours": 24
  }
}
```

**Resolution logic:**
```typescript
function resolveMaxConcurrentAgents(config: HeartbeatConfig): number {
  if (config.maxConcurrentAgents === "auto") {
    return config.detectedConcurrency;
  }
  // User override -- clamp to safe range
  return Math.min(8, Math.max(1, config.maxConcurrentAgents));
}
```

### 7.4 Reference Table

| RAM | CPU Cores | Auto Value | Safe Override Range |
|-----|-----------|------------|---------------------|
| 8 GB | 4-8 | 1-2 | 1-2 |
| 16 GB | 8-12 | 2-3 | 1-4 |
| 32 GB | 12-16 | 3-4 | 1-6 |
| 64 GB+ | 16+ | 4 | 1-8 |

---

## 8. Observability

### 8.1 Heartbeat Status API

```typescript
// GET /api/heartbeat/status
{
  "status": "idle",           // "idle" | "running" | "error"
  "lastRunAt": "2026-02-04T10:30:00Z",
  "lastRunDurationMs": 45200,
  "activeAgents": [
    {
      "project": "my-app",
      "ticket": "Add OAuth login",
      "taskType": "implement",
      "startedAt": "2026-02-04T10:30:05Z"
    }
  ],
  "queue": {
    "length": 5,
    "top": [
      { "project": "api-service", "ticket": "Fix rate limiting", "priority": 1150 },
      { "project": "frontend", "ticket": "Responsive nav", "priority": 850 }
    ]
  },
  "stats": {
    "workCompletedToday": 12,
    "averageWorkDurationMs": 420000,
    "projectsWithPendingWork": 4,
    "heartbeatsToday": 1440
  }
}
```

### 8.2 UI Dashboard

```
+-------------------------------------------------------------------+
|  Work Scheduler                                    Heartbeat: 60s  |
+-------------------------------------------------------------------+
|                                                                     |
|  Last Heartbeat: 2 min ago (ran 1 agent, 45s)                      |
|                                                                     |
|  Currently Running                                                  |
|  +---------------------------------------------------------------+ |
|  | [green] my-app       | Add OAuth login      | Implementing    | |
|  |                      |                       | 5m 42s          | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  Queue (5 items)                                                    |
|  +---------------------------------------------------------------+ |
|  | 1. api-service   | Fix rate limiting    | Priority: 1150      | |
|  | 2. frontend      | Responsive nav       | Priority: 850       | |
|  | 3. my-app        | Password reset flow  | Priority: 650       | |
|  | ...                                                             | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  Today: 12 tasks completed | Avg duration: 7m                      |
|                                                                     |
+-------------------------------------------------------------------+
```

---

## 9. Key Design Decisions

### Why Heartbeat Instead of Long-Running Scheduler

| Concern | Heartbeat Model | Long-Running Scheduler |
|---------|-----------------|----------------------|
| **Crash recovery** | Automatic -- next heartbeat picks up | Requires restart logic, orphan detection |
| **Memory leaks** | Impossible -- process exits each cycle | Accumulates over time |
| **State management** | All in SQLite/filesystem | Mix of in-memory and persisted |
| **Process management** | launchd/systemd handles it | Needs PM2 or similar |
| **Complexity** | Simple -- one function, one path | Event loops, WebSocket connections, reconnection logic |
| **Debuggability** | Run `bonsai heartbeat` manually | Attach debugger to running process |

### Why No Gateway RPC

The original OpenClaw architecture (extraction origin) used a WebSocket Gateway for agent dispatch. Bonsai eliminates this because:

1. **No multi-client need** -- Bonsai is single-user, no Discord/Slack/Telegram channels
2. **No streaming UI** -- agents communicate via ticket comments, not real-time chat
3. **Simpler failure modes** -- no WebSocket reconnection, no gateway health checks
4. **In-process execution** -- AgentRunner runs directly, no RPC serialization overhead

See `13-agent-runtime.md` for the AgentRunner/ToolExecutor/WorkspaceProvider abstraction boundaries that enable future containerization without needing a gateway.

---

## 10. Future Enhancements

1. **Agent teams** -- Multiple personas working on the same ticket in parallel (see [15-agent-teams.md](./15-agent-teams.md))
2. **Distributed scheduling** -- Multiple machines with shared queue (SQLite -> Postgres)
3. **Agent pooling** -- Keep warm agents for faster startup (trade memory for latency)
4. **Work estimation ML** -- Predict task duration for better scheduling
5. **Priority learning** -- Learn which tickets need faster response based on patterns
6. **Resource-aware scheduling** -- Docker availability, GPU, etc.
7. **Containerized agents** -- Run agents in Docker via WorkspaceProvider (see `14-tool-system.md`)
