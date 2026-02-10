# Bonsai Ticket Processing System

## What This Document Covers

Bonsai uses AI agents to do software development work. A human creates a ticket describing what needs to be built or fixed, and a team of AI agents researches, plans, and implements the solution. Humans stay in control at every critical decision point.

This document explains the full lifecycle of a ticket: how it moves through stages, what artifacts accumulate along the way, where humans must approve before work continues, and how the automation runs.

---

## The Big Picture

A ticket moves through four stages. At each stage, AI agents do the heavy lifting while humans make the key decisions.

```mermaid
flowchart LR
    B["Backlog"]
    IP["In Progress"]
    V["Verification"]
    D["Done"]

    B -->|"Human approves\nresearch"| IP
    IP -->|"Agent completes\nimplementation"| V
    V -->|"Human accepts\nthe work"| D
    V -->|"Human rejects\n(needs rework)"| IP
```

**Backlog** — The ticket exists but work hasn't started. An AI researcher is analyzing it.
**In Progress** — A human approved the research. Agents are planning and building.
**Verification** — The code is written. A human reviews whether it's correct.
**Done** — The work is accepted and complete.

---

## The Full Lifecycle

This diagram shows every step a ticket goes through, including who does what and what artifacts are created at each point.

```mermaid
flowchart TD
    subgraph CREATE ["1. Ticket Created"]
        TC["Human creates ticket\n(title, description, acceptance criteria)"]
        TC --> TState1["State: BACKLOG"]
    end

    subgraph RESEARCH ["2. Research Phase"]
        TState1 --> RA["AI Researcher analyzes the ticket"]
        RA --> RD["Artifact: Research Document\n(problem analysis, affected code,\nedge cases, constraints)"]
        RD --> HG1{"HUMAN GATE\nApprove research?"}
        HG1 -->|"Reject / Request changes"| RA
    end

    subgraph PLAN ["3. Planning Phase"]
        HG1 -->|"Approve"| TState2["State: IN PROGRESS"]
        TState2 --> PA["AI Planner creates\nimplementation plan"]
        PA --> PD["Artifact: Implementation Plan\n(step-by-step instructions,\nfiles to change, tests to write)"]
        PD --> HG2{"HUMAN GATE\nApprove plan?"}
        HG2 -->|"Reject / Request changes"| PA
    end

    subgraph IMPLEMENT ["4. Implementation Phase"]
        HG2 -->|"Approve"| DA["AI Developer writes code\n(in isolated git branch)"]
        DA --> CODE["Artifacts: Code changes,\nnew tests, commit history"]
        CODE --> TState3["State: VERIFICATION"]
    end

    subgraph VERIFY ["5. Verification"]
        TState3 --> HG3{"HUMAN GATE\nAccept the work?"}
        HG3 -->|"Accept"| TState4["State: DONE"]
        HG3 -->|"Return with feedback"| TState2
    end

    style HG1 fill:#f59e0b,stroke:#f59e0b,color:#000
    style HG2 fill:#f59e0b,stroke:#f59e0b,color:#000
    style HG3 fill:#f59e0b,stroke:#f59e0b,color:#000
    style TState1 fill:#6b7280,stroke:#6b7280,color:#fff
    style TState2 fill:#3b82f6,stroke:#3b82f6,color:#fff
    style TState3 fill:#8b5cf6,stroke:#8b5cf6,color:#fff
    style TState4 fill:#22c55e,stroke:#22c55e,color:#fff
```

---

## Ticket Status Over Time

A ticket's status tells you where it is in the process. Here's what each status means in practice:

| Status | What's Happening | Who's Active | Duration |
|--------|-----------------|--------------|----------|
| **Backlog** | AI researcher is studying the problem. Analyzing code, identifying edge cases, writing a research document. | AI Researcher | Minutes |
| **In Progress** | Two sub-phases: (1) AI planner writes a step-by-step implementation plan, then (2) AI developer writes the actual code. Each sub-phase requires human approval before advancing. | AI Planner, then AI Developer | Minutes to hours |
| **Verification** | Code is written and committed. Waiting for a human to review the changes and either accept or send back for rework. | Human reviewer | Depends on human |
| **Done** | Work accepted. Ticket is complete. | Nobody | Terminal state |

```mermaid
stateDiagram-v2
    [*] --> Backlog : Ticket created

    Backlog --> Backlog : AI researches\n(adds Research Document)

    Backlog --> InProgress : Human approves research

    InProgress --> InProgress : AI writes plan\n(adds Implementation Plan)
    InProgress --> InProgress : Human approves plan\n→ AI writes code

    InProgress --> Verification : AI completes implementation

    Verification --> Done : Human accepts work
    Verification --> InProgress : Human returns with feedback\n(rework cycle)

    Done --> [*]
```

---

## Artifacts That Accumulate on a Ticket

As a ticket moves through the system, it builds up a collection of documents, comments, and code changes. These artifacts provide a complete paper trail of every decision.

```mermaid
timeline
    title Artifact Accumulation Over a Ticket's Life

    section Backlog
        Ticket created : Title, description, acceptance criteria
        Research begins : AI comments with progress updates
        Research complete : Research Document v1 (markdown)

    section In Progress
        Research approved : Human approval timestamp + approver recorded
        Planning begins : AI comments with progress updates
        Plan complete : Implementation Plan v1 (markdown)
        Plan approved : Human approval timestamp + approver recorded
        Coding begins : Git branch created, AI comments with progress
        Code complete : Code commits, test files, agent summary

    section Verification
        Review begins : Human reads agent summary + code diff
        Feedback given : Human comment (accept or return with notes)

    section Done
        Accepted : Final state, full audit trail preserved
```

### Artifact Details

**Research Document**
Written by the AI researcher. Contains: problem summary, current state of the codebase, affected files and functions, edge cases, constraints, open questions, and a recommended approach. Stored in the database with version tracking — if the researcher revises it, the version number increments.

**Implementation Plan**
Written by the AI planner after research is approved. Contains: step-by-step instructions for what to change, which files to modify, what tests to write, and how to verify the changes work. Also version-tracked.

**Comments**
A running conversation thread on the ticket. Both humans and AI agents can post comments. Agent comments are visually distinguished from human comments. Comments include timestamps, author identity, and optional attachments.

**Code Changes**
The AI developer works in an isolated git branch (`ticket/{ticketId}`) inside a separate worktree directory. This prevents interference between agents working on different tickets simultaneously. Changes include new files, modified files, and test files.

---

## Human Gatekeeping Steps

Humans control three critical decision points. No automation can bypass these gates.

```mermaid
flowchart LR
    subgraph GATE1 ["Gate 1: Research Approval"]
        R1["AI produces\nResearch Document"] --> R2["Human reads\nthe analysis"]
        R2 --> R3{"Good enough?"}
        R3 -->|"Yes"| R4["Approve\n→ moves to In Progress"]
        R3 -->|"No"| R5["Comment with feedback\n→ AI revises research"]
    end

    style R3 fill:#f59e0b,stroke:#f59e0b,color:#000
```

```mermaid
flowchart LR
    subgraph GATE2 ["Gate 2: Plan Approval"]
        P1["AI produces\nImplementation Plan"] --> P2["Human reads\nthe plan"]
        P2 --> P3{"Correct approach?"}
        P3 -->|"Yes"| P4["Approve\n→ AI starts coding"]
        P3 -->|"No"| P5["Comment with feedback\n→ AI revises plan"]
    end

    style P3 fill:#f59e0b,stroke:#f59e0b,color:#000
```

```mermaid
flowchart LR
    subgraph GATE3 ["Gate 3: Work Verification"]
        V1["AI completes\ncode changes"] --> V2["Human reviews\nthe implementation"]
        V2 --> V3{"Meets acceptance\ncriteria?"}
        V3 -->|"Yes"| V4["Accept\n→ ticket is Done"]
        V3 -->|"No"| V5["Return with notes\n→ AI reworks"]
    end

    style V3 fill:#f59e0b,stroke:#f59e0b,color:#000
```

### Why Three Gates?

- **Gate 1 (Research)** ensures the AI understood the problem correctly before anyone starts planning a solution. Catching a misunderstanding here is cheap. Catching it after code is written is expensive.

- **Gate 2 (Plan)** ensures the implementation approach makes sense before code is written. A human can redirect the AI to a better strategy, avoid unnecessary complexity, or flag risks.

- **Gate 3 (Verification)** is the final quality check. The human confirms the code actually works, meets the acceptance criteria, and doesn't introduce problems. If it falls short, the ticket goes back to In Progress with specific feedback.

---

## How the Automation Is Triggered and Maintained

There are two mechanisms that trigger AI agents to work on tickets:

### Mechanism 1: Immediate Dispatch (Human-Triggered)

When a human takes certain actions, an AI agent is dispatched immediately:

```mermaid
sequenceDiagram
    participant H as Human
    participant W as Web App
    participant API as API Server
    participant AI as AI Agent

    H->>W: Creates new ticket
    W->>API: POST /api/tickets
    API->>API: Save ticket to database
    API->>API: POST /api/tickets/{id}/dispatch
    API-->>AI: Spawn researcher agent (background)
    AI->>AI: Analyze ticket, explore codebase
    AI->>API: POST progress updates (comments)
    AI->>API: POST /agent-complete (research document)

    Note over H,AI: Human can also trigger dispatch by posting a comment

    H->>W: Posts comment on ticket
    W->>API: POST /api/comments
    API->>API: Set lastHumanCommentAt flag
    API->>API: POST /api/tickets/{id}/dispatch
    API-->>AI: Spawn appropriate agent (background)
```

**Key detail:** When a human posts a comment on a ticket, two things happen: (1) an agent is dispatched immediately to respond, and (2) a `lastHumanCommentAt` flag is set on the ticket. This flag tells the automated scheduler that a human is waiting for a response, which gives this ticket higher priority.

### Mechanism 2: Heartbeat Scheduler (Automated)

A background process called the "heartbeat" runs every 5 minutes. It scans for tickets that need attention and dispatches agents to work on them.

```mermaid
flowchart TD
    HB["Heartbeat runs\n(every 5 minutes)"] --> SCAN["Scan all tickets\nfor pending work"]

    SCAN --> Q1{"Any tickets where\nhuman is waiting?\n(lastHumanCommentAt set)"}
    Q1 -->|"Yes"| D1["Dispatch agent\n(highest priority)"]
    Q1 -->|"No"| Q2

    Q2{"Any tickets returned\nfrom verification?\n(needs rework)"}
    Q2 -->|"Yes"| D2["Dispatch agent\n(high priority)"]
    Q2 -->|"No"| Q3

    Q3{"Any tickets\nin progress?"}
    Q3 -->|"Yes"| D3["Dispatch agent\n(normal priority)"]
    Q3 -->|"No"| Q4

    Q4{"Any backlog tickets\nneeding research?"}
    Q4 -->|"Yes"| D4["Dispatch researcher\n(background priority)"]
    Q4 -->|"No"| IDLE["Nothing to do\n(sleep until next run)"]

    D1 --> GUARD
    D2 --> GUARD
    D3 --> GUARD
    D4 --> GUARD

    GUARD{"Safety checks"}
    GUARD -->|"Max 2 concurrent agents"| RUN["Agent works on ticket"]
    GUARD -->|"Ticket already has\nactive agent"| SKIP["Skip this ticket"]
    GUARD -->|"Persona already\nbusy on another ticket"| SKIP

    style Q1 fill:#ef4444,stroke:#ef4444,color:#fff
    style Q2 fill:#f59e0b,stroke:#f59e0b,color:#000
    style Q3 fill:#3b82f6,stroke:#3b82f6,color:#fff
    style Q4 fill:#6b7280,stroke:#6b7280,color:#fff
```

### Priority System

The heartbeat uses a priority system to decide which tickets get worked on first:

| Priority | Condition | Reasoning |
|----------|-----------|-----------|
| **Highest** | Human posted a comment | A person is waiting. Respond fast. |
| **High** | Returned from verification | Work was rejected. Fix it before starting new work. |
| **Normal** | In progress, plan approved | Active work that should continue. |
| **Low** | Backlog, needs research | New tickets that no one is waiting on yet. |

### Safety Mechanisms

The system has several safeguards to prevent chaos:

- **Activity lock:** When an agent starts working on a ticket, a timestamp is recorded. No other agent can pick up that ticket for 30 minutes. This prevents two agents from making conflicting changes to the same code.

- **Concurrency limit:** Maximum 2 agents can run at the same time. This prevents overloading the system.

- **Persona exclusivity:** Each AI persona (researcher, developer, etc.) can only work on one ticket at a time. If "Kira the developer" is already implementing ticket A, she won't be assigned ticket B until she finishes.

- **Isolated workspaces:** Each ticket's code changes happen in a separate git branch and worktree directory. Agent A's changes can't accidentally break Agent B's work.

---

## Which AI Role Does What

Different AI personas handle different phases of work. Each role has specific tools it's allowed to use:

```mermaid
flowchart TD
    subgraph ROLES ["AI Team Roles"]

        subgraph RES ["Researcher"]
            R_DESC["Analyzes the problem\nExplores the codebase\nIdentifies edge cases"]
            R_TOOLS["Tools: Read files, search code\n(READ-ONLY, cannot change code)"]
            R_OUT["Output: Research Document"]
        end

        subgraph PLAN ["Planner"]
            P_DESC["Creates step-by-step plan\nBased on approved research"]
            P_TOOLS["Tools: Read files, search code\n(READ-ONLY, cannot change code)"]
            P_OUT["Output: Implementation Plan"]
        end

        subgraph DEV ["Developer"]
            D_DESC["Writes the actual code\nFollows the approved plan"]
            D_TOOLS["Tools: Read, write, edit files,\nrun commands\n(FULL ACCESS within worktree)"]
            D_OUT["Output: Code commits + summary"]
        end

    end

    R_OUT --> PLAN
    P_OUT --> DEV

    style RES fill:#8b5cf6,stroke:#8b5cf6,color:#fff
    style PLAN fill:#3b82f6,stroke:#3b82f6,color:#fff
    style DEV fill:#22c55e,stroke:#22c55e,color:#fff
```

**Why read-only for researchers and planners?** These roles only need to understand the code, not change it. Restricting their tools prevents accidental modifications during the analysis and planning stages. Only the developer role — working from an approved plan, in an isolated branch — has permission to write code.

---

## End-to-End Example

Here's a concrete example of how a ticket flows from creation to completion:

```mermaid
sequenceDiagram
    actor Human
    participant System as Bonsai
    participant Researcher as AI Researcher
    participant Planner as AI Planner
    participant Developer as AI Developer

    Human->>System: Create ticket "Add dark mode toggle"

    Note over System: State: BACKLOG

    System->>Researcher: Dispatch (automatic)
    Researcher->>System: Progress: "Exploring theme system..."
    Researcher->>System: Research Document complete
    Researcher->>System: "Found 3 affected components..."

    Human->>System: Reviews research document
    Human->>System: Approves research

    Note over System: State: IN PROGRESS

    System->>Planner: Dispatch (heartbeat, next cycle)
    Planner->>System: Implementation Plan complete
    Planner->>System: "4 steps: theme context, toggle component,..."

    Human->>System: Reviews plan
    Human->>System: Approves plan

    System->>Developer: Dispatch (heartbeat, next cycle)
    Developer->>System: Progress: "Creating ThemeContext..."
    Developer->>System: Progress: "Writing toggle component..."
    Developer->>System: Progress: "Adding tests..."
    Developer->>System: Implementation complete

    Note over System: State: VERIFICATION

    Human->>System: Reviews code changes
    Human->>System: Accepts work

    Note over System: State: DONE
```

---

## Summary

| Concept | How It Works |
|---------|-------------|
| **Ticket stages** | Backlog → In Progress → Verification → Done |
| **AI work phases** | Research → Planning → Implementation (one at a time, in order) |
| **Human gates** | Three approval points: after research, after planning, after coding |
| **Artifacts** | Research document, implementation plan, comments, code commits |
| **Immediate triggers** | Ticket creation and human comments dispatch agents instantly |
| **Background automation** | Heartbeat scheduler runs every 5 minutes, picks up pending work |
| **Safety** | Activity locks, concurrency limits, persona exclusivity, isolated git branches |
| **Priority** | Human-waiting > rework > active work > new research |
