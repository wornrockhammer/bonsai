# Bonsai Git Operations — Design Document

Date: 2026-02-04

## Overview

Bonsai codifies and automates git operations for agents. Each ticket gets its own **worktree** — an ephemeral virtual filesystem where the agent works in isolation. Worktrees are deleted after finalization. Humans don't work directly in these repositories — agents do all the coding, and humans approve the results.

**Key decisions:**
- Worktree per ticket (ephemeral isolated filesystem)
- Branch per ticket, always starts from `origin/main`
- Codified commit messages (enforced format)
- Rebase over merge (linear history)
- No GitHub PRs — approval happens in Bonsai's board
- Finalization on human approval (rebase onto main, push)
- **Git operation serialization** (shared `.git/` requires coordination)

> **Important: Shared `.git/` contention.** Git worktrees share the `.git` directory — object store, refs, packed-refs, and lock files. Concurrent git operations from different agents (fetch, gc, branch create/delete, rebase) contend on shared locks and can corrupt state. Bonsai serializes all git operations that touch the shared `.git/` through a per-project operation queue. See Section 3.3.

---

## 1. Repository Structure

Each project has a main worktree (on `main`) and ticket worktrees:

```
projects/my-app/
├── .git/                          # Main repository
├── .worktrees/                    # Ticket worktrees
│   ├── ticket-abc123/             # Branch: ticket/abc123
│   │   ├── .git                   # Worktree link file
│   │   ├── src/
│   │   └── ...
│   └── ticket-def456/             # Branch: ticket/def456
│       └── ...
├── .bonsai/
│   └── tickets/
└── (main worktree - stays on main, not used for development)
```

**Main worktree:** Stays on `main` branch. Used for finalization (rebasing completed work). Agents don't develop here.

**Ticket worktrees:** Ephemeral virtual filesystems — each ticket gets its own worktree with its own branch. Agents work here. Deleted after finalization. All worktrees share the main `.git/` directory (object store, refs, locks), so git operations that touch shared state must be serialized through the operation queue (see Section 3.3.1).

---

## 2. Ticket Lifecycle (Git Perspective)

### 2.1 Ticket Created → Worktree Setup

When a ticket moves to **Research** or **In Progress**, create a worktree:

```typescript
async function createTicketWorktree(
  projectPath: string,
  ticketId: string
): Promise<string> {
  const worktreePath = path.join(projectPath, ".worktrees", ticketId);
  const branchName = `ticket/${ticketId}`;

  // Fetch latest from origin
  await execFile("git", ["fetch", "origin"], { cwd: projectPath });

  // Create branch from origin/main
  await execFile("git", ["branch", branchName, "origin/main"], { cwd: projectPath });

  // Create worktree
  await execFile("git", ["worktree", "add", worktreePath, branchName], { cwd: projectPath });

  return worktreePath;
}
```

**Result:**
```
.worktrees/ticket-abc123/    # New worktree
  └── (full repo checkout on branch ticket/abc123)
```

### 2.2 Agent Works → Commits

Agent makes commits as it completes work. See Section 4 for commit format.

```typescript
async function commitAgentWork(
  worktreePath: string,
  message: CommitMessage
): Promise<string> {
  // Stage all changes
  await execFile("git", ["add", "-A"], { cwd: worktreePath });

  // Check if there are changes to commit
  const status = await execFile("git", ["status", "--porcelain"], { cwd: worktreePath });
  if (!status.stdout.trim()) {
    return null; // Nothing to commit
  }

  // Commit with codified message
  const formattedMessage = formatCommitMessage(message);
  await execFile("git", ["commit", "-m", formattedMessage], { cwd: worktreePath });

  // Get commit hash
  const result = await execFile("git", ["rev-parse", "HEAD"], { cwd: worktreePath });
  return result.stdout.trim();
}
```

### 2.3 Human Approves → Finalization

When human approves work (moves ticket to **Done**), finalize:

```typescript
async function finalizeTicket(
  projectPath: string,
  ticketId: string
): Promise<FinalizeResult> {
  const worktreePath = path.join(projectPath, ".worktrees", ticketId);
  const branchName = `ticket/${ticketId}`;

  // 1. Fetch latest origin/main
  await execFile("git", ["fetch", "origin"], { cwd: projectPath });

  // 2. Checkout main in main worktree
  await execFile("git", ["checkout", "main"], { cwd: projectPath });

  // 3. Reset main to origin/main (ensure we're current)
  await execFile("git", ["reset", "--hard", "origin/main"], { cwd: projectPath });

  // 4. Rebase ticket branch onto main
  await execFile("git", ["rebase", branchName], { cwd: projectPath });

  // 5. Push to origin
  await execFile("git", ["push", "origin", "main"], { cwd: projectPath });

  // 6. Cleanup: remove worktree and branch
  await execFile("git", ["worktree", "remove", worktreePath], { cwd: projectPath });
  await execFile("git", ["branch", "-d", branchName], { cwd: projectPath });

  return { success: true, branch: branchName };
}
```

### 2.4 Lifecycle Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  Ticket Created                                                   │
│       │                                                           │
│       ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  git fetch origin                                            │ │
│  │  git branch ticket/{id} origin/main                         │ │
│  │  git worktree add .worktrees/{id} ticket/{id}               │ │
│  └─────────────────────────────────────────────────────────────┘ │
│       │                                                           │
│       ▼                                                           │
│  Agent Works (in worktree)                                        │
│       │                                                           │
│       ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  git add -A                                                  │ │
│  │  git commit -m "feat(scope): description"                   │ │
│  │  (repeat as needed)                                          │ │
│  └─────────────────────────────────────────────────────────────┘ │
│       │                                                           │
│       ▼                                                           │
│  Human Approves                                                   │
│       │                                                           │
│       ▼                                                           │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  git fetch origin                                            │ │
│  │  git checkout main                                           │ │
│  │  git reset --hard origin/main                                │ │
│  │  git rebase ticket/{id}                                      │ │
│  │  git push origin main                                        │ │
│  │  git worktree remove .worktrees/{id}                        │ │
│  │  git branch -d ticket/{id}                                   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│       │                                                           │
│       ▼                                                           │
│  Done ✓                                                           │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Branch Strategy

### 3.1 Branch Naming

```
ticket/{ticket-id}
```

Examples:
- `ticket/abc123`
- `ticket/def456`

All branches are short-lived — deleted after finalization.

### 3.2 Branch Rules

| Rule | Enforcement |
|------|-------------|
| Always branch from `origin/main` | Automated at worktree creation |
| Never commit directly to `main` | Main worktree is read-only during development |
| Always rebase, never merge | Automated at finalization |
| Delete branch after finalization | Automated cleanup |

### 3.3 Git Concurrency & Conflict Strategy

Worktrees give each agent its own working directory, but they share a single `.git/` directory. This creates two distinct concurrency problems:

1. **Git operation contention** — concurrent git commands from different agents fight over shared locks in `.git/` (index.lock, packed-refs.lock, refs/heads/)
2. **Rebase-time merge conflicts** — when two tickets modify the same files, the second finalization fails

#### 3.3.1 Git Operation Queue

All git operations that touch the shared `.git/` must be serialized per-project:

```typescript
/**
 * Per-project operation queue. Serializes ALL git commands that touch
 * the shared .git/ directory (fetch, branch, rebase, gc, etc.).
 *
 * Worktree-local operations (add, commit within a worktree) use the
 * worktree's own index and don't need the queue — UNLESS they also
 * touch shared refs (e.g., creating tags, fetching).
 */
class GitOperationQueue {
  private locks = new Map<string, AsyncLock>();

  private getLock(projectPath: string): AsyncLock {
    if (!this.locks.has(projectPath)) {
      this.locks.set(projectPath, new AsyncLock());
    }
    return this.locks.get(projectPath)!;
  }

  /** Run a git command that touches shared .git/ state */
  async shared<T>(projectPath: string, fn: () => Promise<T>): Promise<T> {
    return this.getLock(projectPath).acquire("shared", fn);
  }

  /** Run a git command local to a worktree (add, commit, status, diff) */
  async local<T>(worktreePath: string, fn: () => Promise<T>): Promise<T> {
    // No serialization needed — worktree index is independent
    return fn();
  }
}

const gitQueue = new GitOperationQueue();
```

**Which operations need the queue:**

| Operation | Touches shared `.git/`? | Needs queue? |
|-----------|------------------------|--------------|
| `git add` (in worktree) | No (uses worktree index) | No |
| `git commit` (in worktree) | Yes (writes objects, updates refs) | **Yes** |
| `git status` (in worktree) | No (reads worktree index) | No |
| `git diff` (in worktree) | No (reads only) | No |
| `git fetch origin` | Yes (updates remote refs, objects) | **Yes** |
| `git branch create/delete` | Yes (writes refs/heads/) | **Yes** |
| `git worktree add/remove` | Yes (writes .git/worktrees/) | **Yes** |
| `git rebase` | Yes (writes objects, moves refs) | **Yes** |
| `git gc` / `git prune` | Yes (repacks objects) | **Yes** |
| `git push` | Yes (reads refs, objects) | **Yes** |

**Usage:**

```typescript
// Agent committing in its worktree — needs queue because it writes objects/refs
await gitQueue.shared(projectPath, () =>
  execFile("git", ["commit", "-m", msg], { cwd: worktreePath })
);

// Agent checking status — no queue needed
const status = await gitQueue.local(worktreePath, () =>
  execFile("git", ["status", "--porcelain"], { cwd: worktreePath })
);

// Fetch before finalization — needs queue
await gitQueue.shared(projectPath, () =>
  execFile("git", ["fetch", "origin"], { cwd: projectPath })
);
```

#### 3.3.2 Why Rebase Conflicts Happen

```
Timeline:
  T0: Ticket A branches from main (auth.ts v1)
  T1: Ticket B branches from main (auth.ts v1)
  T2: Ticket A edits auth.ts → auth.ts v2a
  T3: Ticket B edits auth.ts → auth.ts v2b
  T4: Ticket A finalizes (rebase onto main) → main has auth.ts v2a ✓
  T5: Ticket B finalizes (rebase onto main) → CONFLICT: v2a vs v2b ✗
```

#### 3.3.3 Finalization Lock (Sequential Guarantee)

Finalizations are serialized per-project to prevent race conditions:

```typescript
const finalizationLock = new AsyncLock();

async function finalizeTicket(projectPath: string, ticketId: string) {
  await finalizationLock.acquire(projectPath, async () => {
    await doFinalize(projectPath, ticketId);
  });
}
```

This ensures only one rebase runs at a time, but does NOT prevent conflicts.

#### 3.3.4 Pre-Flight Conflict Detection

Before attempting finalization, check for overlapping file changes:

```typescript
async function detectPotentialConflicts(
  projectPath: string,
  ticketId: string
): Promise<ConflictCheck> {
  const branchName = `ticket/${ticketId}`;

  // Files changed by this ticket vs its fork point
  const mergeBase = await execFile("git", [
    "merge-base", branchName, "origin/main"
  ], { cwd: projectPath });
  const base = mergeBase.stdout.trim();

  // Files this ticket changed
  const ticketFiles = await execFile("git", [
    "diff", "--name-only", base, branchName
  ], { cwd: projectPath });

  // Files changed on main since this ticket branched
  const mainFiles = await execFile("git", [
    "diff", "--name-only", base, "origin/main"
  ], { cwd: projectPath });

  const ticketSet = new Set(ticketFiles.stdout.trim().split("\n").filter(Boolean));
  const mainSet = new Set(mainFiles.stdout.trim().split("\n").filter(Boolean));

  const overlapping = [...ticketSet].filter(f => mainSet.has(f));

  return {
    hasOverlap: overlapping.length > 0,
    overlappingFiles: overlapping,
    ticketFiles: [...ticketSet],
    mainChangedFiles: [...mainSet],
  };
}
```

#### 3.3.5 Conflict Resolution Flow

When a rebase conflict is detected:

```typescript
type ConflictResolution =
  | { action: "auto-resolve"; strategy: "rebase-retry" }
  | { action: "agent-resolve"; ticketId: string }
  | { action: "human-required"; reason: string };

async function handleRebaseConflict(
  projectPath: string,
  ticketId: string,
  conflictFiles: string[]
): Promise<ConflictResolution> {
  // 1. Abort the failed rebase
  await execFile("git", ["rebase", "--abort"], { cwd: projectPath });

  // 2. Check conflict complexity
  const complexity = await assessConflictComplexity(projectPath, ticketId, conflictFiles);

  if (complexity === "trivial") {
    // Non-overlapping changes in same file (e.g., different functions)
    // → Re-queue for agent to rebase interactively in its worktree
    return { action: "agent-resolve", ticketId };
  }

  // 3. For non-trivial conflicts → flag for human review
  return {
    action: "human-required",
    reason: `Rebase conflict in ${conflictFiles.length} file(s): ${conflictFiles.join(", ")}`,
  };
}
```

#### 3.3.6 Agent-Assisted Conflict Resolution

For resolvable conflicts, re-assign to the agent:

```typescript
async function requestAgentConflictResolution(
  projectPath: string,
  ticketId: string,
  conflictFiles: string[]
): Promise<void> {
  const worktreePath = path.join(projectPath, ".worktrees", ticketId);

  // Rebase the ticket branch onto origin/main inside the worktree
  // The agent can see and resolve conflicts in its own workspace
  await gateway.request("agent", {
    agentId: project.agentId,
    sessionKey: buildBonsaiSessionKey({ agentId: project.agentId, projectId: project.id, ticketId }),
    message: [
      `Your branch has conflicts with main in these files: ${conflictFiles.join(", ")}`,
      `Run \`git rebase origin/main\` in your worktree, resolve conflicts, then mark as ready.`,
      `Do NOT force-push or delete any branches.`,
    ].join("\n"),
    workingDirectory: worktreePath,
  });

  // Move ticket back to "In Progress" with conflict flag
  await db.tickets.update(ticketId, {
    state: "in_progress",
    flags: { conflictResolution: true, conflictFiles },
  });
}
```

#### 3.3.7 Ticket State Transitions for Conflicts

```
Done (approved) → Finalize attempt → Conflict detected
                                          │
                    ┌─────────────────────┤
                    │                     │
                    ▼                     ▼
          Agent re-resolve        Human required
          (back to In Progress)   (flag in UI, stays in Done)
                    │                     │
                    ▼                     ▼
          Agent resolves          Human resolves in IDE
                    │                     │
                    ▼                     ▼
          Re-approve → Finalize   Re-approve → Finalize
```

#### 3.3.8 Prevention: File Overlap Awareness (Optional)

The scheduler can optionally track which files each active ticket is modifying, and warn or defer when overlap is detected:

```typescript
async function checkFileOverlap(
  projectPath: string,
  activeTicketIds: string[]
): Promise<Map<string, string[]>> {
  const fileToTickets = new Map<string, string[]>();

  for (const ticketId of activeTicketIds) {
    const worktreePath = path.join(projectPath, ".worktrees", ticketId);
    const diff = await execFile("git", [
      "diff", "--name-only", "origin/main"
    ], { cwd: worktreePath });

    for (const file of diff.stdout.trim().split("\n").filter(Boolean)) {
      const existing = fileToTickets.get(file) ?? [];
      existing.push(ticketId);
      fileToTickets.set(file, existing);
    }
  }

  // Return only files with >1 ticket editing
  return new Map([...fileToTickets].filter(([_, tickets]) => tickets.length > 1));
}

---

## 4. Commit Format

### 4.1 Conventional Commits

All commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

### 4.2 Types

| Type | When to Use |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `refactor` | Code change that neither fixes nor adds feature |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `chore` | Maintenance, dependencies, config |
| `style` | Formatting, whitespace (no code change) |

### 4.3 Scope

Optional, indicates the area of the codebase:

```
feat(auth): add OAuth login flow
fix(api): handle rate limit errors
refactor(db): simplify query builder
```

### 4.4 Footer

Always include ticket reference and agent identity:

```
feat(auth): add Google OAuth provider

Implement Google OAuth login using passport-google-oauth20.
Includes callback handling and session management.

Ticket: ticket-abc123
Agent: my-app-dev
```

### 4.5 Commit Message Builder

```typescript
interface CommitMessage {
  type: "feat" | "fix" | "refactor" | "docs" | "test" | "chore" | "style";
  scope?: string;
  description: string;
  body?: string;
  ticketId: string;
  agentId: string;
}

function formatCommitMessage(msg: CommitMessage): string {
  const header = msg.scope
    ? `${msg.type}(${msg.scope}): ${msg.description}`
    : `${msg.type}: ${msg.description}`;

  const parts = [header];

  if (msg.body) {
    parts.push("", msg.body);
  }

  parts.push("", `Ticket: ${msg.ticketId}`, `Agent: ${msg.agentId}`);

  return parts.join("\n");
}
```

### 4.6 Commit Granularity

Agents commit after completing each **todo item** from the implementation plan:

```markdown
## TODO
- [x] Add passport-google-oauth20 dependency     → commit 1
- [x] Create OAuth callback route                → commit 2
- [x] Implement session handling                 → commit 3
- [ ] Add tests
- [ ] Update documentation
```

This provides:
- Clear git history showing progression
- Easy to bisect if issues arise
- Natural checkpoints for recovery

---

## 5. Author Identity

### 5.1 Git Author Config

Each agent has its own git identity:

```typescript
async function configureAgentIdentity(
  worktreePath: string,
  agentId: string,
  projectName: string
): Promise<void> {
  const name = `${projectName} Agent`;
  const email = `${agentId}@bonsai.local`;

  await execFile("git", ["config", "user.name", name], { cwd: worktreePath });
  await execFile("git", ["config", "user.email", email], { cwd: worktreePath });
}
```

**Example commits:**
```
Author: My App Agent <my-app-dev@bonsai.local>
Date:   Tue Feb 4 10:30:00 2026

    feat(auth): add Google OAuth provider

    Ticket: ticket-abc123
    Agent: my-app-dev
```

### 5.2 Why Local Email Domain

Using `@bonsai.local`:
- Clearly identifies agent commits
- Won't accidentally match real GitHub accounts
- No GitHub avatar/profile implications
- Easy to filter in git log

---

## 6. Safety Rails

### 6.1 Never Force Push

```typescript
// Force push is never used — always regular push after rebase
await execFile("git", ["push", "origin", "main"], { cwd: projectPath });

// NOT: git push --force
```

### 6.2 Never Delete Main

```typescript
const PROTECTED_BRANCHES = ["main", "master"];

async function deleteBranch(projectPath: string, branch: string): Promise<void> {
  if (PROTECTED_BRANCHES.includes(branch)) {
    throw new Error(`Cannot delete protected branch: ${branch}`);
  }
  await execFile("git", ["branch", "-d", branch], { cwd: projectPath });
}
```

### 6.3 Worktree Isolation

Agents can only access their ticket's worktree:

```typescript
function validateWorktreeAccess(
  agentTicketId: string,
  requestedPath: string
): boolean {
  const expectedWorktree = `.worktrees/${agentTicketId}`;
  return requestedPath.includes(expectedWorktree);
}
```

### 6.4 Main Worktree is Read-Only

During development, the main worktree (project root) is not modified. Only used for finalization.

---

## 7. Worktree Management

### 7.1 Worktree Lifecycle

| Event | Action |
|-------|--------|
| Ticket → Research | Create worktree |
| Ticket → In Progress | Worktree already exists |
| Ticket → Done (approved) | Finalize → delete worktree |
| Ticket → Backlog (rejected) | Delete worktree, preserve branch (optional) |

### 7.2 List Worktrees

```typescript
async function listWorktrees(projectPath: string): Promise<Worktree[]> {
  const result = await execFile(
    "git", ["worktree", "list", "--porcelain"],
    { cwd: projectPath }
  );

  return parseWorktreeList(result.stdout);
}
```

### 7.3 Orphaned Worktree Cleanup

On startup, clean up orphaned worktrees (from crashes, etc.):

```typescript
async function cleanupOrphanedWorktrees(projectPath: string): Promise<void> {
  const worktrees = await listWorktrees(projectPath);
  const activeTicketIds = await db.tickets.listActive(projectId);

  for (const wt of worktrees) {
    if (wt.path.includes(".worktrees/")) {
      const ticketId = extractTicketId(wt.path);
      if (!activeTicketIds.includes(ticketId)) {
        await execFile("git", ["worktree", "remove", "--force", wt.path], {
          cwd: projectPath,
        });
      }
    }
  }
}
```

---

## 8. Error Handling

### 8.1 Finalization Failure

If finalization fails (e.g., push rejected):

```typescript
async function finalizeWithRetry(
  projectPath: string,
  ticketId: string
): Promise<FinalizeResult> {
  const maxRetries = 3;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await finalizeTicket(projectPath, ticketId);
    } catch (error) {
      if (attempt === maxRetries) {
        // Mark ticket as finalization-failed
        await db.tickets.update(ticketId, {
          state: "finalization_failed",
          error: error.message,
        });
        throw error;
      }

      // Fetch and retry
      await execFile("git", ["fetch", "origin"], { cwd: projectPath });
      await sleep(1000 * attempt);
    }
  }
}
```

### 8.2 Recovery States

| State | Cause | Recovery |
|-------|-------|----------|
| `finalization_failed` | Push rejected, network error | Manual retry or admin intervention |
| `worktree_missing` | Worktree deleted unexpectedly | Recreate from branch |
| `branch_missing` | Branch deleted unexpectedly | Recreate worktree from scratch |

---

## 9. Git Commands Reference

### 9.1 Setup Commands

```bash
# Create ticket branch from origin/main
git fetch origin
git branch ticket/{id} origin/main
git worktree add .worktrees/{id} ticket/{id}

# Configure agent identity in worktree
git -C .worktrees/{id} config user.name "Project Agent"
git -C .worktrees/{id} config user.email "agent@bonsai.local"
```

### 9.2 Development Commands

```bash
# Stage and commit (in worktree)
git -C .worktrees/{id} add -A
git -C .worktrees/{id} commit -m "feat(scope): description"

# Check status
git -C .worktrees/{id} status
git -C .worktrees/{id} log --oneline -5
```

### 9.3 Finalization Commands

```bash
# Finalize ticket work
git fetch origin
git checkout main
git reset --hard origin/main
git rebase ticket/{id}
git push origin main

# Cleanup
git worktree remove .worktrees/{id}
git branch -d ticket/{id}
```

### 9.4 Maintenance Commands

```bash
# List all worktrees
git worktree list

# Prune stale worktrees
git worktree prune

# List ticket branches
git branch --list "ticket/*"
```

---

## 10. Integration Points

### 10.1 With Work Scheduler

When scheduler assigns work to a ticket, ensure worktree exists:

```typescript
async function prepareTicketForWork(ticketId: string): Promise<string> {
  const ticket = await db.tickets.get(ticketId);
  const project = await db.projects.get(ticket.projectId);

  if (!ticket.worktreePath) {
    const worktreePath = await createTicketWorktree(project.path, ticketId);
    await db.tickets.update(ticketId, { worktreePath });
    return worktreePath;
  }

  return ticket.worktreePath;
}
```

### 10.2 With Agent Execution

Agent's workspace is the ticket worktree:

```typescript
// When spawning agent for ticket work
const worktreePath = await prepareTicketForWork(ticketId);

await gateway.request("agent", {
  agentId: project.agentId,
  sessionKey: `bonsai:${project.id}:ticket:${ticketId}`,
  message: buildAgentPrompt(ticket),
  // Agent works in worktree directory
  workingDirectory: worktreePath,
});
```

### 10.3 With Board UI

Show git status in ticket card:

```typescript
async function getTicketGitStatus(ticketId: string): Promise<GitStatus> {
  const ticket = await db.tickets.get(ticketId);

  if (!ticket.worktreePath) {
    return { hasWorktree: false };
  }

  const result = await execFile(
    "git", ["log", "--oneline", "-5"],
    { cwd: ticket.worktreePath }
  );

  return {
    hasWorktree: true,
    recentCommits: parseCommitLog(result.stdout),
    branch: `ticket/${ticketId}`,
  };
}
```
