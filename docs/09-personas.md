# Bonsai Personas — Design Document

Date: 2026-02-04

## Overview

**Personas** are the core abstraction in Bonsai for defining agent behavior. Each persona is a complete agent template containing all the files an OpenClaw agent needs (SOUL.md, MEMORY.md, TOOLS.md, etc.) plus Bonsai-specific identity (name, gender, profile picture).

Personas are **system-level** resources stored at `~/.bonsai/personas/`. Projects reference a persona but don't copy the files — at runtime, Bonsai loads the persona and injects project/ticket context.

**Key design decision:** Bonsai skips OpenClaw's "name your agent" onboarding step. Instead, Bonsai creates a special **project manager** persona that orchestrates all other personas.

---

## 1. Persona Architecture

### 1.1 The Project Manager

The **project manager** is a special persona that serves as Bonsai's top-level orchestrator:

```
Project Manager (always running)
       │
       ├── Monitors all projects and tickets
       ├── Runs the work scheduler
       ├── Assigns tickets to appropriate personas
       │
       └── Spins up personas as needed:
           ├── "developer" for coding tickets
           ├── "reviewer" for code review tickets
           ├── "researcher" for research tasks
           └── Custom personas as configured
```

**The project manager:**
- Is created during first-run onboarding
- Uses the default OpenClaw agent
- Runs the scheduler loop (doc 06)
- Loads other personas when tickets need work
- Injects project/ticket context into persona prompts

### 1.2 Work Personas

Work personas do the actual project work (coding, reviewing, researching). When the project manager assigns a ticket, it:

1. Looks up which persona the project uses
2. Loads that persona's files from `~/.bonsai/personas/{name}/`
3. Injects project context (repo, branch, current ticket)
4. Sends the work request to the gateway

```typescript
// Pseudo-code for persona spin-up
async function spinUpPersona(ticket: Ticket): Promise<void> {
  const project = await db.projects.get(ticket.projectId);
  const persona = await loadPersona(project.persona);

  // Build context from persona + project + ticket
  const context = buildAgentContext({
    persona,  // SOUL.md, MEMORY.md, etc.
    project,  // repo URL, branch, language
    ticket,   // description, acceptance criteria, todo
  });

  // Send to gateway
  await gateway.request("agent", {
    agentId: "default",  // Use default OpenClaw agent
    sessionKey: `agent:default:bonsai:${project.id}:ticket:${ticket.id}`,
    message: context,
  });
}
```

---

## 2. Persona File Structure

Each persona contains all standard OpenClaw workspace files plus Bonsai additions:

```
~/.bonsai/personas/{persona-name}/
├── SOUL.md           # Core personality and instructions
├── MEMORY.md         # Pre-loaded knowledge and context
├── IDENTITY.md       # Name, emoji, avatar (OpenClaw format)
├── TOOLS.md          # Tool permissions and policies
├── AGENTS.md         # Subagent definitions
├── USER.md           # User context template
├── HEARTBEAT.md      # Scheduled tasks (optional)
├── BOOTSTRAP.md      # First-run setup (optional)
├── settings.json     # Model, tools, sandbox config
├── persona.json      # Bonsai identity (name, gender, avatar)
└── avatar.png        # Profile picture (generated or custom)
```

### 2.1 OpenClaw Files

These files follow OpenClaw's standard format:

| File | Purpose |
|------|---------|
| `SOUL.md` | Core personality — who the agent is, how it works, rules it follows |
| `MEMORY.md` | Pre-loaded knowledge — patterns, conventions, reference info |
| `IDENTITY.md` | Display identity — name, emoji for messages |
| `TOOLS.md` | Tool permissions — what tools the agent can/can't use |
| `AGENTS.md` | Subagent definitions — agents this persona can spawn |
| `USER.md` | User context — template for user info injection |
| `HEARTBEAT.md` | Scheduled tasks — periodic actions |
| `BOOTSTRAP.md` | First-run setup — initial configuration |

### 2.2 settings.json

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

**Tool profiles:**
- `minimal` — Basic tools only
- `coding` — File editing, exec, git
- `messaging` — Send/receive messages
- `full` — All tools enabled

### 2.3 persona.json

Bonsai-specific identity:

```json
{
  "id": "developer",
  "name": "Devon",
  "gender": "neutral",
  "description": "A software developer focused on clean, maintainable code",
  "profilePicture": "avatar.png",
  "createdAt": "2026-02-04T10:00:00Z",
  "generatedWith": "stable-diffusion",
  "colors": {
    "primary": "#3B82F6",
    "accent": "#60A5FA"
  }
}
```

**Identity fields:**
- `name` — Human name for the persona (Devon, Alex, Jordan, etc.)
- `gender` — For avatar generation (male, female, neutral)
- `description` — Brief description shown in UI
- `profilePicture` — Path to avatar image
- `colors` — UI accent colors for this persona

---

## 3. Built-in Personas

### 3.1 Project Manager

The orchestrator persona, created during onboarding:

```
~/.bonsai/personas/project-manager/
```

**SOUL.md:**
```markdown
# Project Manager

You are the Bonsai project manager, responsible for orchestrating work across all projects and tickets.

## Responsibilities
- Monitor project boards for work that needs attention
- Assign tickets to appropriate personas based on ticket type
- Track progress and report status
- Coordinate between personas when needed

## You Do NOT
- Write code directly (delegate to developer persona)
- Review code (delegate to reviewer persona)
- Conduct research (delegate to researcher persona)

## Scheduling
You run on a schedule to check for pending work. When you find tickets that need attention:
1. Identify the appropriate persona for the ticket
2. Load that persona's context
3. Dispatch the work
4. Monitor for completion or blockers
```

**settings.json:**
```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514"
  },
  "tools": {
    "profile": "minimal"
  }
}
```

### 3.2 Developer

Full-stack software development:

**SOUL.md:**
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

**settings.json:**
```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514",
    "fallbacks": ["claude-haiku-4-20250514"]
  },
  "tools": {
    "profile": "coding"
  },
  "sandbox": {
    "mode": "non-main",
    "workspaceAccess": "rw"
  }
}
```

**persona.json:**
```json
{
  "id": "developer",
  "name": "Devon",
  "gender": "neutral",
  "description": "A software developer focused on clean, maintainable code",
  "colors": { "primary": "#3B82F6", "accent": "#60A5FA" }
}
```

### 3.3 Reviewer

Code review specialist:

**SOUL.md:**
```markdown
# Reviewer

You are a code reviewer focused on quality, correctness, and maintainability.

## Review Focus
- Logic errors and edge cases
- Security vulnerabilities
- Performance issues
- Code style and consistency
- Test coverage

## You Do NOT
- Modify code directly
- Make commits
- Run the application

## Feedback Style
- Be constructive and specific
- Explain the "why" behind suggestions
- Prioritize critical issues over style nits
- Acknowledge good patterns when you see them
```

**settings.json:**
```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514"
  },
  "tools": {
    "profile": "minimal",
    "deny": ["exec.*", "write.*"]
  }
}
```

**persona.json:**
```json
{
  "id": "reviewer",
  "name": "Riley",
  "gender": "neutral",
  "description": "A code reviewer focused on quality and maintainability",
  "colors": { "primary": "#8B5CF6", "accent": "#A78BFA" }
}
```

### 3.4 Researcher

Research and documentation:

**SOUL.md:**
```markdown
# Researcher

You are a researcher who gathers information, explores options, and documents findings.

## Research Process
1. Understand the question or problem
2. Search the codebase for relevant patterns
3. Look up external documentation
4. Synthesize findings into clear documentation

## Output Format
Create structured research documents with:
- Summary of findings
- Options considered (if applicable)
- Recommendations with rationale
- References and links

## You Do NOT
- Write production code
- Make commits
- Make final decisions (recommend, don't decide)
```

**settings.json:**
```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514"
  },
  "tools": {
    "profile": "minimal",
    "alsoAllow": ["web.search", "web.fetch"]
  }
}
```

**persona.json:**
```json
{
  "id": "researcher",
  "name": "Morgan",
  "gender": "neutral",
  "description": "A researcher who explores options and documents findings",
  "colors": { "primary": "#10B981", "accent": "#34D399" }
}
```

### 3.5 DevOps

Infrastructure and deployment:

**SOUL.md:**
```markdown
# DevOps

You are a DevOps engineer focused on infrastructure, CI/CD, and deployment.

## Responsibilities
- Configure build pipelines
- Set up deployment automation
- Manage infrastructure as code
- Monitor and troubleshoot production issues

## Safety Rules
- Never commit secrets or credentials
- Always use environment variables for sensitive data
- Test changes in staging before production
- Document infrastructure changes
```

**settings.json:**
```json
{
  "model": {
    "primary": "claude-sonnet-4-20250514"
  },
  "tools": {
    "profile": "full"
  },
  "sandbox": {
    "mode": "all",
    "workspaceAccess": "rw"
  }
}
```

**persona.json:**
```json
{
  "id": "devops",
  "name": "Jamie",
  "gender": "neutral",
  "description": "A DevOps engineer focused on infrastructure and deployment",
  "colors": { "primary": "#F59E0B", "accent": "#FBBF24" }
}
```

---

## 4. Persona Identity

### 4.1 Name and Gender

Each persona has a human name and gender for:
- Avatar generation
- Natural conversation ("Devon is working on your ticket")
- UI personalization

**Name guidelines:**
- Use gender-neutral names by default (Devon, Alex, Jordan, Morgan, Riley, Jamie)
- Allow customization
- Names should be friendly and approachable

### 4.2 Profile Pictures

Personas have profile pictures (avatars) that can be:
- **Auto-generated** during persona creation (using Stable Diffusion, DALL-E, etc.)
- **Uploaded** by the user
- **Selected** from a built-in library

**Avatar specifications:**
- Size: 256x256 pixels minimum
- Format: PNG with transparency
- Style: Professional, friendly, approachable

### 4.3 Colors

Each persona has associated colors for UI elements:
- `primary` — Main accent color
- `accent` — Secondary/highlight color

Used for:
- Ticket cards when persona is assigned
- Chat bubbles
- Status indicators

---

## 5. How Personas Get Used

### 5.1 At Runtime

When the project manager assigns work to a ticket:

```typescript
async function assignTicket(ticket: Ticket, task: TaskType): Promise<void> {
  // 1. Get project and persona
  const project = await db.projects.get(ticket.projectId);
  const personaName = project.persona;

  // 2. Load persona files
  const personaPath = path.join(BONSAI_MOUNT, "personas", personaName);
  const persona = {
    soul: await fs.readFile(path.join(personaPath, "SOUL.md"), "utf-8"),
    memory: await fs.readFile(path.join(personaPath, "MEMORY.md"), "utf-8"),
    tools: await fs.readFile(path.join(personaPath, "TOOLS.md"), "utf-8"),
    settings: JSON.parse(await fs.readFile(path.join(personaPath, "settings.json"), "utf-8")),
    identity: JSON.parse(await fs.readFile(path.join(personaPath, "persona.json"), "utf-8")),
  };

  // 3. Build context message
  const message = buildTaskMessage({
    persona,
    project,
    ticket,
    task,
  });

  // 4. Send to gateway
  await gateway.request("agent", {
    agentId: "default",
    sessionKey: `agent:default:bonsai:${project.id}:ticket:${ticket.id}`,
    message,
    // settings.json fields get applied here
  });
}
```

### 5.2 Context Injection

The persona's files are combined with project/ticket context:

```markdown
# Context for {persona.identity.name}

## Your Identity
{persona.soul}

## Your Knowledge
{persona.memory}

## Current Project
Repository: {project.repo.url}
Branch: {project.repo.defaultBranch}
Language: {detected language}

## Current Ticket
Title: {ticket.title}
Type: {ticket.type}
State: {ticket.state}

Description:
{ticket.description}

Acceptance Criteria:
{ticket.acceptanceCriteria}

## Your Task
{task-specific instructions}
```

### 5.3 Session Isolation

Each ticket gets its own session key:
```
agent:default:bonsai:{projectId}:ticket:{ticketId}
```

This ensures:
- Ticket work is isolated from other tickets
- Context persists across work cycles
- Project manager can track progress

---

## 6. Custom Personas

### 6.1 Creating a Persona

Users can create custom personas via the UI or manually:

**Via UI:**
1. Go to Settings → Personas
2. Click "Create Persona"
3. Fill in identity (name, description, avatar)
4. Select a base template or start from scratch
5. Edit SOUL.md to define behavior
6. Configure tools and settings

**Manually:**
```bash
# Create directory
mkdir -p ~/.bonsai/personas/my-persona

# Copy from template
cp -r ~/.bonsai/personas/developer/* ~/.bonsai/personas/my-persona/

# Edit files
edit ~/.bonsai/personas/my-persona/SOUL.md
edit ~/.bonsai/personas/my-persona/persona.json
```

### 6.2 Persona Templates

Users can duplicate built-in personas as starting points:

```typescript
async function duplicatePersona(source: string, newName: string): Promise<void> {
  const sourcePath = path.join(PERSONAS_DIR, source);
  const targetPath = path.join(PERSONAS_DIR, newName);

  await fs.cp(sourcePath, targetPath, { recursive: true });

  // Update persona.json with new identity
  const personaJson = path.join(targetPath, "persona.json");
  const persona = JSON.parse(await fs.readFile(personaJson, "utf-8"));
  persona.id = newName;
  persona.createdAt = new Date().toISOString();
  await fs.writeFile(personaJson, JSON.stringify(persona, null, 2));
}
```

### 6.3 Persona Validation

Before using a persona, Bonsai validates it has required files:

```typescript
async function validatePersona(name: string): Promise<ValidationResult> {
  const personaPath = path.join(PERSONAS_DIR, name);

  const required = ["SOUL.md", "settings.json", "persona.json"];
  const optional = ["MEMORY.md", "IDENTITY.md", "TOOLS.md", "AGENTS.md"];

  const missing: string[] = [];
  for (const file of required) {
    try {
      await fs.access(path.join(personaPath, file));
    } catch {
      missing.push(file);
    }
  }

  if (missing.length > 0) {
    return { valid: false, missing };
  }

  return { valid: true };
}
```

---

## 7. Persona Assignment

### 7.1 Project Default

Each project has a default persona set in `project.json`:

```json
{
  "persona": "developer"
}
```

### 7.2 Ticket Override (Future)

In the future, tickets could override the project persona:

```json
{
  "id": "ticket-abc123",
  "persona": "researcher"
}
```

This allows research tickets in a development project to use the researcher persona.

### 7.3 Persona Switching

The project manager can switch personas mid-ticket if needed:
- Research phase → researcher persona
- Implementation phase → developer persona
- Review phase → reviewer persona

---

## 8. UI Integration

### 8.1 Persona Cards

```
┌─────────────────────────────────────┐
│ [Avatar] Devon                      │
│          Developer                  │
│ ─────────────────────────────────── │
│ A software developer focused on     │
│ clean, maintainable code            │
│ ─────────────────────────────────── │
│ Model: claude-sonnet-4              │
│ Tools: coding                       │
│ ─────────────────────────────────── │
│ [Edit] [Duplicate] [Delete]         │
└─────────────────────────────────────┘
```

### 8.2 Persona in Ticket View

When a persona is working on a ticket:

```
┌─────────────────────────────────────┐
│ 🟢 Devon is working...              │
│ ─────────────────────────────────── │
│ Task: Implementing OAuth login      │
│ Progress: ████████░░ 80%            │
│ Started: 5 minutes ago              │
└─────────────────────────────────────┘
```

### 8.3 Persona Selection in Project Settings

```
┌─────────────────────────────────────────────────────────┐
│ Project Settings › Default Persona                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Select the default persona for this project:           │
│                                                         │
│  ◉ Developer (Devon)                                    │
│    Best for: coding, bug fixes, features                │
│                                                         │
│  ○ Reviewer (Riley)                                     │
│    Best for: code review, quality checks                │
│                                                         │
│  ○ Researcher (Morgan)                                  │
│    Best for: exploration, documentation                 │
│                                                         │
│  ○ DevOps (Jamie)                                       │
│    Best for: infrastructure, deployment                 │
│                                                         │
│  ○ Custom: my-special-persona                           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 9. Summary

| Concept | Description |
|---------|-------------|
| **Persona** | Complete agent template with files + identity |
| **Project Manager** | Special orchestrator persona that schedules work |
| **Work Personas** | Personas that do actual project work |
| **System-level** | Personas live in `~/.bonsai/personas/`, not per-project |
| **Reference, not copy** | Projects reference personas, files loaded at runtime |
| **Identity** | Name, gender, profile picture for UI personalization |
| **Teams** | Multiple personas can collaborate on a single ticket — see [15-agent-teams.md](./15-agent-teams.md) |
