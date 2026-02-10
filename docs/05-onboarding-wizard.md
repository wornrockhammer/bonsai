# Bonsai Onboarding Wizard — Design Document

Date: 2026-02-04

> **Architecture note (2026-02-04):** Bonsai is fully self-contained. There is no OpenClaw Gateway, no WebSocket RPC, and no `openclaw.json`. Agents run in-process via the heartbeat model: `cron`/`launchd` fires `bonsai heartbeat`, which reads SQLite, runs agents, writes results, and exits. The web app (Next.js) is the full UI for settings, projects, tickets, docs, and onboarding. All agent-human communication happens via comments on tickets. Some design patterns in this doc trace their extraction origin to OpenClaw, but Bonsai has zero runtime dependency on OpenClaw. See docs `13-agent-runtime.md` and `14-tool-system.md` for the agent execution model and tool system.

## Overview

Bonsai's onboarding wizard is a **web-based** flow designed for non-programmers. It sets up API credentials, creates the `~/.bonsai/` directory, installs the heartbeat service, and optionally installs Docker for project sandboxing.

**Key simplifications:**
- No plugin/skill selection (Bonsai picks sensible defaults)
- No hooks configuration (auto-enabled)
- No Tailscale/advanced networking (loopback only for v1)
- No runtime selection (Node only)
- Single auth provider focus (Claude via Anthropic)
- No channel adapters (Discord, Slack, Telegram) — agents communicate via ticket comments

---

## 1. Wizard Structure

Two distinct flows:

### 1.1 First-Run Setup (Global)
Run once when Bonsai is first installed. Sets up Bonsai infrastructure.

```
+-------------------------------------------------------------+
|                                                             |
|  Step 1: Claude Authentication (Session ID or API Key)     |
|  Step 2: GitHub Token                                       |
|  Step 3: Health Check -> Success -> Create First Project    |
|                                                             |
+-------------------------------------------------------------+
```

**Note:** Heartbeat service installation happens automatically during the health check step. No gateway, no channel setup (Discord, Slack, etc.) — Bonsai uses only the in-app board and ticket comments.

### 1.2 New Project Setup
Run each time user creates a new project. Connects to a GitHub repo.

```
+-------------------------------------------------------------+
|                                                             |
|  Step 1: Repository Selection                               |
|  Step 2: Project Configuration                              |
|  Step 3: Clone & Analyze                                    |
|  Step 4: Success -> Project Board                           |
|                                                             |
+-------------------------------------------------------------+
```

### 1.3 Key Vault (Settings, Post-Onboarding)
Additional API keys for other providers (Gemini, OpenAI, etc.) are added via a local encrypted key vault in Settings, not during onboarding.

---

## 2. First-Run Setup (Detailed)

### Step 1: Claude Authentication

**Purpose:** Connect to Claude via Max subscription (session ID) or API key

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|  Welcome to Bonsai                                          |
|                                                             |
|  Your AI-powered developer workspace.                       |
|                                                             |
|  Let's connect to Claude to power your AI agents.           |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  (*) I have a Claude Max subscription                 |   |
|  |    Use your existing Claude.ai account                |   |
|  |                                                       |   |
|  |  ( ) I have an API key                                |   |
|  |    Use Anthropic API credits                          |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                           [ Continue ]                      |
|                                                             |
+-------------------------------------------------------------+
```

**UI (Max subscription selected):**
```
+-------------------------------------------------------------+
|                                                             |
|  Step 1 of 3                                                |
|                                                             |
|  Connect Claude Max                                         |
|                                                             |
|  To use your Max subscription, we need your session ID.     |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  How to get your session ID:                          |   |
|  |                                                       |   |
|  |  1. Go to claude.ai and sign in                       |   |
|  |  2. Open browser Developer Tools (F12)                |   |
|  |  3. Go to Application -> Cookies -> claude.ai         |   |
|  |  4. Find the cookie named "sessionKey"                |   |
|  |  5. Copy the value                                    |   |
|  |                                                       |   |
|  |  Session ID                                           |   |
|  |  +---------------------------------------------------+|   |
|  |  | sk-ant-sid01-**************************          ||   |
|  |  +---------------------------------------------------+|   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  | Your session ID is stored locally and never           |   |
|  |    leaves your computer.                              |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                 [ Back ]          [ Continue ]              |
|                                                             |
+-------------------------------------------------------------+
```

**UI (API key selected):**
```
+-------------------------------------------------------------+
|                                                             |
|  Step 1 of 3                                                |
|                                                             |
|  Connect with API Key                                       |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  API Key                                              |   |
|  |  +---------------------------------------------------+|   |
|  |  | sk-ant-api03-**************************          ||   |
|  |  +---------------------------------------------------+|   |
|  |                                                       |   |
|  |  Don't have an API key?                               |   |
|  |  -> Get one at console.anthropic.com                  |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  | Your API key is stored locally and never              |   |
|  |    leaves your computer.                              |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                 [ Back ]          [ Continue ]              |
|                                                             |
+-------------------------------------------------------------+
```

**Validation:**
- Session ID format: validate structure, test with a ping to Claude
- API key format: starts with `sk-ant-`, test with minimal API request
- Show error if invalid: "Couldn't connect to Claude. Please check your credentials."

**Config set:**
```json
{
  "agents": {
    "defaults": {
      "model": "claude-sonnet-4-20250514"
    }
  }
}
```

**Credentials stored:** Added to `~/.bonsai/vault.age` (age-encrypted)
```json
{
  "anthropic": {
    "type": "session",
    "value": "sk-ant-sid01-...",
    "createdAt": "2026-02-04T..."
  }
}
```

**Next:** Click "Continue" -> Step 2

---

### Step 2: GitHub Token

**Purpose:** Get GitHub access for cloning repos and creating PRs

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|  Step 2 of 3                                                |
|                                                             |
|  Connect to GitHub                                          |
|                                                             |
|  Bonsai needs access to clone repos and create commits.     |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  Create a Personal Access Token:                      |   |
|  |                                                       |   |
|  |  1. Go to github.com/settings/tokens                  |   |
|  |  2. Click "Generate new token (classic)"              |   |
|  |  3. Give it a name like "Bonsai"                      |   |
|  |  4. Select the "repo" scope (full control)            |   |
|  |  5. Click "Generate token"                            |   |
|  |  6. Copy and paste it below                           |   |
|  |                                                       |   |
|  |  GitHub Token                                         |   |
|  |  +---------------------------------------------------+|   |
|  |  | ghp_*************************************        ||   |
|  |  +---------------------------------------------------+|   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  | Your token is stored locally and used only to         |   |
|  |    clone repos and create commits/PRs.                |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                 [ Back ]          [ Continue ]              |
|                                                             |
+-------------------------------------------------------------+
```

**Validation:**
- Token format: starts with `ghp_` or `github_pat_`
- Test with GitHub API: `GET /user`
- Show username on success: "Connected as @username"

**Credentials stored:** Added to `~/.bonsai/vault.age` (age-encrypted)
```json
{
  "github": {
    "type": "token",
    "value": "ghp_...",
    "createdAt": "2026-02-04T...",
    "metadata": { "username": "octocat" }
  }
}
```

**Background actions (while showing Step 2):**
Bonsai workspace setup happens silently in the background:

1. Create workspace directory: `~/.bonsai/`
2. Create `~/.bonsai/config.json` with defaults
3. Initialize SQLite database: `~/.bonsai/bonsai.db`
4. Generate age keypair for vault encryption

**Next:** Click "Continue" -> Step 3

---

### Step 3: Health Check & Success

**Purpose:** Verify everything works, install heartbeat service, celebrate, guide to first project

**UI (checking):**
```
+-------------------------------------------------------------+
|                                                             |
|  Step 3 of 3                                                |
|                                                             |
|  Setting up your workspace...                               |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  [check] Claude connected                             |   |
|  |  [check] GitHub connected (@username)                 |   |
|  |  [spin]  Creating workspace (~/.bonsai/)...           |   |
|  |  [ ]     Installing heartbeat service...              |   |
|  |  [ ]     Verifying setup                              |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  Everything runs on your computer.                          |
|  Your code and conversations stay private.                  |
|                                                             |
+-------------------------------------------------------------+
```

**UI (success):**
```
+-------------------------------------------------------------+
|                                                             |
|                    You're all set!                           |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  [check] Claude connected                             |   |
|  |  [check] GitHub connected (@username)                 |   |
|  |  [check] Workspace ready (~/.bonsai/)                 |   |
|  |  [check] Heartbeat service installed                  |   |
|  |  [check] Setup verified                               |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|     Bonsai is ready. Create your first project to          |
|     start building with AI.                                 |
|                                                             |
|                  [ Create First Project ]                   |
|                                                             |
|                    or go to Dashboard                       |
|                                                             |
+-------------------------------------------------------------+
```

**UI (failure):**
```
+-------------------------------------------------------------+
|                                                             |
|  Step 3 of 3                                                |
|                                                             |
|  Almost there...                                            |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  [check] Claude connected                             |   |
|  |  [check] GitHub connected (@username)                 |   |
|  |  [check] Workspace ready                              |   |
|  |  [fail]  Heartbeat service failed to install          |   |
|  |                                                       |   |
|  |  The heartbeat service could not be installed.        |   |
|  |                                                       |   |
|  |  Try:                                                 |   |
|  |  - Restarting your computer                           |   |
|  |  - Running: bonsai heartbeat install                  |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|              [ Retry ]          [ Get Help ]                |
|                                                             |
+-------------------------------------------------------------+
```

**Checks performed:**
1. Claude credentials valid (ping)
2. GitHub token valid (already verified in Step 2)
3. `~/.bonsai/` directory created with correct structure
4. Heartbeat service installed (launchd on macOS, systemd on Linux)

**Heartbeat service installation:**

On macOS, write a launchd plist:
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

On Linux, write a systemd timer + service:
```ini
# ~/.config/systemd/user/bonsai-heartbeat.service
[Unit]
Description=Bonsai Heartbeat

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bonsai heartbeat

# ~/.config/systemd/user/bonsai-heartbeat.timer
[Unit]
Description=Bonsai Heartbeat Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
```

See `13-agent-runtime.md` for full heartbeat implementation details.

**Actions:**
- Mark onboarding complete in Bonsai DB
- "Create First Project" -> New Project wizard
- "Dashboard" -> Main Bonsai dashboard (empty state)

---

## 3. New Project Setup (Detailed)

GitHub is already connected during first-run setup, so new project creation starts with repository selection.

### Step 1: Repository Selection

**Purpose:** Choose which repo to work with

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|  New Project -- Step 1 of 4                                 |
|                                                             |
|  Choose a Repository                                        |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  Search repositories...                               |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  Your Repositories                                    |   |
|  |  --------------------------------------------------- |   |
|  |  ( ) octocat/my-app              TypeScript    * 12   |   |
|  |  ( ) octocat/api-server          Python        * 5    |   |
|  |  ( ) octocat/landing-page        JavaScript    * 2    |   |
|  |  ( ) octocat/dotfiles            Shell         * 0    |   |
|  |                                                       |   |
|  |  [ Load more... ]                                     |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  --------------- or ---------------                        |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  Paste a repository URL:                              |   |
|  |  +---------------------------------------------------+|   |
|  |  | https://github.com/...                            ||   |
|  |  +---------------------------------------------------+|   |
|  +-----------------------------------------------------+   |
|                                                             |
|  --------------- or ---------------                        |
|                                                             |
|             [ + Create New Repository ]                     |
|                                                             |
|                 [ Back ]          [ Continue ]              |
|                                                             |
+-------------------------------------------------------------+
```

**Features:**
- List user's repos via GitHub API (sorted by recent push)
- Search/filter repos
- Paste URL for repos not in list
- Create new repo option

**Create New Repo flow (inline modal):**
```
+-------------------------------------------------------------+
|                                                             |
|  Create New Repository                                      |
|                                                             |
|  Name:        +---------------------------------------+     |
|               | my-new-project                        |     |
|               +---------------------------------------+     |
|                                                             |
|  Description: +---------------------------------------+     |
|               | A cool new project                    |     |
|               +---------------------------------------+     |
|                                                             |
|  Visibility:  (*) Private    ( ) Public                     |
|                                                             |
|  Initialize:  [x] Add README.md                             |
|               [x] Add .gitignore (Node)                     |
|                                                             |
|              [ Cancel ]          [ Create ]                 |
|                                                             |
+-------------------------------------------------------------+
```

**Next:** Select repo -> Click "Continue" -> Step 2

---

### Step 2: Project Configuration

**Purpose:** Review and customize project settings

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|  New Project -- Step 2 of 4                                 |
|                                                             |
|  Configure Project                                          |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  Repository:     octocat/my-app                       |   |
|  |  Language:       TypeScript (detected)                |   |
|  |  Default branch: main                                 |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  Project Name                                               |
|  +-----------------------------------------------------+   |
|  | My App                                               |   |
|  +-----------------------------------------------------+   |
|  This is how the project appears in Bonsai                 |
|                                                             |
|  AI Model                                                   |
|  +-----------------------------------------------------+   |
|  | Claude Sonnet 4 (Recommended)                    v   |   |
|  +-----------------------------------------------------+   |
|  Sonnet balances speed and capability. Use Opus for        |
|  complex architectural work.                                |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  > Advanced Options                                   |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                 [ Back ]          [ Continue ]              |
|                                                             |
+-------------------------------------------------------------+
```

**Advanced Options (collapsed by default):**
```
+-------------------------------------------------------------+
|  v Advanced Options                                         |
|                                                             |
|  Local Path                                                 |
|  +-----------------------------------------------------+   |
|  | ~/.bonsai/projects/my-app                            |   |
|  +-----------------------------------------------------+   |
|  Where to clone the repository                             |
|                                                             |
|  Agent ID                                                   |
|  +-----------------------------------------------------+   |
|  | my-app-dev                                           |   |
|  +-----------------------------------------------------+   |
|  Internal identifier (auto-generated from repo name)       |
|                                                             |
+-------------------------------------------------------------+
```

**Data collected:**
- `projectName`: Display name
- `model`: claude-sonnet-4-20250514 | claude-opus-4-5-20251101
- `localPath`: Where to clone (default: `~/.bonsai/projects/{repo-name}`)
- `agentId`: Bonsai agent ID (default: `{repo-name}-dev`)

**Next:** Click "Continue" -> Step 3

---

### Step 3: Clone & Analyze

**Purpose:** Clone repo, analyze structure, create project in SQLite

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|  New Project -- Step 3 of 4                                 |
|                                                             |
|  Setting up your project                                    |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  [check] Cloning repository...                        |   |
|  |  [check] Analyzing project structure...               |   |
|  |  [spin]  Creating project record...                   |   |
|  |  [ ]     Generating project context...                |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  Detected:                                            |   |
|  |  - Framework: Next.js 14                              |   |
|  |  - Package manager: pnpm                              |   |
|  |  - Test runner: Vitest                                |   |
|  |  - 47 source files                                    |   |
|  +-----------------------------------------------------+   |
|                                                             |
+-------------------------------------------------------------+
```

**Actions performed:**

1. **Clone repository:**
   ```bash
   git clone https://github.com/octocat/my-app ~/.bonsai/projects/my-app
   ```

2. **Analyze project:**
   - Detect language (package.json, requirements.txt, go.mod, etc.)
   - Detect framework (Next.js, Express, Django, etc.)
   - Detect package manager (npm, pnpm, yarn, pip, etc.)
   - Detect test runner (vitest, jest, pytest, etc.)
   - Count source files

3. **Create Bonsai project record in SQLite:**
   ```sql
   INSERT INTO projects (id, name, slug, github_repo, local_path, agent_id, model, ...)
   VALUES ('uuid', 'My App', 'my-app', 'octocat/my-app', '~/.bonsai/projects/my-app', 'my-app-dev', 'claude-sonnet-4-20250514', ...);
   ```

4. **Generate SOUL.md:**
   Write to `~/.bonsai/projects/my-app/SOUL.md`:
   ```markdown
   You are a developer working exclusively on the my-app repository.

   Repository: https://github.com/octocat/my-app
   Language: TypeScript
   Framework: Next.js 14
   Branch: main

   ## Rules
   - Only make changes within this repository
   - Follow the project's existing code style
   - Use pnpm for package management
   - Run tests with vitest before committing
   - Create focused, well-described commits
   - Communicate all questions and status updates via ticket comments
   ```

5. **Generate MEMORY.md:**
   Write to `~/.bonsai/projects/my-app/MEMORY.md`:
   ```markdown
   # Project Knowledge

   ## Structure
   - src/app/ - Next.js app router pages
   - src/components/ - React components
   - src/lib/ - Utility functions
   - ...

   ## Key Files
   - package.json - Dependencies and scripts
   - next.config.js - Next.js configuration
   - ...
   ```

6. **Create agent session directory:**
   ```
   ~/.bonsai/agents/my-app-dev/sessions/
   ```

**Next:** Auto-advance to Step 4 when complete

---

### Step 4: Success

**Purpose:** Celebrate, open project board

**UI:**
```
+-------------------------------------------------------------+
|                                                             |
|                    Project Created!                          |
|                                                             |
|     My App is ready to go.                                  |
|                                                             |
|     Your AI agent has analyzed the codebase and is          |
|     ready to help you build features, fix bugs,             |
|     and manage your project.                                |
|                                                             |
|                  [ Open Project Board ]                     |
|                                                             |
|                    or create another project                |
|                                                             |
+-------------------------------------------------------------+
```

**Actions:**
- "Open Project Board" -> Navigate to `/projects/{slug}/board`
- "create another project" -> Restart New Project wizard

---

## 4. Key Vault (Settings)

After onboarding, users can add additional API keys for other providers via a local encrypted key vault in Settings. This is **not** part of onboarding -- it's available anytime from the Settings page.

### 4.1 Purpose

- Store API keys for Gemini, OpenAI, OpenRouter, and other providers
- Enable switching models per-project (e.g., use Gemini for one project, Claude for another)
- Keep all secrets in one secure, local location

### 4.2 UI

**Settings -> Key Vault:**
```
+-------------------------------------------------------------+
|                                                             |
|  Settings > Key Vault                                       |
|                                                             |
|  API Keys & Credentials                                     |
|                                                             |
|  Store API keys for AI providers. All keys are encrypted   |
|  and stored locally on your machine.                        |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  Anthropic (Claude)                    Connected      |   |
|  |  Using: Max Session                    [ Edit ]       |   |
|  |  --------------------------------------------------- |   |
|  |                                                       |   |
|  |  GitHub                                Connected      |   |
|  |  @octocat                              [ Edit ]       |   |
|  |  --------------------------------------------------- |   |
|  |                                                       |   |
|  |  Google (Gemini)                       Not set        |   |
|  |                                        [ Add Key ]    |   |
|  |  --------------------------------------------------- |   |
|  |                                                       |   |
|  |  OpenAI                                Not set        |   |
|  |                                        [ Add Key ]    |   |
|  |  --------------------------------------------------- |   |
|  |                                                       |   |
|  |  OpenRouter                            Not set        |   |
|  |                                        [ Add Key ]    |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  > Custom Keys                                        |   |
|  +-----------------------------------------------------+   |
|                                                             |
+-------------------------------------------------------------+
```

**Add Key Modal:**
```
+-------------------------------------------------------------+
|                                                             |
|  Add Google (Gemini) API Key                          X     |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  API Key                                              |   |
|  |  +---------------------------------------------------+|   |
|  |  | AIza*************************************        ||   |
|  |  +---------------------------------------------------+|   |
|  |                                                       |   |
|  |  Get a key at aistudio.google.com                     |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|              [ Cancel ]          [ Save Key ]               |
|                                                             |
+-------------------------------------------------------------+
```

**Custom Keys (expanded):**
```
+-------------------------------------------------------------+
|  v Custom Keys                                              |
|                                                             |
|  Add any key-value pair for custom integrations.           |
|                                                             |
|  +-----------------------------------------------------+   |
|  |  REPLICATE_API_TOKEN          ********   [ Edit ]     |   |
|  |  PINECONE_API_KEY             ********   [ Edit ]     |   |
|  +-----------------------------------------------------+   |
|                                                             |
|                    [ + Add Custom Key ]                     |
|                                                             |
+-------------------------------------------------------------+
```

### 4.3 Encryption: age

We use **[age](https://github.com/FiloSottile/age)** -- a modern, audited file encryption tool. It's the standard for CLI encryption, audited by Cure53, and has native bindings for Node.js.

**Why age:**
- Battle-tested, audited by security professionals
- Simple API: encrypt/decrypt with one function call
- X25519 key exchange (Curve25519) + ChaCha20-Poly1305
- Passphrase mode uses scrypt for key derivation
- Single binary, no dependencies

### 4.4 Storage Architecture

```
~/.bonsai/
+-- vault.age              # Encrypted vault (age format)
+-- vault-key.txt          # age identity (private key), mode 0600
```

**First-run:** Generate an age keypair. The private key (`vault-key.txt`) stays on disk with strict permissions. The vault is encrypted to this key.

**No password required:** The private key on disk acts as the "password". If someone gets the key file, they can decrypt. This is the same model as SSH keys.

### 4.5 Vault Contents (Decrypted)

```json
{
  "version": 1,
  "entries": {
    "anthropic": {
      "type": "session",
      "value": "sk-ant-sid01-...",
      "createdAt": "2026-02-04T..."
    },
    "github": {
      "type": "token",
      "value": "ghp_...",
      "createdAt": "2026-02-04T...",
      "metadata": { "username": "octocat" }
    },
    "google": {
      "type": "api_key",
      "value": "AIza...",
      "createdAt": "2026-02-04T..."
    },
    "custom:REPLICATE_API_TOKEN": {
      "type": "custom",
      "value": "r8_...",
      "createdAt": "2026-02-04T..."
    }
  }
}
```

### 4.6 Implementation

**Dependencies:**
- `age-encryption` -- Node.js bindings for age (https://www.npmjs.com/package/age-encryption)

**Vault class:**
```typescript
import * as age from "age-encryption";
import * as fs from "fs/promises";
import * as path from "path";

const VAULT_PATH = path.join(process.env.HOME!, ".bonsai", "vault.age");
const KEY_PATH = path.join(process.env.HOME!, ".bonsai", "vault-key.txt");

interface VaultEntry {
  type: "session" | "api_key" | "token" | "custom";
  value: string;
  createdAt: string;
  metadata?: Record<string, unknown>;
}

interface VaultData {
  version: number;
  entries: Record<string, VaultEntry>;
}

class Vault {
  private identity: string | null = null;
  private recipient: string | null = null;

  async init(): Promise<void> {
    // Check if key exists
    try {
      const keyContent = await fs.readFile(KEY_PATH, "utf-8");
      this.identity = keyContent.trim();
      // Extract recipient (public key) from identity
      this.recipient = await this.getRecipient();
    } catch {
      // Generate new keypair
      const { privateKey, publicKey } = await age.generateIdentity();
      this.identity = privateKey;
      this.recipient = publicKey;

      // Save private key with strict permissions
      await fs.mkdir(path.dirname(KEY_PATH), { recursive: true, mode: 0o700 });
      await fs.writeFile(KEY_PATH, privateKey + "\n", { mode: 0o600 });

      // Create empty vault
      await this.save({ version: 1, entries: {} });
    }
  }

  async get(key: string): Promise<string | null> {
    const data = await this.load();
    return data.entries[key]?.value ?? null;
  }

  async set(key: string, value: string, type: VaultEntry["type"], metadata?: Record<string, unknown>): Promise<void> {
    const data = await this.load();

    data.entries[key] = {
      type,
      value,
      createdAt: new Date().toISOString(),
      metadata,
    };

    await this.save(data);
  }

  async delete(key: string): Promise<void> {
    const data = await this.load();
    delete data.entries[key];
    await this.save(data);
  }

  async list(): Promise<Array<{ key: string; type: string; createdAt: string }>> {
    const data = await this.load();
    return Object.entries(data.entries).map(([key, entry]) => ({
      key,
      type: entry.type,
      createdAt: entry.createdAt,
    }));
  }

  private async load(): Promise<VaultData> {
    try {
      const encrypted = await fs.readFile(VAULT_PATH);
      const decrypted = await age.decrypt(encrypted, [this.identity!]);
      return JSON.parse(decrypted.toString("utf-8"));
    } catch {
      return { version: 1, entries: {} };
    }
  }

  private async save(data: VaultData): Promise<void> {
    const plaintext = Buffer.from(JSON.stringify(data, null, 2));
    const encrypted = await age.encrypt(plaintext, [this.recipient!]);
    await fs.writeFile(VAULT_PATH, encrypted, { mode: 0o600 });
  }

  private async getRecipient(): Promise<string> {
    // age identity format: AGE-SECRET-KEY-1...
    // Corresponding recipient: age1...
    // Use age library to derive recipient from identity
    return age.identityToRecipient(this.identity!);
  }
}

// Singleton
let vault: Vault | null = null;

export async function getVault(): Promise<Vault> {
  if (!vault) {
    vault = new Vault();
    await vault.init();
  }
  return vault;
}
```

### 4.7 CLI Usage

For debugging or manual access, use the `age` CLI directly:

```bash
# Decrypt vault to stdout
age -d -i ~/.bonsai/vault-key.txt ~/.bonsai/vault.age

# Encrypt a new vault
echo '{"version":1,"entries":{}}' | age -r $(age-keygen -y ~/.bonsai/vault-key.txt) -o ~/.bonsai/vault.age
```

### 4.8 Security Properties

| Property | How It's Achieved |
|----------|-------------------|
| **Confidentiality** | X25519 + ChaCha20-Poly1305 |
| **Integrity** | Poly1305 MAC |
| **Key security** | Private key file with 0600 permissions |
| **Audited** | Cure53 audit of age |
| **No plaintext on disk** | All secrets in encrypted vault |

### 4.9 Optional: Password Protection

If users want an additional password layer (key file + password), use age's passphrase mode:

```typescript
// Encrypt with passphrase instead of key
const encrypted = await age.encryptWithPassphrase(plaintext, password);
const decrypted = await age.decryptWithPassphrase(encrypted, password);
```

This adds scrypt-based password protection on top. Trade-off: user must enter password on each app start.

### 4.10 Platform Keychain (Future)

For even better security, store the age private key in the system keychain:
- macOS: Keychain Access
- Linux: libsecret / GNOME Keyring
- Windows: Credential Manager

This protects the key file from being read by other processes. Implementation deferred to v2.

### 4.11 API Routes

```typescript
// GET /api/vault
// List all vault entries (keys redacted)
{
  "entries": [
    { "provider": "anthropic", "type": "session", "status": "connected" },
    { "provider": "github", "type": "token", "status": "connected", "username": "octocat" },
    { "provider": "google", "type": "api_key", "status": "not_set" },
    ...
  ]
}

// POST /api/vault/:provider
// Add or update a key
{ "key": "AIza...", "type": "api_key" }

// DELETE /api/vault/:provider
// Remove a key

// POST /api/vault/:provider/validate
// Test if key is valid
```

### 4.12 Using Keys in Projects

When creating or editing a project, users can select which model/provider to use:

```
+-------------------------------------------------------------+
|                                                             |
|  AI Model                                                   |
|  +-----------------------------------------------------+   |
|  | Claude Sonnet 4 (Recommended)                    v   |   |
|  +-----------------------------------------------------+   |
|  |-- Claude Sonnet 4 (Recommended)                       |
|  |-- Claude Opus 4.5                                     |
|  |-- Gemini 2.5 Pro               <- requires Gemini key|
|  |-- GPT-4o                       <- requires OpenAI key|
|  +-- + Add more providers in Settings                    |
|                                                             |
+-------------------------------------------------------------+
```

Providers without keys are shown grayed out with a link to Settings.

---

## 5. Next.js API Route Categories

Bonsai's web UI (Next.js) communicates with local system resources directly. There is no gateway proxy -- all system access is through API routes that read/write SQLite and the filesystem.

### 5.1 Architecture

```
+-------------------------------------------------------------+
|                         Browser                              |
|  +-------------------------------------------------------+  |
|  |                   Next.js Frontend                     |  |
|  |                   (React components)                   |  |
|  +-------------------------------------------------------+  |
|                            |                                 |
|                     fetch() requests                         |
|                            |                                 |
+----------------------------+---------------------------------+
                             |
                             v
+-------------------------------------------------------------+
|                    Bonsai Server (Local)                     |
|  +-------------------------------------------------------+  |
|  |              Next.js API Routes                        |  |
|  |              /api/projects/*                           |  |
|  |              /api/tickets/*                            |  |
|  |              /api/vault/*                              |  |
|  |              /api/git/*                                |  |
|  |              /api/fs/*                                 |  |
|  |              /api/heartbeat/*                          |  |
|  +-------------------------------------------------------+  |
|                            |                                 |
|              +-------------+-------------+                   |
|              |             |             |                   |
|              v             v             v                   |
|  +-----------+  +-----------+  +-----------+                 |
|  | Prisma    |  |    Git    |  | File      |                 |
|  | (SQLite)  |  |  (child_  |  | System    |                 |
|  |           |  |  process) |  | (fs/path) |                 |
|  +-----------+  +-----------+  +-----------+                 |
|                                                             |
+-------------------------------------------------------------+
```

### 5.2 Git Routes (`/api/git/*`)

Execute git commands via child_process.

```typescript
// /api/git/clone/route.ts
import { NextRequest, NextResponse } from "next/server";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

export async function POST(req: NextRequest) {
  const { repoUrl, targetPath } = await req.json();

  // Validate inputs
  if (!repoUrl.startsWith("https://github.com/")) {
    return NextResponse.json({ error: "Invalid repo URL" }, { status: 400 });
  }

  const { stdout, stderr } = await execAsync(
    `git clone ${repoUrl} ${targetPath}`,
    { timeout: 120000 }
  );

  return NextResponse.json({ success: true, stdout, stderr });
}
```

**Endpoints:**
- `POST /api/git/clone` -- Clone a repository
- `POST /api/git/status` -- Get git status
- `POST /api/git/commit` -- Create a commit
- `POST /api/git/push` -- Push to remote
- `POST /api/git/pull` -- Pull from remote

### 5.3 File System Routes (`/api/fs/*`)

Read/write files for config, SOUL.md, etc.

```typescript
// /api/fs/read/route.ts
import { NextRequest, NextResponse } from "next/server";
import fs from "fs/promises";
import path from "path";

const ALLOWED_ROOTS = [
  process.env.HOME + "/.bonsai",
  process.cwd() + "/projects",
];

/**
 * Validate that a path is within allowed roots.
 * Uses fs.realpath() to resolve symlinks BEFORE checking,
 * preventing symlink-based path traversal attacks.
 *
 * Also validates the root paths themselves via realpath
 * to handle symlinks in ALLOWED_ROOTS.
 */
async function validatePath(filePath: string): Promise<
  | { ok: true; realPath: string }
  | { ok: false; error: string }
> {
  // 1. Resolve logical path (handles ../ etc.)
  const resolved = path.resolve(filePath);

  // 2. Check if path exists, then resolve symlinks
  //    For new files (write/mkdir), resolve the parent directory
  let realPath: string;
  try {
    realPath = await fs.realpath(resolved);
  } catch {
    // File doesn't exist yet -- resolve parent dir instead
    const parentDir = path.dirname(resolved);
    try {
      const realParent = await fs.realpath(parentDir);
      realPath = path.join(realParent, path.basename(resolved));
    } catch {
      return { ok: false, error: "Parent directory does not exist" };
    }
  }

  // 3. Check against allowed roots (also realpath'd)
  for (const root of ALLOWED_ROOTS) {
    try {
      const realRoot = await fs.realpath(root);
      if (realPath.startsWith(realRoot + path.sep) || realPath === realRoot) {
        return { ok: true, realPath };
      }
    } catch {
      // Root doesn't exist yet -- skip
    }
  }

  return { ok: false, error: "Path not allowed" };
}

export async function POST(req: NextRequest) {
  const { filePath } = await req.json();

  const check = await validatePath(filePath);
  if (!check.ok) {
    return NextResponse.json({ error: check.error }, { status: 403 });
  }

  const content = await fs.readFile(check.realPath, "utf-8");
  return NextResponse.json({ content });
}
```

**Endpoints:**
- `POST /api/fs/read` -- Read file contents
- `POST /api/fs/write` -- Write file contents
- `POST /api/fs/exists` -- Check if path exists
- `POST /api/fs/mkdir` -- Create directory
- `POST /api/fs/list` -- List directory contents

### 5.4 Project Routes (`/api/projects/*`)

Bonsai-specific project management.

**Endpoints:**
- `GET /api/projects` -- List all projects
- `POST /api/projects` -- Create new project
- `GET /api/projects/[id]` -- Get project details
- `PATCH /api/projects/[id]` -- Update project
- `DELETE /api/projects/[id]` -- Delete project
- `POST /api/projects/[id]/analyze` -- Re-analyze project

### 5.5 Heartbeat Routes (`/api/heartbeat/*`)

Monitor and control the heartbeat service.

**Endpoints:**
- `GET /api/heartbeat/status` -- Check if heartbeat is running, last run time
- `POST /api/heartbeat/trigger` -- Manually trigger a heartbeat cycle
- `GET /api/heartbeat/logs` -- View recent heartbeat logs

### 5.6 Security Considerations

1. **Path validation:** All file system operations validate paths against allowlist
2. **Local only:** Server binds to localhost only (no external access)
3. **Token auth:** Web UI uses startup token authentication (see `12-technology-stack.md`)
4. **Input sanitization:** All user inputs validated before shell execution
5. **No arbitrary code:** Git/shell commands are predefined, not user-supplied

---

## 6. Config Keys Set by Onboarding

### First-Run Setup

Written to `~/.bonsai/config.json`:
```json
{
  "agents": {
    "defaults": {
      "model": "claude-sonnet-4-20250514",
      "workspace": "~/.bonsai/projects"
    }
  },
  "heartbeat": {
    "intervalSeconds": 60,
    "maxConcurrentAgents": "auto",
    "agentTimeoutMs": 1800000
  },
  "wizard": {
    "lastRunAt": "<timestamp>",
    "lastRunVersion": "<version>",
    "lastRunCommand": "bonsai-onboard"
  }
}
```

### Per-Project Setup

Project data is stored in SQLite (not in a config file). The `projects` table holds:
- `id`, `slug`, `name`
- `githubRepo`, `localPath`, `agentId`
- `model` (selected AI model)
- `createdAt`, `updatedAt`

Agent session data is stored on the filesystem:
```
~/.bonsai/agents/{agent-id}/sessions/
```

---

## 7. Files Created by Onboarding

### First-Run Setup

```
~/.bonsai/
+-- config.json            # Bonsai configuration
+-- bonsai.db              # SQLite database (projects, tickets, etc.)
+-- vault.age              # age-encrypted vault (all secrets)
+-- vault-key.txt          # age private key (mode 0600)
+-- logs/
|   +-- heartbeat.log      # Heartbeat stdout log
|   +-- heartbeat.err      # Heartbeat stderr log
+-- agents/                # Agent session data
+-- projects/              # Cloned repositories (default location)

# macOS:
~/Library/LaunchAgents/com.bonsai.heartbeat.plist

# Linux:
~/.config/systemd/user/bonsai-heartbeat.service
~/.config/systemd/user/bonsai-heartbeat.timer
```

### Per-Project Setup

```
~/.bonsai/projects/<repo-name>/     # Cloned repository
+-- .git/
+-- SOUL.md                         # Agent persona (created by Bonsai)
+-- MEMORY.md                       # Project knowledge (created by Bonsai)
+-- ... (repo contents)

~/.bonsai/agents/<repo-name>-dev/
+-- sessions/                       # Agent session history
```

---

## 8. Error Handling

### Common Errors and Recovery

| Error | Cause | Recovery |
|-------|-------|----------|
| Invalid API key | Wrong key or revoked | Show input again, link to Anthropic console |
| Heartbeat install failed | Permission issue | Show manual install command: `bonsai heartbeat install` |
| Clone failed | Private repo / no access | Check GitHub token permissions |
| Git not installed | Missing dependency | Show install instructions for platform |
| SQLite locked | Another process holding lock | Retry with backoff, or restart Bonsai |

### Error UI Pattern

```
+-------------------------------------------------------------+
|                                                             |
|  Something went wrong                                       |
|                                                             |
|  +-----------------------------------------------------+   |
|  |                                                       |   |
|  |  Couldn't install the heartbeat service.              |   |
|  |                                                       |   |
|  |  Error: Permission denied writing to LaunchAgents     |   |
|  |                                                       |   |
|  |  Try running manually:                                |   |
|  |  $ bonsai heartbeat install                           |   |
|  |                                                       |   |
|  +-----------------------------------------------------+   |
|                                                             |
|              [ Retry ]          [ Get Help ]                |
|                                                             |
+-------------------------------------------------------------+
```

---

## 9. What's NOT in Bonsai Onboarding

Compared to OpenClaw's TUI wizard (extraction origin), Bonsai **removes**:

| Removed | Reason |
|---------|--------|
| Plugin/skill selection | Bonsai picks defaults |
| Hooks configuration | Auto-enabled |
| Tailscale/advanced networking | v1 is local-only |
| Runtime selection (Node/Bun) | Node only |
| Multiple auth providers | Claude only for v1 |
| Channel setup (Discord, Slack, etc.) | Not applicable -- agents use ticket comments |
| Risk acknowledgement screen | Simplified UX (move to settings) |
| Quickstart vs Advanced choice | Always "quickstart" equivalent |
| Service runtime selection | Node only |
| DM policy configuration | Not applicable |
| Gateway setup / port config | No gateway -- heartbeat model instead |
| WebSocket RPC configuration | No WebSocket -- agents run in-process |
| openclaw.json creation | No openclaw.json -- Bonsai uses ~/.bonsai/config.json |
