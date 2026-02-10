# Bonsai Agent Teams — Design Document

Date: 2026-02-06

> **Reference:** This design is informed by Claude Code's experimental [Agent Teams](https://code.claude.com/docs/en/agent-teams) feature. Bonsai adapts the core concepts — team lead, teammates, shared task lists, inter-agent messaging — to work within Bonsai's heartbeat model and persona system. Where Claude Code runs persistent interactive sessions, Bonsai teams operate across heartbeat cycles with all coordination state persisted to SQLite.

## Overview

Today, Bonsai assigns **one persona per ticket** — a single agent works the ticket from research through implementation. This works for focused tasks but falls short when a ticket benefits from parallel exploration, multi-perspective review, or cross-specialty collaboration.

**Agent Teams** let Bonsai coordinate **multiple personas working on the same ticket** (or across related tickets) with shared task lists and inter-agent messaging. One persona acts as **team lead**, breaking work into tasks and coordinating teammates. Teammates work independently, each in their own session and context window, and communicate through a structured mailbox system.

**Core problem:** A complex feature ticket touches frontend, backend, and tests. Today one agent does everything sequentially. With teams, a frontend persona, backend persona, and test persona work in parallel — coordinated by a lead — completing work faster and with domain-appropriate expertise.

**Core answer:** The heartbeat dispatcher detects team-eligible tickets, spawns team sessions, and coordinates teammates across heartbeat cycles. All team state lives in SQLite and the filesystem. No persistent daemon required.

---

## 1. Concept Mapping: Claude Code → Bonsai

| Claude Code Agent Teams | Bonsai Equivalent | Notes |
|------------------------|-------------------|-------|
| Team lead | **Project manager persona** (or designated lead persona) | Coordinates work, assigns tasks, synthesizes results |
| Teammate | **Work persona** (developer, reviewer, researcher, etc.) | Each teammate is a persona session scoped to specific tasks |
| Shared task list | **Team task list** (SQLite `team_tasks` table) | Tasks with status, assignment, dependencies, claimed via DB locks |
| Mailbox / messaging | **Team messages** (SQLite `team_messages` table) | Async message delivery between personas, read on next heartbeat |
| Spawn teammate | **Activate persona for team** | Load persona files, create team session, assign initial task |
| Split panes / in-process | **Board view team panel** | Web UI shows all active teammates and their progress |
| Team config file | **SQLite `teams` table** + filesystem | `~/.bonsai/teams/{teamId}/config.json` mirrors Claude Code's layout |
| Delegate mode | **Lead-only scheduling** | Lead persona restricted to coordination tools — no code changes |

### What Bonsai Adapts

Claude Code's agent teams are **interactive** — a human sits at the terminal, watches teammates work in real-time, and can message any teammate directly. Bonsai's teams are **autonomous** — they operate across heartbeat cycles without human presence, coordinating through persisted state. The human interacts through the web UI, reviewing progress and steering via comments.

### What Bonsai Preserves

- Each teammate gets its own **context window** (independent session)
- Teammates load the same **project context** (CLAUDE.md, persona files, workspace)
- Shared **task list** with dependency tracking and atomic claiming
- **Inter-agent messaging** for sharing findings and coordinating
- **Lead orchestration** — one persona breaks down work and synthesizes results

---

## 2. When to Use Agent Teams

### Automatic Team Detection

The heartbeat scheduler evaluates tickets for team eligibility based on signals:

```typescript
interface TeamEligibility {
  eligible: boolean;
  reason: string;
  suggestedTeamSize: number;
  suggestedRoles: string[];  // Persona IDs
}

function evaluateTeamEligibility(ticket: Ticket, project: Project): TeamEligibility {
  const signals: string[] = [];

  // Signal: Multiple acceptance criteria spanning different domains
  const domains = detectDomains(ticket.acceptanceCriteria);
  if (domains.size >= 3) {
    signals.push("multi-domain-criteria");
  }

  // Signal: Implementation plan references multiple subsystems
  if (ticket.implementationPlan) {
    const subsystems = extractSubsystems(ticket.implementationPlan);
    if (subsystems.length >= 3) {
      signals.push("multi-subsystem-plan");
    }
  }

  // Signal: Ticket explicitly tagged for team work
  if (ticket.labels?.includes("team")) {
    signals.push("explicit-team-label");
  }

  // Signal: Estimated complexity exceeds single-agent threshold
  if (ticket.estimatedComplexity === "high" || ticket.estimatedComplexity === "critical") {
    signals.push("high-complexity");
  }

  if (signals.length >= 2 || signals.includes("explicit-team-label")) {
    return {
      eligible: true,
      reason: signals.join(", "),
      suggestedTeamSize: Math.min(domains.size || 3, 5),
      suggestedRoles: suggestRoles(ticket, project),
    };
  }

  return { eligible: false, reason: "insufficient signals", suggestedTeamSize: 1, suggestedRoles: [] };
}
```

### Human-Initiated Teams

Humans can explicitly request team work through the ticket UI:

```
┌─────────────────────────────────────────────────────────┐
│ Ticket: Implement user authentication system            │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Work Mode                                              │
│  ┌─────────────────────────────────────────────────┐   │
│  │  (*) Solo Agent — one persona works the ticket  │   │
│  │  ( ) Agent Team — multiple personas collaborate │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  [When "Agent Team" selected:]                          │
│                                                         │
│  Team Composition                                       │
│  ☑ Devon (Developer) — backend auth implementation     │
│  ☑ Devon (Developer) — frontend auth UI                │
│  ☑ Riley (Reviewer) — security review                  │
│  ☐ Morgan (Researcher) — OAuth spec research           │
│                                                         │
│  Lead: Devon (Developer) — coordinates all work        │
│                                                         │
│  [ Start Team ]                                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### When NOT to Use Teams

Teams add coordination overhead and consume significantly more tokens. Prefer solo agents when:

- The ticket is focused on a single file or module
- Sequential tasks with heavy dependencies between steps
- Simple bug fixes or chores
- Research-only tickets
- The project has limited token budget

---

## 3. Team Architecture

### 3.1 Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Team                                │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Team Lead                              │   │
│  │  Persona: Project Manager (or designated lead)            │   │
│  │  Role: Break down work, assign tasks, synthesize results  │   │
│  │  Tools: Coordination-only (no code changes in delegate    │   │
│  │          mode) or full (if lead also implements)           │   │
│  └─────────────┬──────────────┬──────────────┬──────────────┘   │
│                │              │              │                   │
│        ┌───────▼──────┐ ┌────▼─────────┐ ┌──▼───────────┐     │
│        │ Teammate A   │ │ Teammate B   │ │ Teammate C   │     │
│        │              │ │              │ │              │     │
│        │ Devon        │ │ Devon        │ │ Riley        │     │
│        │ (Developer)  │ │ (Developer)  │ │ (Reviewer)   │     │
│        │ Backend auth │ │ Frontend UI  │ │ Security     │     │
│        └──────────────┘ └──────────────┘ └──────────────┘     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Shared Team Task List                        │   │
│  │  [ ] Set up OAuth provider configs         → Teammate A  │   │
│  │  [ ] Implement token exchange endpoint     → Teammate A  │   │
│  │  [ ] Build login/signup UI components      → Teammate B  │   │
│  │  [ ] Add session management middleware     → Teammate A  │   │
│  │  [ ] Review auth flow for vulnerabilities  → Teammate C  │   │
│  │  [x] Research OAuth best practices         → completed   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Team Mailbox                                 │   │
│  │  A → B: "Auth endpoint is at /api/auth/callback"        │   │
│  │  C → A: "Token storage needs PKCE — see RFC 7636"       │   │
│  │  A → Lead: "Backend auth complete, 4/4 tasks done"      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Team Lifecycle

```
Human creates/moves ticket
  → Heartbeat detects team-eligible ticket (or human requests team)
  → Lead persona session created
  → Lead analyzes ticket, creates team task list
  → Lead spawns teammate sessions (one per role/domain)
  → Each heartbeat cycle:
      → Teammates check mailbox for new messages
      → Teammates claim and work on tasks
      → Teammates post results and findings to mailbox
      → Lead monitors progress, reassigns stuck tasks
      → Lead synthesizes partial results
  → All tasks complete:
      → Lead writes summary comment on ticket
      → Lead merges/synthesizes teammate work
      → Team disbanded, sessions archived
      → Ticket moves to verification
```

### 3.3 Heartbeat Integration

Teams operate within the existing heartbeat model but require changes to how the scheduler allocates work:

```typescript
async function heartbeatWithTeams(): Promise<void> {
  // 1. Standard: find actionable solo tickets
  const soloWork = await findActionableTickets();

  // 2. New: find active teams needing heartbeat attention
  const activeTeams = await findActiveTeams();

  // 3. New: find tickets eligible for team creation
  const teamCandidates = await findTeamCandidates();

  // 4. Allocate resources across solo work and team work
  const allocation = allocateResources({
    soloWork,
    activeTeams,
    teamCandidates,
    maxConcurrentAgents: config.heartbeat.maxConcurrentAgents,
  });

  // 5. Run solo agents
  await Promise.all(allocation.solo.map(runAgentForTicket));

  // 6. Run team heartbeats (each team gets one or more agent slots)
  await Promise.all(allocation.teams.map(runTeamHeartbeat));

  // 7. Create new teams for candidates
  for (const candidate of allocation.newTeams) {
    await createTeam(candidate);
  }
}
```

**Resource allocation rules:**
- Each active teammate consumes one agent slot
- Teams have a configurable max concurrent teammates (default: 3)
- The lead consumes a slot only when actively coordinating (not idle)
- Solo work and team work share the same resource pool
- Priority: human-responded tickets > team work > solo work > new team creation

---

## 4. Data Model

### 4.1 Teams Table

```typescript
interface Team {
  id: string;              // "team_abc123"
  ticketId: string;        // The ticket this team is working on
  projectId: string;       // Parent project
  status: TeamStatus;      // "forming" | "active" | "completing" | "disbanded"
  leadPersonaId: string;   // Which persona is the lead
  leadSessionKey: string;  // Session key for the lead
  mode: "full" | "delegate"; // Whether lead can also implement
  createdAt: string;
  disbandedAt?: string;
  config: {
    maxTeammates: number;       // Cap on simultaneous teammates
    taskClaimTimeoutMs: number; // How long a claimed task stays locked
    autoDisband: boolean;       // Disband when all tasks complete
  };
}

type TeamStatus = "forming" | "active" | "completing" | "disbanded";
```

### 4.2 Team Members Table

```typescript
interface TeamMember {
  id: string;              // "tm_abc123"
  teamId: string;          // Parent team
  personaId: string;       // Which persona template
  role: string;            // "backend", "frontend", "security-review", etc.
  sessionKey: string;      // Dedicated session for this teammate
  status: MemberStatus;    // "active" | "idle" | "completed" | "shutdown"
  spawnPrompt: string;     // Context given when the teammate was created
  joinedAt: string;
  leftAt?: string;
  tasksCompleted: number;
  tokensUsed: { input: number; output: number };
}

type MemberStatus = "active" | "idle" | "completed" | "shutdown";
```

### 4.3 Team Tasks Table

```typescript
interface TeamTask {
  id: string;              // "tt_abc123"
  teamId: string;          // Parent team
  subject: string;         // Brief title
  description: string;     // Detailed requirements
  status: TaskStatus;      // "pending" | "claimed" | "in_progress" | "completed" | "blocked"
  assignedTo?: string;     // TeamMember ID (null = unassigned)
  claimedAt?: string;      // When it was claimed
  completedAt?: string;
  priority: number;        // Higher = more urgent
  blockedBy: string[];     // Other TeamTask IDs that must complete first
  result?: string;         // Summary of what the teammate produced
  createdAt: string;
}

type TaskStatus = "pending" | "claimed" | "in_progress" | "completed" | "blocked";
```

### 4.4 Team Messages Table

```typescript
interface TeamMessage {
  id: string;              // "msg_abc123"
  teamId: string;          // Parent team
  fromMemberId: string;    // Sender (TeamMember ID or "lead")
  toMemberId: string;      // Recipient (TeamMember ID, "lead", or "broadcast")
  content: string;         // Message text (markdown)
  type: MessageType;       // "info" | "question" | "finding" | "plan_approval" | "shutdown"
  read: boolean;           // Has recipient processed this message
  createdAt: string;
  readAt?: string;
}

type MessageType = "info" | "question" | "finding" | "plan_approval" | "shutdown";
```

### 4.5 Schema Migration

```sql
-- New tables for agent teams
CREATE TABLE teams (
  id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL REFERENCES tickets(id),
  project_id TEXT NOT NULL REFERENCES projects(id),
  status TEXT NOT NULL DEFAULT 'forming',
  lead_persona_id TEXT NOT NULL,
  lead_session_key TEXT NOT NULL,
  mode TEXT NOT NULL DEFAULT 'full',
  max_teammates INTEGER NOT NULL DEFAULT 3,
  task_claim_timeout_ms INTEGER NOT NULL DEFAULT 1800000,
  auto_disband INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  disbanded_at TEXT
);

CREATE TABLE team_members (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id),
  persona_id TEXT NOT NULL,
  role TEXT NOT NULL,
  session_key TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  spawn_prompt TEXT NOT NULL,
  joined_at TEXT NOT NULL,
  left_at TEXT,
  tasks_completed INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE team_tasks (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id),
  subject TEXT NOT NULL,
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  assigned_to TEXT REFERENCES team_members(id),
  claimed_at TEXT,
  completed_at TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  blocked_by TEXT NOT NULL DEFAULT '[]',  -- JSON array of task IDs
  result TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE team_messages (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id),
  from_member_id TEXT NOT NULL,
  to_member_id TEXT NOT NULL,
  content TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'info',
  read INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  read_at TEXT
);

-- Index for efficient team queries
CREATE INDEX idx_teams_ticket ON teams(ticket_id);
CREATE INDEX idx_teams_status ON teams(status);
CREATE INDEX idx_team_members_team ON team_members(team_id);
CREATE INDEX idx_team_tasks_team_status ON team_tasks(team_id, status);
CREATE INDEX idx_team_tasks_assigned ON team_tasks(assigned_to);
CREATE INDEX idx_team_messages_to_read ON team_messages(to_member_id, read);
```

---

## 5. Team Operations

### 5.1 Creating a Team

When the heartbeat decides to create a team (or the human requests one):

```typescript
async function createTeam(
  ticket: Ticket,
  project: Project,
  composition: TeamComposition
): Promise<Team> {
  // 1. Create team record
  const team = await db.teams.insert({
    id: generateId("team"),
    ticketId: ticket.id,
    projectId: project.id,
    status: "forming",
    leadPersonaId: composition.lead.personaId,
    leadSessionKey: buildTeamSessionKey(project.id, ticket.id, "lead"),
    mode: composition.delegateMode ? "delegate" : "full",
    maxTeammates: composition.maxTeammates ?? 3,
    createdAt: new Date().toISOString(),
  });

  // 2. Run lead persona to analyze ticket and create task breakdown
  const leadResult = await runTeamLead(team, ticket, "initialize");
  // Lead creates team_tasks entries based on its analysis

  // 3. Spawn initial teammates
  for (const role of composition.roles) {
    await spawnTeammate(team, role);
  }

  // 4. Activate team
  await db.teams.update(team.id, { status: "active" });

  return team;
}
```

### 5.2 Task Claiming (Atomic)

Teammates claim tasks using atomic database operations to prevent race conditions:

```typescript
async function claimNextTask(
  teamId: string,
  memberId: string
): Promise<TeamTask | null> {
  // Atomic claim: UPDATE ... WHERE status = 'pending' AND assigned_to IS NULL
  // Only one teammate can win the race
  const claimed = db.prepare(`
    UPDATE team_tasks
    SET status = 'claimed',
        assigned_to = ?,
        claimed_at = ?
    WHERE id = (
      SELECT id FROM team_tasks
      WHERE team_id = ?
        AND status = 'pending'
        AND assigned_to IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM team_tasks AS blocker
          WHERE blocker.id IN (
            SELECT value FROM json_each(team_tasks.blocked_by)
          )
          AND blocker.status != 'completed'
        )
      ORDER BY priority DESC
      LIMIT 1
    )
    RETURNING *
  `).get(memberId, new Date().toISOString(), teamId);

  return claimed ?? null;
}
```

### 5.3 Inter-Agent Messaging

Messages are persisted to SQLite and read on the next heartbeat cycle:

```typescript
// Teammate sends a message
async function sendTeamMessage(
  teamId: string,
  fromMemberId: string,
  toMemberId: string, // "lead", specific member ID, or "broadcast"
  content: string,
  type: MessageType = "info"
): Promise<void> {
  if (toMemberId === "broadcast") {
    // Send to all team members except sender
    const members = await db.teamMembers.list({ teamId, status: "active" });
    for (const member of members) {
      if (member.id !== fromMemberId) {
        await db.teamMessages.insert({
          id: generateId("msg"),
          teamId,
          fromMemberId,
          toMemberId: member.id,
          content,
          type,
          read: false,
          createdAt: new Date().toISOString(),
        });
      }
    }
  } else {
    await db.teamMessages.insert({
      id: generateId("msg"),
      teamId,
      fromMemberId,
      toMemberId,
      content,
      type,
      read: false,
      createdAt: new Date().toISOString(),
    });
  }
}

// Teammate reads messages on heartbeat wake
async function readUnreadMessages(
  teamId: string,
  memberId: string
): Promise<TeamMessage[]> {
  const messages = db.prepare(`
    UPDATE team_messages
    SET read = 1, read_at = ?
    WHERE team_id = ? AND to_member_id = ? AND read = 0
    RETURNING *
  `).all(new Date().toISOString(), teamId, memberId);

  return messages;
}
```

### 5.4 Team Lead Coordination

The lead persona has special tools for team management:

```typescript
const teamLeadTools: ToolDefinition[] = [
  {
    name: "team_create_task",
    description: "Create a new task in the team's shared task list.",
    parameters: {
      type: "object",
      properties: {
        subject: { type: "string" },
        description: { type: "string" },
        priority: { type: "number" },
        blockedBy: { type: "array", items: { type: "string" } },
        assignTo: { type: "string", description: "Member ID to assign, or null for self-claim" },
      },
      required: ["subject", "description"],
    },
  },
  {
    name: "team_send_message",
    description: "Send a message to a specific teammate or broadcast to all.",
    parameters: {
      type: "object",
      properties: {
        to: { type: "string", description: "Member ID, or 'broadcast' for all" },
        content: { type: "string" },
        type: { type: "string", enum: ["info", "question", "finding", "plan_approval", "shutdown"] },
      },
      required: ["to", "content"],
    },
  },
  {
    name: "team_check_progress",
    description: "Get the current status of all team tasks and members.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "team_reassign_task",
    description: "Reassign a task from one teammate to another.",
    parameters: {
      type: "object",
      properties: {
        taskId: { type: "string" },
        toMemberId: { type: "string" },
        reason: { type: "string" },
      },
      required: ["taskId", "toMemberId"],
    },
  },
  {
    name: "team_shutdown_member",
    description: "Request a teammate to shut down after completing current work.",
    parameters: {
      type: "object",
      properties: {
        memberId: { type: "string" },
        reason: { type: "string" },
      },
      required: ["memberId"],
    },
  },
  {
    name: "team_disband",
    description: "Disband the team. All teammates must be shut down first.",
    parameters: {
      type: "object",
      properties: {
        summary: { type: "string", description: "Final summary of team accomplishments" },
      },
      required: ["summary"],
    },
  },
];
```

### 5.5 Teammate Tools

Every teammate gets messaging and task tools in addition to their persona's standard toolset:

```typescript
const teammateTools: ToolDefinition[] = [
  {
    name: "team_claim_task",
    description: "Claim the next available unblocked task from the team task list.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "team_complete_task",
    description: "Mark the current task as completed with a result summary.",
    parameters: {
      type: "object",
      properties: {
        result: { type: "string", description: "Summary of what was accomplished" },
      },
      required: ["result"],
    },
  },
  {
    name: "team_send_message",
    description: "Send a message to the lead or another teammate.",
    parameters: {
      type: "object",
      properties: {
        to: { type: "string", description: "Member ID or 'lead'" },
        content: { type: "string" },
      },
      required: ["to", "content"],
    },
  },
  {
    name: "team_read_messages",
    description: "Check for new messages from teammates or the lead.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "team_view_tasks",
    description: "View the current state of all team tasks.",
    parameters: { type: "object", properties: {} },
  },
];
```

---

## 6. Team Heartbeat Cycle

### 6.1 Per-Team Heartbeat Flow

Each active team gets a heartbeat cycle that runs its members:

```typescript
async function runTeamHeartbeat(team: Team): Promise<void> {
  const members = await db.teamMembers.list({
    teamId: team.id,
    status: { in: ["active", "idle"] },
  });

  // 1. Run lead first — it may create new tasks or reassign work
  if (shouldRunLead(team)) {
    await runTeamMember(team, "lead", team.leadPersonaId, team.leadSessionKey);
  }

  // 2. Run active teammates in parallel (bounded by resource limits)
  const runnableMembers = members.filter(m => shouldRunMember(m, team));
  const maxParallel = Math.min(runnableMembers.length, team.config.maxTeammates);

  await runBounded(runnableMembers.slice(0, maxParallel), async (member) => {
    await runTeamMember(team, member.id, member.personaId, member.sessionKey);
  });

  // 3. Check if team is complete
  const allTasksDone = await checkAllTasksComplete(team.id);
  if (allTasksDone && team.config.autoDisband) {
    await initiateTeamCompletion(team);
  }
}

function shouldRunLead(team: Team): boolean {
  // Run lead if: new messages from teammates, tasks stuck, periodic check-in
  const hasUnreadMessages = db.teamMessages.countUnread(team.id, "lead") > 0;
  const hasStuckTasks = db.teamTasks.countStuck(team.id) > 0;
  const timeSinceLastRun = Date.now() - getLastLeadRunTime(team.id);
  const periodicCheckIn = timeSinceLastRun > 5 * 60 * 1000; // 5 minutes

  return hasUnreadMessages || hasStuckTasks || periodicCheckIn;
}

function shouldRunMember(member: TeamMember, team: Team): boolean {
  // Run member if: has claimed task, has unread messages, has available tasks to claim
  const hasClaimedTask = db.teamTasks.hasClaimedTask(member.id);
  const hasUnreadMessages = db.teamMessages.countUnread(team.id, member.id) > 0;
  const hasAvailableTasks = db.teamTasks.countAvailable(team.id) > 0;

  return hasClaimedTask || hasUnreadMessages || hasAvailableTasks;
}
```

### 6.2 Teammate Agent Run

Each teammate run follows this pattern:

```typescript
async function runTeamMember(
  team: Team,
  memberId: string,
  personaId: string,
  sessionKey: string
): Promise<void> {
  const persona = await loadPersona(personaId);
  const ticket = await db.tickets.get(team.ticketId);
  const project = await db.projects.get(team.projectId);

  // 1. Read unread messages — inject into prompt context
  const messages = await readUnreadMessages(team.id, memberId);

  // 2. Get current task assignment
  const currentTask = await db.teamTasks.getCurrentTask(memberId);

  // 3. If no current task, try to claim one
  if (!currentTask) {
    const claimed = await claimNextTask(team.id, memberId);
    if (!claimed) {
      // No work available — mark idle
      await db.teamMembers.update(memberId, { status: "idle" });
      return;
    }
  }

  // 4. Build system prompt with team context
  const systemPrompt = buildTeamMemberPrompt({
    persona,
    project,
    ticket,
    team,
    memberId,
    currentTask: currentTask ?? await db.teamTasks.getCurrentTask(memberId),
    recentMessages: messages,
  });

  // 5. Run agent
  const result = await agentRunner.run({
    projectId: project.id,
    ticketId: ticket.id,
    task: systemPrompt,
    workspace: await workspaceProvider.resolve(project.id),
    systemPrompt,
    sessionDir: resolveTeamSessionDir(team.id, memberId),
    maxDurationMs: config.heartbeat.teamMemberTimeoutMs ?? 900_000, // 15 min default
  });

  // 6. Update member stats
  await db.teamMembers.update(memberId, {
    tokensUsed: {
      input: (member.tokensUsed?.input ?? 0) + result.tokensUsed.input,
      output: (member.tokensUsed?.output ?? 0) + result.tokensUsed.output,
    },
  });
}
```

### 6.3 Team System Prompt Additions

When a persona is running as a teammate, extra context is injected:

```markdown
## Team Context

You are part of an agent team working on ticket: {ticket.title}

### Your Role
{member.role}: {member.spawnPrompt}

### Team Members
- Lead: {lead.persona.name} — coordinating work
- You ({member.persona.name}) — {member.role}
- {otherMembers.map(m => `${m.persona.name} — ${m.role}`)}

### Your Current Task
**{currentTask.subject}**
{currentTask.description}

### Recent Messages
{messages.map(m => `[${m.fromName}]: ${m.content}`)}

### Team Rules
- Complete your current task before claiming a new one
- Send findings relevant to other teammates via team_send_message
- Ask the lead if you're blocked or uncertain about scope
- Do NOT modify files that another teammate is actively working on
- Use team_complete_task when your task is done, with a clear summary
```

---

## 7. File Conflict Prevention

Multiple teammates editing the same file causes overwrites. Bonsai prevents this with file-level advisory locks:

### 7.1 File Lock Table

```sql
CREATE TABLE team_file_locks (
  team_id TEXT NOT NULL REFERENCES teams(id),
  file_path TEXT NOT NULL,       -- Relative to workspace root
  locked_by TEXT NOT NULL,       -- TeamMember ID
  locked_at TEXT NOT NULL,
  PRIMARY KEY (team_id, file_path)
);
```

### 7.2 Lock Enforcement

```typescript
// Wrapped ToolExecutor that checks file locks before writes
class TeamToolExecutor implements ToolExecutor {
  constructor(
    private inner: ToolExecutor,
    private teamId: string,
    private memberId: string
  ) {}

  async writeFile(path: string, content: string): Promise<void> {
    const lock = await db.teamFileLocks.get(this.teamId, path);

    if (lock && lock.lockedBy !== this.memberId) {
      throw new Error(
        `File ${path} is locked by teammate ${lock.lockedBy}. ` +
        `Send them a message to coordinate changes.`
      );
    }

    // Auto-lock on first write
    if (!lock) {
      await db.teamFileLocks.insert({
        teamId: this.teamId,
        filePath: path,
        lockedBy: this.memberId,
        lockedAt: new Date().toISOString(),
      });
    }

    return this.inner.writeFile(path, content);
  }

  // readFile, exec, etc. delegate directly to inner
}
```

### 7.3 Lead Can Resolve Conflicts

The lead has a tool to release file locks if a teammate is stuck:

```typescript
{
  name: "team_release_file_lock",
  description: "Release a file lock held by a teammate. Use when reassigning work or resolving conflicts.",
  parameters: {
    type: "object",
    properties: {
      filePath: { type: "string" },
    },
    required: ["filePath"],
  },
}
```

---

## 8. Plan Approval Gate

For complex or risky work, the lead can require teammates to plan before implementing. This mirrors Claude Code's plan approval flow:

```typescript
interface TeamTaskWithPlanApproval extends TeamTask {
  requiresPlanApproval: boolean;
  plan?: string;           // Teammate's proposed approach
  planStatus?: "pending" | "approved" | "rejected";
  planFeedback?: string;   // Lead's feedback if rejected
}
```

**Flow:**
1. Lead creates task with `requiresPlanApproval: true`
2. Teammate claims task, enters read-only exploration mode
3. Teammate writes plan and sends `plan_approval` message to lead
4. Lead reviews plan:
   - **Approved** → teammate proceeds with implementation
   - **Rejected** → teammate revises plan based on feedback
5. Lead can set approval criteria: "only approve plans that include test coverage"

---

## 9. Git Workflow for Teams

### 9.1 Branch Strategy

Teams work on a shared feature branch with per-teammate sub-branches to prevent conflicts:

```
main
  └── feat/ticket-42-auth               ← team feature branch
        ├── feat/ticket-42-auth/backend  ← Teammate A's working branch
        ├── feat/ticket-42-auth/frontend ← Teammate B's working branch
        └── feat/ticket-42-auth/security ← Teammate C's review branch
```

### 9.2 Merge Coordination

The lead coordinates merges:
1. Teammate completes task → commits to their sub-branch
2. Teammate sends "task complete" message to lead
3. Lead merges sub-branch into team feature branch
4. If conflicts: lead notifies affected teammates to resolve
5. When all work done: lead creates PR from feature branch to main

---

## 10. UI Integration

### 10.1 Team Panel in Ticket View

When a ticket has an active team, the ticket view shows a team panel:

```
┌─────────────────────────────────────────────────────────────────┐
│ Ticket: Implement user authentication system                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌─── Team Status ──────────────────────────────────────────┐   │
│  │                                                           │   │
│  │  Lead: Devon (PM)  [Active — coordinating]               │   │
│  │                                                           │   │
│  │  Teammates:                                               │   │
│  │  ┌─────────────┬──────────────────────┬──────────┐       │   │
│  │  │ Devon (Dev) │ Backend auth         │ Working  │       │   │
│  │  │             │ Task: Token exchange │ 12m      │       │   │
│  │  ├─────────────┼──────────────────────┼──────────┤       │   │
│  │  │ Devon (Dev) │ Frontend UI          │ Working  │       │   │
│  │  │             │ Task: Login form     │ 8m       │       │   │
│  │  ├─────────────┼──────────────────────┼──────────┤       │   │
│  │  │ Riley (Rev) │ Security review      │ Idle     │       │   │
│  │  │             │ Waiting for backend  │          │       │   │
│  │  └─────────────┴──────────────────────┴──────────┘       │   │
│  │                                                           │   │
│  │  Tasks: 3/8 complete  │  Messages: 7 exchanged           │   │
│  │                                                           │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌─── Team Task List ───────────────────────────────────────┐   │
│  │ ✅ Research OAuth best practices        (Morgan)          │   │
│  │ ✅ Set up provider configs              (Devon-Backend)   │   │
│  │ ✅ Design login UI components           (Devon-Frontend)  │   │
│  │ 🔄 Implement token exchange endpoint    (Devon-Backend)   │   │
│  │ 🔄 Build login/signup forms             (Devon-Frontend)  │   │
│  │ ⏳ Add session management middleware    (unassigned)      │   │
│  │ ⏳ Review auth flow for vulns           (Riley) blocked   │   │
│  │ ⏳ Integration tests                    (unassigned)      │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌─── Team Messages (recent) ───────────────────────────────┐   │
│  │ Devon-Backend → Devon-Frontend:                           │   │
│  │   "Auth endpoint is at /api/auth/callback. Use the        │   │
│  │    AuthResponse type from src/types/auth.ts"              │   │
│  │                                                           │   │
│  │ Riley → Devon-Backend:                                    │   │
│  │   "Token storage needs PKCE flow — see RFC 7636.          │   │
│  │    Don't store tokens in localStorage."                   │   │
│  │                                                           │   │
│  │ [View all messages]                                       │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 Team Activity in Board View

Board cards show team indicators:

```
┌───────────┐
│ ✨ Auth    │
│ system    │
│ 👥 3/8    │  ← team icon + task progress
│ 🔄 Active │
└───────────┘
```

### 10.3 Human Messaging into Teams

Humans can send messages to the team or specific teammates through the ticket UI:

```
┌─────────────────────────────────────────────────────┐
│ Send message to team                                 │
│ ┌─────────────────────────────────────────────────┐ │
│ │ To: [All ▼]  [Lead]  [Devon-Backend]  [Riley]  │ │
│ │                                                 │ │
│ │ Use bcrypt for password hashing, not SHA-256.   │ │
│ │ Also, we need to support "Remember me" with     │ │
│ │ refresh tokens.                                 │ │
│ │                                                 │ │
│ │                               [ Send Message ]  │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

Human messages are injected as high-priority team messages (teammates process them before regular inter-agent messages).

---

## 11. Permissions and Security

### 11.1 Persona Permissions in Teams

Each teammate retains its persona's role-based permissions (see doc 10). The team does not elevate permissions:

| Persona | Team Role | Permissions |
|---------|-----------|-------------|
| Developer (Devon) | Backend implementation | `Files:Full`, `Exec:Sandbox`, `GitHub:Write` |
| Developer (Devon) | Frontend implementation | `Files:Full`, `Exec:Sandbox`, `GitHub:Write` |
| Reviewer (Riley) | Security review | `Files:Read`, no exec, no write |
| Researcher (Morgan) | OAuth research | `Web:Full`, `Files:Read`, no exec |

### 11.2 File Scope Restrictions (Future)

In a future version, teammates can be scoped to specific directories:

```typescript
interface TeamMemberScope {
  allowedPaths: string[];   // ["src/backend/auth/**", "src/types/**"]
  deniedPaths: string[];    // ["src/frontend/**", ".env*"]
}
```

This prevents the backend teammate from accidentally modifying frontend code.

### 11.3 Token Budget per Team

Teams consume significantly more tokens than solo work. Bonsai tracks and optionally caps token usage:

```typescript
interface TeamTokenBudget {
  maxInputTokens: number;     // e.g., 2_000_000
  maxOutputTokens: number;    // e.g., 500_000
  currentInputTokens: number;
  currentOutputTokens: number;
  warningThreshold: number;   // 0.8 = warn at 80%
}
```

When the budget is exceeded:
1. Warning posted as comment on ticket
2. Teammates complete current tasks but don't claim new ones
3. Lead synthesizes partial results
4. Human decides whether to extend budget or finish with solo agent

---

## 12. Session Management

### 12.1 Team Session Directory Layout

```
~/.bonsai/
├── sessions/
│   └── {projectId}/
│       └── {ticketId}/
│           ├── transcript.json           # Solo session (if no team)
│           └── team/                     # Team sessions
│               ├── config.json           # Team configuration
│               ├── lead/
│               │   ├── transcript.json   # Lead's conversation history
│               │   └── metadata.json
│               ├── {memberId}/
│               │   ├── transcript.json   # Teammate's conversation history
│               │   └── metadata.json
│               └── .../
```

### 12.2 Session Key Format for Teams

```
bonsai:{projectId}:ticket:{ticketId}:team:{teamId}:lead
bonsai:{projectId}:ticket:{ticketId}:team:{teamId}:member:{memberId}
```

### 12.3 Session Resumption

Since teammates run across heartbeat cycles, their sessions must resume correctly:

1. On heartbeat wake, load the teammate's `transcript.json`
2. Inject any new team messages since last run
3. Inject updated task list state
4. Resume the LLM conversation with full history + new context
5. On heartbeat exit, save updated transcript

This follows the same pattern as solo ticket sessions (doc 03, section 2) but with additional team context injection.

---

## 13. Configuration

### 13.1 Global Team Settings

In `~/.bonsai/config.json`:

```json
{
  "teams": {
    "enabled": true,
    "maxConcurrentTeams": 2,
    "maxTeammatesPerTeam": 4,
    "defaultMode": "full",
    "autoDetect": true,
    "tokenBudget": {
      "defaultMaxInputTokens": 2000000,
      "defaultMaxOutputTokens": 500000,
      "warningThreshold": 0.8
    },
    "teamMemberTimeoutMs": 900000,
    "taskClaimTimeoutMs": 1800000
  }
}
```

### 13.2 Per-Project Team Settings

Projects can override global team settings:

```json
{
  "id": "proj_abc123",
  "teamSettings": {
    "enabled": true,
    "preferredComposition": {
      "lead": "project-manager",
      "roles": ["developer", "reviewer"]
    },
    "maxTeammatesPerTeam": 3
  }
}
```

---

## 14. Observability

### 14.1 Team Status API

```typescript
// GET /api/teams/{teamId}/status
{
  "team": {
    "id": "team_abc123",
    "ticketId": "tkt_456",
    "status": "active",
    "createdAt": "2026-02-06T10:00:00Z",
    "runningFor": "45m"
  },
  "lead": {
    "persona": "Devon (PM)",
    "lastActive": "2026-02-06T10:42:00Z",
    "tokensUsed": { "input": 45000, "output": 12000 }
  },
  "members": [
    {
      "id": "tm_001",
      "persona": "Devon (Developer)",
      "role": "Backend auth",
      "status": "active",
      "currentTask": "Implement token exchange",
      "tasksCompleted": 2,
      "tokensUsed": { "input": 120000, "output": 35000 }
    }
  ],
  "tasks": {
    "total": 8,
    "completed": 3,
    "inProgress": 2,
    "pending": 2,
    "blocked": 1
  },
  "messages": {
    "total": 12,
    "unread": 2
  },
  "tokenBudget": {
    "used": { "input": 450000, "output": 120000 },
    "max": { "input": 2000000, "output": 500000 },
    "percentUsed": 0.23
  }
}
```

### 14.2 Team Events

All team events are logged for debugging and audit:

```typescript
type TeamEvent =
  | { type: "team_created"; teamId: string; ticketId: string }
  | { type: "member_spawned"; teamId: string; memberId: string; persona: string; role: string }
  | { type: "task_created"; teamId: string; taskId: string; subject: string }
  | { type: "task_claimed"; teamId: string; taskId: string; memberId: string }
  | { type: "task_completed"; teamId: string; taskId: string; memberId: string }
  | { type: "message_sent"; teamId: string; from: string; to: string; type: MessageType }
  | { type: "file_lock_acquired"; teamId: string; memberId: string; path: string }
  | { type: "member_shutdown"; teamId: string; memberId: string; reason: string }
  | { type: "team_disbanded"; teamId: string; summary: string };
```

---

## 15. Example: Full Team Workflow

### Ticket: "Implement user authentication with OAuth"

**Step 1: Human creates ticket, selects "Agent Team" mode**

Team composition:
- Lead: Devon (PM) — coordinate work
- Teammate A: Devon (Developer) — backend auth
- Teammate B: Devon (Developer) — frontend UI
- Teammate C: Riley (Reviewer) — security review

**Step 2: Heartbeat creates team (beat #1)**

Lead analyzes ticket and creates 8 tasks:
1. Research OAuth best practices (unassigned)
2. Set up OAuth provider configs (→ Teammate A)
3. Design login UI components (→ Teammate B)
4. Implement token exchange endpoint (→ Teammate A, blocked by #2)
5. Build login/signup forms (→ Teammate B, blocked by #3)
6. Add session management middleware (unassigned, blocked by #4)
7. Review auth flow for vulnerabilities (→ Teammate C, blocked by #4, #5)
8. Integration tests (unassigned, blocked by #6, #7)

**Step 3: Teammates work in parallel (beats #2-10)**

- Beat #2: Teammate A starts task #2 (provider configs). Teammate B starts task #3 (UI design).
- Beat #3: Teammate A completes #2, claims #4 (token exchange). Teammate B still on #3.
- Beat #4: Teammate A working on #4, sends message to B: "Auth endpoint at /api/auth/callback".
- Beat #5: Teammate B completes #3, claims #5 (login forms). Uses A's endpoint info.
- Beat #6: Teammate C sends message to A: "Use PKCE for token exchange (RFC 7636)".
- Beat #7: Teammate A adjusts implementation based on C's feedback, completes #4.
- Beat #8: Task #6 unblocked, claimed by A. Task #7 partially unblocked (waiting on B).
- Beat #9: Teammate B completes #5. Task #7 fully unblocked, C starts security review.
- Beat #10: Teammate A completes #6. C completes #7 with findings.

**Step 4: Lead synthesizes (beat #11)**

Lead reviews all completed tasks, finds task #8 (integration tests) is now unblocked. Assigns to Teammate A.

**Step 5: Final tasks (beats #12-13)**

- Beat #12: Teammate A writes integration tests.
- Beat #13: All tests pass. Lead writes summary comment on ticket, merges branches, disbands team.

**Step 6: Ticket moves to verification**

Human reviews the PR, tests the auth flow, moves to Done.

---

## 16. Comparison: Solo vs Team

| Aspect | Solo Agent | Agent Team |
|--------|-----------|------------|
| **Tokens** | ~200K per ticket | ~800K-2M per ticket |
| **Wall time** | Sequential (many heartbeat cycles) | Parallel (fewer cycles, more per cycle) |
| **Coordination** | None needed | Lead orchestrates, messages exchanged |
| **File conflicts** | Impossible (single writer) | Prevented by file locks |
| **Expertise** | One persona's skills | Multiple specialized personas |
| **Best for** | Focused tasks, single-domain | Cross-domain, complex features |
| **Risk** | Simpler failure modes | Coordination failures, wasted tokens |

---

## 17. Known Limitations

1. **No real-time team visibility** — web UI polls for updates (same as solo tickets). No WebSocket streaming of teammate activity.
2. **Heartbeat latency** — teammates exchange messages across heartbeat cycles (60s minimum). Not suitable for tight real-time coordination.
3. **Token cost** — teams use 4-10x more tokens than solo agents. Budget monitoring is essential.
4. **File conflicts** — advisory locks prevent simultaneous writes but can't prevent all semantic conflicts (e.g., two teammates adding the same import).
5. **Lead bottleneck** — lead runs once per heartbeat cycle. If lead is slow to respond, teammates idle.
6. **No nested teams** — a teammate cannot spawn its own sub-team. Only the lead manages the team.
7. **One team per ticket** — a ticket can have at most one active team.
8. **Session size** — teammate sessions grow across heartbeat cycles. Context compaction applies but team message history adds overhead.

---

## 18. Future Enhancements

1. **WebSocket streaming** — real-time team activity in the web UI
2. **Persistent team mode** — optional long-running team process (bypass heartbeat) for intensive team work
3. **Cross-ticket teams** — teams that span multiple related tickets in the same project
4. **Dynamic team scaling** — lead can spawn additional teammates mid-work if needed
5. **Teammate specialization learning** — track which personas perform best in which roles, auto-suggest team compositions
6. **Conflict resolution tooling** — semantic merge tools for when file locks aren't enough
7. **Team templates** — save and reuse team compositions for common ticket patterns
8. **Inter-team coordination** — when two teams in the same project need to coordinate

---

## 19. Cross-References

| Topic | Document |
|-------|----------|
| Heartbeat model and agent runtime | [13-agent-runtime.md](./13-agent-runtime.md) |
| Work scheduler and priority logic | [06-work-scheduler.md](./06-work-scheduler.md) |
| Session management | [03-agent-session-management.md](./03-agent-session-management.md) |
| Persona system | [09-personas.md](./09-personas.md) |
| Roles and permissions | [10-roles-permissions.md](./10-roles-permissions.md) |
| Tool system | [14-tool-system.md](./14-tool-system.md) |
| Project board and ticket lifecycle | [04-project-board.md](./04-project-board.md) |
| Technical architecture | [02-technical-architecture.md](./02-technical-architecture.md) |
| Claude Code Agent Teams (reference) | [code.claude.com/docs/en/agent-teams](https://code.claude.com/docs/en/agent-teams) |
