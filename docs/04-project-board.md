# Bonsai Project Board — Design Document

Date: 2026-02-04

**UI Design Specification:** See `11-ui-design-spec.md` for complete visual design system (colors, typography, components).

**Reference Image:** `.claude/bonsai/assets/project-board-reference.png`

## Overview

Every Bonsai project gets a **project board** — a visual state machine for managing work from idea to completion. The board orchestrates human-agent collaboration through structured tickets that move through defined states, with agents autonomously advancing work and humans providing direction and approval at key checkpoints.

---

## 1. Core Concepts

### 1.1 The Board as a State Machine

The project board is not just a visual kanban — it's a **state machine** that governs:
- What work agents can perform on a ticket
- When human input is required
- How tickets transition between columns
- When agents wake up to attempt progress

Each column represents a distinct state with defined entry conditions, agent behaviors, and exit criteria.

### 1.2 Ticket Types

| Type | Purpose | Icon |
|------|---------|------|
| **Feature** | New functionality to build | ✨ |
| **Bug** | Something broken to fix | 🐛 |
| **Chore** | Maintenance, refactoring, infrastructure | 🔧 |

All ticket types follow the same state machine — the type affects how agents approach research and implementation, not the workflow.

### 1.3 Ticket Anatomy

```
┌─────────────────────────────────────────────────────────┐
│ [✨ Feature] User authentication via OAuth              │
├─────────────────────────────────────────────────────────┤
│ Description                                             │
│ ─────────────────────────────────────────────────────── │
│ Add Google and GitHub OAuth login options to the app.  │
│ Users should be able to link multiple providers to     │
│ one account.                                            │
│                                                         │
│ Attachments: [mockup.png] [requirements.pdf]           │
├─────────────────────────────────────────────────────────┤
│ Acceptance Criteria                                     │
│ ─────────────────────────────────────────────────────── │
│ □ User can sign in with Google                         │
│ □ User can sign in with GitHub                         │
│ □ User can link both providers to same account         │
│ □ Existing email/password users can link OAuth         │
│ □ All tests pass                                        │
├─────────────────────────────────────────────────────────┤
│ Agent Documents                                         │
│ ─────────────────────────────────────────────────────── │
│ 📄 research.md          [Ready ✓]                      │
│ 📄 implementation-plan.md [Ready ✓]                    │
│ 📋 todo.md              [In Progress]                  │
├─────────────────────────────────────────────────────────┤
│ Comments (3)                                            │
│ ─────────────────────────────────────────────────────── │
│ 💬 Agent: Should we support Apple Sign-In too?         │
│ 💬 Human: Not for v1, add it to a follow-up ticket     │
│ 💬 Agent: Got it, scoped to Google + GitHub only       │
└─────────────────────────────────────────────────────────┘
```

**Human-provided fields:**
- Title
- Description (rich text)
- Attachments (images, documents)
- Acceptance criteria (checklist)

**Agent-generated fields:**
- Research document
- Implementation plan
- Todo list (during implementation)
- Comments/questions

---

## 2. Board Columns (States)

```
┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐
│ Backlog  │ → │ Research │ → │  Ready    │ → │   In     │ → │   Done   │
│          │   │          │   │           │   │ Progress │   │          │
└──────────┘   └──────────┘   └───────────┘   └──────────┘   └──────────┘
     │              │              │               │              │
     │              │              │               │              │
   Human          Agent          Human           Agent          Human
   creates        researches     approves        implements     verifies
```

### 2.1 Backlog

**Entry:** Human creates ticket with description + acceptance criteria

**Agent behavior:**
- Agents do NOT automatically start work on backlog items
- Ticket sits until human explicitly moves it to Research

**Exit criteria:**
- Human moves ticket to Research column

**Why manual?** Backlog is for capturing ideas. Not everything in backlog should be worked on. Human decides priority by moving to Research.

### 2.2 Research

**Entry:** Human moves ticket from Backlog

**Agent behavior:**
1. Agent claims the ticket
2. Reads description, attachments, acceptance criteria
3. Gathers information from:
   - Project codebase(s)
   - External documentation
   - Videos (transcribed)
   - Blog posts, articles
   - API docs
4. Creates `research.md` with findings
5. Drafts `implementation-plan.md` with:
   - Technical approach
   - Files to modify/create
   - Dependencies
   - Risks and unknowns
   - Estimated complexity
6. Marks both documents as "Ready"
7. Ticket visually surfaces to top of column

**Exit criteria:**
- Both `research.md` and `implementation-plan.md` marked Ready
- Human reviews and clicks "Approve"

**Human interaction:**
- Human can read research and plan in built-in markdown viewer
- Human can add **anchored comments** (pointing to specific text or images)
- Agent responds to comments, updates documents
- Ping-pong continues until human clicks "Approve"

### 2.3 Ready

**Entry:** Human approves research and plan

**Purpose:** Staging area for approved work. Tickets here are ready to be picked up.

**Agent behavior:**
- No automatic agent work
- Ticket waits for human to move to In Progress

**Exit criteria:**
- Human moves ticket to In Progress

**Why manual?** Human controls when work actually starts. Ready queue lets them batch and prioritize.

### 2.4 In Progress

**Entry:** Human moves ticket from Ready

**Agent behavior:**
1. Agent claims the ticket
2. Consumes `research.md` and `implementation-plan.md`
3. Creates `todo.md` — a physical checklist derived from the plan
4. Works through todo items:
   - Writes code
   - Runs tests
   - Commits changes
   - Checks off completed items
5. If blocked or uncertain:
   - Adds comment with question
   - Ticket enters "Waiting for Human" sub-state
   - Human is notified
6. Human responds via comment
7. Agent continues work

**Agent wake cycle:**
- Every 5 minutes, scheduler checks In Progress tickets
- If no agent is currently attached, one spins up
- Agent evaluates: "Can I move this forward?"
  - If yes: does work, updates todo, comments if needed
  - If no (waiting for human): sleeps until next cycle

**Exit criteria:**
- All todo items checked
- All acceptance criteria met
- Agent marks ticket as "Implementation Complete"
- Human moves to Done (after verification)

### 2.5 Done

**Entry:** Human verifies implementation and moves ticket

**Agent behavior:**
- None — ticket is complete

**What happens:**
- Ticket archived for reference
- Linked commits/PRs visible in ticket history
- Research and plan documents preserved

---

## 3. Agent Wake Cycle

Agents don't run continuously. They wake on a schedule to check if work is needed.

### 3.1 Wake Logic

```
Every 5 minutes:
  for each ticket in [Research, In Progress]:
    if ticket.hasActiveAgent:
      skip  # Don't double-attach

    if ticket.state == "Research":
      if not ticket.researchComplete:
        spawnAgent(ticket, task="research")
      elif ticket.hasUnresolvedHumanComments:
        spawnAgent(ticket, task="respond_to_comments")

    elif ticket.state == "In Progress":
      if ticket.waitingForHuman:
        skip  # Can't proceed without human input
      elif ticket.hasPendingTodoItems:
        spawnAgent(ticket, task="work_on_todo")
      elif ticket.hasUnresolvedHumanComments:
        spawnAgent(ticket, task="respond_to_comments")
```

### 3.2 Agent Attachment

- Only one agent attached to a ticket at a time
- Agent "locks" ticket while working
- Lock released when agent completes current task or times out
- Timeout: 30 minutes (configurable)

### 3.3 Sub-States (Visual Indicators)

| Visual | Meaning |
|--------|---------|
| 🔄 Agent Working | Agent currently attached and active |
| ⏳ Waiting for Human | Agent asked a question, awaiting response |
| ✅ Ready for Review | Research/plan complete, needs human approval |
| 🚀 Ready to Start | In Ready column, approved and waiting |

---

## 4. Human-Agent Communication

### 4.1 Anchored Comments

Comments can be attached to specific locations:

**Text anchors:**
```markdown
> "We should use the existing AuthService class"
@agent: Which AuthService? There are two in the codebase.
```

**Image anchors:**
- Click on image to place pin
- Comment attached to that coordinate
- Useful for mockups, screenshots, diagrams

**Document section anchors:**
- Click on heading in research.md or plan.md
- Comment attached to that section

### 4.2 Comment Flow

```
┌─────────────────────────────────────────────────────────┐
│ research.md                                             │
├─────────────────────────────────────────────────────────┤
│ ## Authentication Providers                             │
│                                                         │
│ The app currently uses Passport.js for authentication.  │
│ Adding OAuth providers requires:                        │  ← 📌 Human comment here
│ 1. Installing passport-google-oauth20                   │
│ 2. Installing passport-github2                          │
│ 3. Configuring callback URLs                            │
│                                                         │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ 💬 Human: We also need to handle the case where     │ │
│ │    user's email from OAuth doesn't match existing   │ │
│ │    account email. How should we handle that?        │ │
│ │                                                     │ │
│ │ 💬 Agent: Good point. I see three options:          │ │
│ │    1. Reject login, ask user to use original method │ │
│ │    2. Create new account, let user merge later      │ │
│ │    3. Prompt user to confirm account linking        │ │
│ │    Which approach fits your UX goals?               │ │
│ │                                                     │ │
│ │ 💬 Human: Option 3 - prompt to confirm linking      │ │
│ │                                                     │ │
│ │ 💬 Agent: Updated the plan to include account       │ │
│ │    linking confirmation flow. See section 4.2.      │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### 4.3 Notification System

Humans are notified when:
- Research document marked Ready
- Implementation plan marked Ready
- Agent asks a question (comment)
- Agent completes implementation
- Agent encounters a blocker

Notification channels (configurable per user):
- In-app badge/toast
- Email digest
- Push notification (mobile)
- Discord/Slack mention (if channel bound)

---

## 5. Data Model

### 5.1 Ticket Schema

```typescript
interface Ticket {
  id: string;
  projectId: string;
  type: "feature" | "bug" | "chore";
  state: TicketState;
  subState?: TicketSubState;

  // Human-provided
  title: string;
  description: string;  // Markdown
  attachments: Attachment[];
  acceptanceCriteria: AcceptanceCriterion[];

  // Agent-generated
  researchDocId?: string;
  implementationPlanId?: string;
  todoDocId?: string;

  // Metadata
  createdAt: string;
  updatedAt: string;
  createdBy: string;  // Human user ID
  assignedAgentId?: string;
  agentLockedUntil?: string;  // Timestamp

  // History
  stateHistory: StateTransition[];
  linkedCommits: string[];  // Git SHAs
  linkedPRs: string[];  // PR URLs
}

type TicketState =
  | "backlog"
  | "research"
  | "ready"
  | "in_progress"
  | "done";

type TicketSubState =
  | "agent_working"
  | "waiting_for_human"
  | "ready_for_review"
  | "implementation_complete";

interface AcceptanceCriterion {
  id: string;
  text: string;
  completed: boolean;
  completedAt?: string;
  completedBy?: string;  // Agent or human
}

interface Attachment {
  id: string;
  filename: string;
  mimeType: string;
  url: string;
  uploadedAt: string;
}

interface StateTransition {
  from: TicketState;
  to: TicketState;
  timestamp: string;
  triggeredBy: string;  // User ID or "agent"
  reason?: string;
}
```

### 5.2 Document Schema

```typescript
interface TicketDocument {
  id: string;
  ticketId: string;
  type: "research" | "implementation_plan" | "todo";
  content: string;  // Markdown
  status: "draft" | "ready" | "approved";

  createdAt: string;
  updatedAt: string;
  createdBy: string;  // Usually agent ID
  approvedBy?: string;  // Human user ID
  approvedAt?: string;

  version: number;
  versions: DocumentVersion[];
}

interface DocumentVersion {
  version: number;
  content: string;
  timestamp: string;
  changedBy: string;
  changeSummary?: string;
}
```

### 5.3 Comment Schema

```typescript
interface Comment {
  id: string;
  ticketId: string;
  documentId?: string;  // If anchored to a document

  author: {
    type: "human" | "agent";
    id: string;
    name: string;
  };

  content: string;  // Markdown

  anchor?: {
    type: "text" | "image" | "section";
    documentId: string;
    // For text: character range
    startOffset?: number;
    endOffset?: number;
    // For image: coordinates
    x?: number;
    y?: number;
    // For section: heading ID
    sectionId?: string;
  };

  resolved: boolean;
  resolvedAt?: string;
  resolvedBy?: string;

  createdAt: string;
  parentCommentId?: string;  // For threading
}
```

### 5.4 Agent Run Schema

```typescript
interface AgentRun {
  id: string;
  ticketId: string;
  agentId: string;
  task: "research" | "respond_to_comments" | "work_on_todo";

  startedAt: string;
  completedAt?: string;
  status: "running" | "completed" | "failed" | "timed_out";

  // What the agent did
  actions: AgentAction[];

  // Token usage
  inputTokens: number;
  outputTokens: number;

  // Link to OpenClaw session
  sessionKey: string;
  transcriptPath: string;
}

interface AgentAction {
  type: "read_file" | "write_file" | "run_command" | "web_search" |
        "create_document" | "update_document" | "add_comment" |
        "check_todo_item" | "git_commit";
  timestamp: string;
  details: Record<string, unknown>;
}
```

---

## 6. Integration with OpenClaw

### 6.1 Agent ↔ Ticket Mapping

Each ticket in a Bonsai project uses the project's OpenClaw agent:

```
Bonsai Project: "frontend-app"
  └── OpenClaw Agent: "frontend-app-dev"
        └── Ticket #42: "Add OAuth"
              └── Session: "agent:frontend-app-dev:ticket:42"
```

### 6.2 Session Key Pattern

Ticket work uses dedicated sessions following OpenClaw's format:
```
agent:{agentId}:bonsai:{projectId}:ticket:{ticketId}
```

Example: `agent:default:bonsai:proj_abc123:ticket:tkt_456`

This keeps ticket work isolated from:
- Main chat sessions
- Other tickets
- Other projects

### 6.3 Agent Task Dispatch

When Bonsai needs to wake an agent for a ticket:

```typescript
// 1. Build session key
const sessionKey = `agent:${project.agentId}:ticket:${ticket.id}`;

// 2. Build context message
const message = buildAgentTaskMessage(ticket, task);

// 3. Send via Gateway RPC
const result = await ws.request("agent", {
  agentId: project.agentId,
  sessionKey,
  message,
  idempotencyKey: `${ticket.id}-${task}-${Date.now()}`,
  deliver: false,  // Don't send to channels
});

// 4. Stream response, update ticket state
for await (const event of result.events) {
  await processAgentEvent(ticket, event);
}
```

### 6.4 SOUL.md Injection

When agent works on a ticket, Bonsai injects ticket context into the system prompt via the workspace's `SOUL.md`:

```markdown
# Project: frontend-app

You are working on ticket #42: "Add OAuth authentication"

## Ticket Description
{ticket.description}

## Acceptance Criteria
{ticket.acceptanceCriteria}

## Current Task
{task.type}: {task.description}

## Research Document
{ticket.researchDoc.content}

## Implementation Plan
{ticket.implementationPlan.content}

## Current Todo
{ticket.todo.content}

## Rules
- Only modify files in this project's workspace
- Check off todo items as you complete them
- Ask questions via comments if uncertain
- Do not mark acceptance criteria complete until verified
```

This is written to the workspace before each agent wake, ensuring the agent has full ticket context.

---

## 7. Wake Scheduler Implementation

### 7.1 Cron-Based Scheduler

Bonsai runs a scheduler service that wakes every minute:

```typescript
// scheduler.ts
import { CronJob } from "cron";

const scheduler = new CronJob("* * * * *", async () => {
  const tickets = await getTicketsNeedingWork();

  for (const ticket of tickets) {
    if (await shouldWakeAgent(ticket)) {
      await dispatchAgentTask(ticket);
    }
  }
});

async function shouldWakeAgent(ticket: Ticket): Promise<boolean> {
  // Don't double-attach
  if (ticket.agentLockedUntil && new Date(ticket.agentLockedUntil) > new Date()) {
    return false;
  }

  // Check state-specific conditions
  switch (ticket.state) {
    case "research":
      return !ticket.researchDoc?.status === "ready" ||
             hasUnresolvedAgentQuestions(ticket);

    case "in_progress":
      return !ticket.subState?.includes("waiting_for_human") &&
             hasPendingTodoItems(ticket);

    default:
      return false;
  }
}
```

### 7.2 Agent Lock Management

```typescript
async function dispatchAgentTask(ticket: Ticket): Promise<void> {
  // Lock ticket for 30 minutes
  await db.tickets.update(ticket.id, {
    agentLockedUntil: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
    assignedAgentId: generateAgentRunId(),
  });

  try {
    const run = await executeAgentRun(ticket);
    await recordAgentRun(run);
  } finally {
    // Release lock
    await db.tickets.update(ticket.id, {
      agentLockedUntil: null,
      assignedAgentId: null,
    });
  }
}
```

---

## 8. UI Components

### 8.1 Board View

```
┌─────────────────────────────────────────────────────────────────────────┐
│ frontend-app                                              [+ New Ticket]│
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Backlog (3)      Research (1)     Ready (2)      In Progress (1)      │
│  ───────────      ────────────     ─────────      ───────────────      │
│  ┌───────────┐    ┌───────────┐   ┌───────────┐   ┌───────────┐        │
│  │ ✨ Add     │    │ 🐛 Fix     │   │ ✨ OAuth   │   │ 🔧 Refactor│        │
│  │ dark mode │    │ login bug │   │ support   │   │ API client│        │
│  │           │    │           │   │ ✅ Ready  │   │ 🔄 Working│        │
│  │           │    │ 🔄 Working│   └───────────┘   │           │        │
│  └───────────┘    └───────────┘   ┌───────────┐   │ ████░░░░ │        │
│  ┌───────────┐                    │ 🐛 Fix     │   │ 40%      │        │
│  │ 🔧 Update │                    │ logout    │   └───────────┘        │
│  │ deps      │                    │ ✅ Ready  │                        │
│  └───────────┘                    └───────────┘                        │
│  ┌───────────┐                                                         │
│  │ ✨ Export │                                                         │
│  │ to PDF   │                                                          │
│  └───────────┘                                                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Ticket Detail View

Split-pane layout:
- Left: Ticket info, acceptance criteria, comments
- Right: Document viewer (research, plan, todo)

### 8.3 Document Viewer

- Markdown rendering with syntax highlighting
- Inline comment anchoring
- Version history sidebar
- "Approve" button for research/plan

---

## 9. Example Workflow

### Step-by-Step: Feature from Idea to Done

**1. Human creates ticket**
```
Title: Add user profile avatars
Type: Feature
Description: Users should be able to upload and display profile pictures.
             Support jpg, png, gif up to 5MB. Default to initials if no upload.
Attachments: [avatar-mockup.png]
Acceptance Criteria:
  - [ ] User can upload avatar from settings
  - [ ] Avatar displays in header and comments
  - [ ] Supports jpg, png, gif up to 5MB
  - [ ] Falls back to initials avatar
  - [ ] Existing users without avatar get initials
```

**2. Human moves to Research**
- Ticket appears in Research column
- Within 5 minutes, agent wakes and claims ticket

**3. Agent researches**
- Reads codebase: finds existing image upload code, user model
- Searches docs: image processing libraries, S3 upload patterns
- Creates `research.md` with findings
- Creates `implementation-plan.md` with approach
- Marks both Ready

**4. Human reviews**
- Sees ✅ Ready indicator
- Opens ticket, reads research and plan
- Adds comment: "Can we use Cloudinary instead of S3?"
- Agent wakes, updates plan, responds

**5. Human approves**
- Clicks "Approve" on research and plan
- Moves ticket to Ready

**6. Human starts work**
- Moves ticket to In Progress
- Agent wakes, creates `todo.md`:
  ```markdown
  ## Todo
  - [ ] Add avatar field to User model
  - [ ] Create avatar upload endpoint
  - [ ] Integrate Cloudinary SDK
  - [ ] Add avatar component to header
  - [ ] Add avatar component to comments
  - [ ] Create initials fallback generator
  - [ ] Add upload UI to settings page
  - [ ] Write tests
  ```

**7. Agent works**
- Every 5 minutes, agent wakes if not locked
- Works through todo items
- Commits code incrementally
- Checks off completed items
- Asks question: "The gif support requires an extra library. Install it?"
- Human responds: "Yes, go ahead"
- Agent continues

**8. Agent completes**
- All todo items checked
- All acceptance criteria met
- Agent marks "Implementation Complete"
- Ticket shows sub-state indicator

**9. Human verifies**
- Reviews code, tests feature
- Moves to Done

---

## 10. Future Considerations

### 10.1 Multi-Agent Collaboration (Agent Teams)
- Specialist agents (research agent, code agent, test agent) working in parallel
- Handoffs between agents with context
- See [15-agent-teams.md](./15-agent-teams.md) for the full agent teams design

### 10.2 Ticket Dependencies
- "Blocked by" relationships
- Automatic unblocking when dependency completes

### 10.3 Time Estimates
- Agent estimates time during planning
- Track actual vs estimated

### 10.4 Sprint Planning
- Group tickets into sprints
- Velocity tracking

### 10.5 Integration with External Trackers
- Sync with GitHub Issues
- Sync with Linear, Jira
- Two-way comment sync
