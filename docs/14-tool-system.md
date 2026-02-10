# Bonsai Tool System — Design Document

Date: 2026-02-04

## Overview

Agents do work through tools. Every action an agent takes — reading a file, running a command, posting a comment, checking acceptance criteria — goes through the tool system.

Tools come from three sources:
1. **Extracted from OpenClaw** — file operations, bash execution, git, web search
2. **Bonsai-specific** — ticket management, comments, project queries, board operations
3. **Custom CLI tools** — standalone executables built for specific workflows

All tools execute through the `ToolExecutor` abstraction (see doc 13), which means the same tool works whether running locally (v1) or inside a Docker container (v2).

---

## 1. Tool Sources

### 1.1 Extracted from OpenClaw

These are the core development tools. Extracted from OpenClaw's `src/agents/pi-tools.ts` and related files.

| Tool | OpenClaw Source | What It Does |
|------|----------------|-------------|
| `bash` | `src/agents/bash-tools.exec.ts` | Execute shell commands in workspace |
| `file_read` | `src/agents/pi-tools.read.ts` | Read file contents |
| `file_write` | `src/agents/pi-tools.write.ts` | Write/create files |
| `file_edit` | `src/agents/pi-tools.write.ts` | Edit existing files (search/replace) |
| `file_list` | `src/agents/pi-tools.ts` | List files matching a pattern |
| `web_search` | `src/agents/pi-tools.ts` | Search the web for information |
| `web_fetch` | `src/agents/pi-tools.ts` | Fetch content from a URL |

**Bonsai modifications to extracted tools:**
- All file/bash tools route through `ToolExecutor` (not direct process spawning or `fs` calls)
- Path arguments are relative to the project workspace root
- The agent never sees absolute paths
- Removed: channel tools, messaging tools, voice tools

### 1.2 Bonsai-Specific Tools

These tools let the agent interact with the Bonsai system — reading its board, posting comments, updating ticket state. They read/write the shared SQLite database.

| Tool | What It Does |
|------|-------------|
| `ticket_read` | Read ticket details — title, description, acceptance criteria, state, comments |
| `ticket_update_state` | Move a ticket between states (RESEARCH → IN_PROGRESS → VERIFICATION) |
| `comment_post` | Post a comment on a ticket (question, status update, or completion note) |
| `comment_list` | Read all comments on a ticket, including human feedback |
| `comment_resolve` | Mark a comment thread as resolved |
| `acceptance_check` | Read acceptance criteria and check which are met |
| `project_info` | Read project metadata — repo URL, language, branch, persona |
| `board_read` | Read the full board state — all tickets and their states |

**These tools are NOT extracted from OpenClaw.** They are new, Bonsai-native, and operate on Bonsai's SQLite database.

### 1.3 Custom CLI Tools

Standalone executables that the agent invokes through the `ToolExecutor`. These are built as part of the Bonsai codebase and installed alongside it.

**Why CLI tools:**
- Independently testable (run them from the terminal, no agent needed)
- Naturally respect the ToolExecutor boundary (`executor.exec("bonsai-tool", [...args], opts)`)
- Can be swapped, versioned, and extended without touching the agent runner
- Work locally (v1) and inside containers (v2) with no changes

**Examples of custom CLI tools:**

| Tool | Command | What It Does |
|------|---------|-------------|
| `bonsai-analyze` | `bonsai-analyze <repo-path>` | Analyze a repo — detect language, framework, test runner, project structure |
| `bonsai-plan` | `bonsai-plan <ticket-file>` | Generate an implementation plan from a ticket description |
| `bonsai-test` | `bonsai-test <repo-path>` | Run the project's test suite, parse results into structured output |
| `bonsai-lint` | `bonsai-lint <repo-path>` | Run the project's linter, parse results |
| `bonsai-git` | `bonsai-git <operation> [args]` | Git operations scoped to a workspace (commit, push, branch, worktree) |
| `bonsai-criteria` | `bonsai-criteria check <ticket-id>` | Evaluate acceptance criteria against current code state |

**CLI tool contract:**
- Accept arguments via CLI flags (no stdin interaction)
- Output structured JSON to stdout
- Exit code 0 = success, non-zero = failure
- Stderr for human-readable error messages
- No interactive prompts — agents can't type into them

```typescript
// Example: bonsai-analyze output
{
  "language": "typescript",
  "framework": "nextjs",
  "packageManager": "pnpm",
  "testRunner": "vitest",
  "sourceFiles": 47,
  "structure": {
    "src/app": "Next.js app router pages",
    "src/components": "React components",
    "src/lib": "Utility functions"
  }
}
```

---

## 2. Tool Registration

### 2.1 Tool Definitions

Tools are defined as structured objects that the LLM understands. Each tool has a name, description, and parameter schema.

```typescript
interface ToolDefinition {
  name: string;
  description: string;
  parameters: JsonSchema;
  execute: (params: Record<string, unknown>, ctx: ToolContext) => Promise<ToolResult>;
}

interface ToolContext {
  projectId: string;
  ticketId: string;
  workspace: Workspace;
  db: PrismaClient;
}

interface ToolResult {
  output: string;
  error?: string;
  metadata?: Record<string, unknown>;
}
```

### 2.2 Tool Assembly

For each agent run, the tool set is assembled based on the project and ticket context:

```typescript
function assembleTools(ctx: ToolContext): ToolDefinition[] {
  return [
    // Extracted development tools (via ToolExecutor)
    ...createFileTools(ctx.workspace.executor),
    ...createBashTools(ctx.workspace.executor),
    ...createGitTools(ctx.workspace.executor),
    ...createWebTools(),

    // Bonsai-specific tools (via DB)
    ...createTicketTools(ctx.db, ctx.projectId, ctx.ticketId),
    ...createCommentTools(ctx.db, ctx.ticketId),
    ...createBoardTools(ctx.db, ctx.projectId),

    // Custom CLI tools (via ToolExecutor)
    ...createCliTools(ctx.workspace.executor),
  ];
}
```

### 2.3 Tool Profiles

Different contexts may need different tool subsets. Profiles control which tools are available.

| Profile | Tools Included | Use Case |
|---------|---------------|----------|
| `developer` | All file, bash, git, web, ticket, comment, CLI tools | Default for development work |
| `researcher` | File read, web search/fetch, ticket read, comment, project info | Research phase — no writes |
| `reviewer` | File read, git (read-only), ticket, comment | Code review — read and comment only |

```typescript
function applyToolProfile(
  tools: ToolDefinition[],
  profile: string
): ToolDefinition[] {
  const profiles: Record<string, string[]> = {
    developer: ["*"],
    researcher: [
      "file_read", "file_list", "web_search", "web_fetch",
      "ticket_read", "comment_*", "project_info", "board_read",
    ],
    reviewer: [
      "file_read", "file_list", "bonsai-git",
      "ticket_read", "comment_*", "acceptance_check",
    ],
  };

  const allowed = profiles[profile] ?? profiles.developer;

  if (allowed.includes("*")) return tools;

  return tools.filter((tool) =>
    allowed.some((pattern) =>
      pattern.endsWith("*")
        ? tool.name.startsWith(pattern.slice(0, -1))
        : tool.name === pattern
    )
  );
}
```

---

## 3. Bonsai-Specific Tool Implementations

### 3.1 ticket_read

```typescript
const ticketReadTool: ToolDefinition = {
  name: "ticket_read",
  description: "Read the current ticket's details including title, description, acceptance criteria, state, and recent comments.",
  parameters: {
    type: "object",
    properties: {},
    required: [],
  },
  async execute(_params, ctx) {
    const ticket = await ctx.db.ticket.findUnique({
      where: { id: ctx.ticketId },
      include: {
        comments: { orderBy: { createdAt: "desc" }, take: 20 },
        documents: true,
      },
    });

    return {
      output: JSON.stringify({
        title: ticket.title,
        description: ticket.description,
        state: ticket.state,
        subState: ticket.subState,
        comments: ticket.comments.map((c) => ({
          author: c.authorName,
          type: c.authorType,
          content: c.content,
          resolved: c.resolved,
          createdAt: c.createdAt,
        })),
        documents: ticket.documents.map((d) => ({
          type: d.type,
          status: d.status,
        })),
      }, null, 2),
    };
  },
};
```

### 3.2 comment_post

```typescript
const commentPostTool: ToolDefinition = {
  name: "comment_post",
  description: "Post a comment on the current ticket. Use type 'question' when blocked and need human input. Use 'status' for progress updates. Use 'completion' when all acceptance criteria are met.",
  parameters: {
    type: "object",
    properties: {
      content: { type: "string", description: "The comment text" },
      type: {
        type: "string",
        enum: ["question", "status", "completion"],
        description: "The type of comment",
      },
    },
    required: ["content", "type"],
  },
  async execute(params, ctx) {
    const comment = await ctx.db.comment.create({
      data: {
        ticketId: ctx.ticketId,
        authorType: "agent",
        authorId: ctx.projectId,
        authorName: "Agent",
        content: params.content as string,
        resolved: false,
      },
    });

    return {
      output: `Comment posted: ${comment.id}`,
      metadata: { commentType: params.type },
    };
  },
};
```

### 3.3 ticket_update_state

```typescript
const ticketUpdateStateTool: ToolDefinition = {
  name: "ticket_update_state",
  description: "Move the current ticket to a new state. Valid transitions: RESEARCH → IN_PROGRESS, IN_PROGRESS → VERIFICATION. Only move to VERIFICATION when ALL acceptance criteria are met.",
  parameters: {
    type: "object",
    properties: {
      state: {
        type: "string",
        enum: ["RESEARCH", "IN_PROGRESS", "VERIFICATION"],
        description: "The target state",
      },
      reason: {
        type: "string",
        description: "Why this state change is happening",
      },
    },
    required: ["state", "reason"],
  },
  async execute(params, ctx) {
    const ticket = await ctx.db.ticket.findUnique({
      where: { id: ctx.ticketId },
    });

    const validTransitions: Record<string, string[]> = {
      RESEARCH: ["IN_PROGRESS"],
      IN_PROGRESS: ["VERIFICATION"],
    };

    const allowed = validTransitions[ticket.state] ?? [];
    if (!allowed.includes(params.state as string)) {
      return {
        output: `Invalid transition: ${ticket.state} → ${params.state}`,
        error: "invalid_transition",
      };
    }

    await ctx.db.ticket.update({
      where: { id: ctx.ticketId },
      data: { state: params.state as string },
    });

    return {
      output: `Ticket moved from ${ticket.state} to ${params.state}: ${params.reason}`,
    };
  },
};
```

---

## 4. CLI Tool Development

### 4.1 Structure

CLI tools live in the monorepo under `packages/tools/`:

```
packages/tools/
├── package.json
├── src/
│   ├── analyze.ts          # bonsai-analyze
│   ├── test-runner.ts      # bonsai-test
│   ├── lint-runner.ts      # bonsai-lint
│   ├── git-ops.ts          # bonsai-git
│   └── criteria-check.ts   # bonsai-criteria
└── bin/
    ├── bonsai-analyze
    ├── bonsai-test
    ├── bonsai-lint
    ├── bonsai-git
    └── bonsai-criteria
```

### 4.2 CLI Tool Template

```typescript
#!/usr/bin/env node
// packages/tools/src/analyze.ts

import { parseArgs } from "node:util";

const { positionals } = parseArgs({
  allowPositionals: true,
  strict: true,
});

const repoPath = positionals[0];
if (!repoPath) {
  console.error("Usage: bonsai-analyze <repo-path>");
  process.exit(1);
}

async function analyze(repoPath: string) {
  // ... analysis logic
  const result = {
    language: "typescript",
    framework: "nextjs",
    // ...
  };

  // Output structured JSON to stdout
  console.log(JSON.stringify(result, null, 2));
}

analyze(repoPath).catch((err) => {
  console.error(err.message);
  process.exit(1);
});
```

### 4.3 Registering CLI Tools as Agent Tools

CLI tools are wrapped as agent tool definitions:

```typescript
function createCliTool(
  name: string,
  command: string,
  description: string,
  paramSchema: JsonSchema
): ToolDefinition {
  return {
    name,
    description,
    parameters: paramSchema,
    async execute(params, ctx) {
      const args = buildArgs(params);
      const result = await ctx.workspace.executor.exec(command, args, {
        cwd: ctx.workspace.rootPath,
        timeout: 60_000,
      });

      if (result.exitCode !== 0) {
        return {
          output: result.stderr || `Command failed with exit code ${result.exitCode}`,
          error: "tool_failed",
        };
      }

      return { output: result.stdout };
    },
  };
}

// Register CLI tools
function createCliTools(executor: ToolExecutor): ToolDefinition[] {
  return [
    createCliTool(
      "analyze_project",
      "bonsai-analyze",
      "Analyze the project structure, detect language, framework, and test runner.",
      { type: "object", properties: {}, required: [] }
    ),
    createCliTool(
      "run_tests",
      "bonsai-test",
      "Run the project's test suite and return structured results.",
      { type: "object", properties: {}, required: [] }
    ),
    createCliTool(
      "run_linter",
      "bonsai-lint",
      "Run the project's linter and return issues found.",
      { type: "object", properties: {}, required: [] }
    ),
    createCliTool(
      "check_criteria",
      "bonsai-criteria",
      "Evaluate acceptance criteria against the current code state.",
      {
        type: "object",
        properties: {
          ticketId: { type: "string", description: "Ticket ID to check criteria for" },
        },
        required: ["ticketId"],
      }
    ),
  ];
}
```

---

## 5. Tool Execution Flow

```
Agent LLM generates tool call
  → Tool dispatch resolves the tool definition
  → Tool's execute() is called with params + context
    → For file/bash/git/CLI tools: routes through ToolExecutor
    → For Bonsai tools: reads/writes SQLite directly
  → Result returned to LLM as tool response
  → LLM continues or calls another tool
```

### ToolExecutor Path (development tools + CLI tools)

```
Agent calls "bash" tool with command "npm test"
  → BashTool.execute() called
  → ctx.workspace.executor.exec("npm", ["test"], { cwd: workspace.rootPath })
    → V1: execFile("npm", ["test"], { cwd: "/home/user/.bonsai/projects/my-app" })
    → V2: docker exec <container> npm test
  → Result (stdout/stderr/exitCode) returned to agent
```

### Direct DB Path (Bonsai tools)

```
Agent calls "comment_post" with { content: "Need clarification on auth flow", type: "question" }
  → CommentPostTool.execute() called
  → ctx.db.comment.create({ ... })
  → "Comment posted: cuid_abc123" returned to agent
```

---

## 6. Adding New Tools

### Adding a New Bonsai Tool

1. Define the tool in `packages/agent/src/tools/bonsai/`
2. Add it to `createTicketTools()` or `createBoardTools()` assembly
3. Add it to relevant tool profiles

### Adding a New CLI Tool

1. Create the executable in `packages/tools/src/`
2. Add a bin entry in `packages/tools/package.json`
3. Wrap it with `createCliTool()` in `packages/agent/src/tools/cli.ts`
4. Add it to `createCliTools()` assembly

### Adding a Tool from OpenClaw

1. Extract the tool implementation from OpenClaw source
2. Refactor to use `ToolExecutor` instead of direct process/fs calls
3. Add to `packages/agent/src/tools/dev/`
4. Register in `createFileTools()` / `createBashTools()` / etc.

---

## 7. Cross-References

| Topic | Document |
|-------|----------|
| ToolExecutor interface | [13-agent-runtime.md](./13-agent-runtime.md) §4.1 |
| WorkspaceProvider interface | [13-agent-runtime.md](./13-agent-runtime.md) §4.2 |
| AgentRunner (tool dispatch) | [13-agent-runtime.md](./13-agent-runtime.md) §4.3 |
| Heartbeat (when tools run) | [13-agent-runtime.md](./13-agent-runtime.md) §1 |
| Comments as communication | [13-agent-runtime.md](./13-agent-runtime.md) §2 |
| Ticket lifecycle | [13-agent-runtime.md](./13-agent-runtime.md) §2 |
| Extraction plan | [AGENT_EXTRACT_TODO.md](./AGENT_EXTRACT_TODO.md) §2 |
| Package structure | [13-agent-runtime.md](./13-agent-runtime.md) §10 |
| Database schema (tickets, comments) | [12-technology-stack.md](./12-technology-stack.md) |
| V1 vs V2 security | [13-agent-runtime.md](./13-agent-runtime.md) §9 |
