# Bonsai Roles and Permissions Architecture

Date: 2026-02-04

## Summary

Bonsai's permission system builds on OpenClaw's tool policies while adding a human-readable **Resource:Action** format. Users can attach roles to personas, granting them specific capabilities like `Email:Read`, `GitHub:Write`, or `Exec:Full`. This document covers how Bonsai's roles map to OpenClaw's underlying tool system.

**Key principle:** Bonsai roles are a UI layer over OpenClaw's tool policies. They translate human-readable permissions into OpenClaw's `allow`/`deny`/`profile` configuration.

---

## OpenClaw's Permission Model (Foundation)

### Tool Profiles

OpenClaw provides four built-in tool profiles that serve as permission templates:

| Profile | Tools Allowed | Use Case |
|---------|---------------|----------|
| `minimal` | `session_status` only | Restricted agent |
| `coding` | `group:fs`, `group:runtime`, `group:sessions`, `group:memory`, `image` | Developer work |
| `messaging` | `group:messaging`, session tools | Communication-focused |
| `full` | Everything (no restrictions) | Unrestricted agent |

**Key file:** `src/agents/tool-policy.ts:59-76`

### Tool Groups

OpenClaw organizes tools into logical groups:

```typescript
TOOL_GROUPS = {
  "group:memory": ["memory_search", "memory_get"],
  "group:web": ["web_search", "web_fetch"],
  "group:fs": ["read", "write", "edit", "apply_patch"],
  "group:runtime": ["exec", "process"],
  "group:sessions": ["sessions_list", "sessions_history", "sessions_send", "sessions_spawn", "session_status"],
  "group:ui": ["browser", "canvas"],
  "group:automation": ["cron", "gateway"],
  "group:messaging": ["message"],
  "group:nodes": ["nodes"],
  "group:openclaw": [/* all native OpenClaw tools */],
  "group:plugins": [/* dynamically populated from plugins */],
}
```

**Key file:** `src/agents/tool-policy.ts:13-57`

### Allow/Deny Configuration

OpenClaw's `AgentToolsConfig` supports:

```typescript
type AgentToolsConfig = {
  profile?: "minimal" | "coding" | "messaging" | "full";
  allow?: string[];          // Explicit allowlist
  alsoAllow?: string[];      // Additive (merges with profile)
  deny?: string[];           // Blocklist (always wins)
  byProvider?: Record<string, ToolPolicyConfig>;  // Per-model overrides
  elevated?: { enabled?: boolean; allowFrom?: {...} };
  exec?: ExecToolConfig;
  sandbox?: { tools?: { allow?: string[]; deny?: string[] } };
};
```

**Key file:** `src/config/types.tools.ts:198-222`

### Skills

OpenClaw skills are separately managed:

```typescript
type SkillsConfig = {
  allowBundled?: string[];              // Bundled skill allowlist
  entries?: Record<string, SkillConfig>; // Per-skill settings
  load?: { extraDirs?: string[]; watch?: boolean };
  install?: { preferBrew?: boolean; nodeManager?: "npm" | "pnpm" | "yarn" | "bun" };
};
```

**Key file:** `src/config/types.skills.ts:25-31`

---

## Bonsai's Role System

### Design Philosophy

Bonsai translates human-readable **Resource:Action** permissions into OpenClaw's tool configuration. This provides:

1. **Clarity** — Users understand "Email:Read" better than "tools.allow: ['message']"
2. **Safety** — Roles are pre-defined with sensible defaults
3. **Flexibility** — Custom roles can map to any tool combination

### Permission Format

Bonsai permissions follow the format:

```
{Resource}:{Action}
```

Examples:
- `Email:Read` — Can read emails but not send
- `GitHub:Write` — Can push commits, create PRs
- `Files:Full` — Full filesystem access
- `Exec:Elevated` — Can run privileged commands
- `Memory:Search` — Can search agent memory

### Built-in Roles

Bonsai provides pre-configured roles that map to common use cases:

| Role Name | Description | OpenClaw Mapping |
|-----------|-------------|------------------|
| `Developer` | Full coding capabilities | `profile: "coding"` |
| `Reviewer` | Read-only code review | `profile: "coding"`, `deny: ["write", "edit", "exec"]` |
| `Researcher` | Web and memory search | `allow: ["group:web", "group:memory"]` |
| `Messenger` | Communication-focused | `profile: "messaging"` |
| `Observer` | Status only, no actions | `profile: "minimal"` |
| `Admin` | Full access | `profile: "full"` |

### Resource Categories

Bonsai organizes permissions into resource categories:

#### Files
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Files:Read` | Read files | `read` |
| `Files:Write` | Create/modify files | `read`, `write`, `edit`, `apply_patch` |
| `Files:Full` | All file operations | `group:fs` |

#### Exec (Runtime)
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Exec:Sandbox` | Sandboxed execution | `exec` (with `exec.host: "sandbox"`) |
| `Exec:Gateway` | Gateway host execution | `exec` (with `exec.host: "gateway"`) |
| `Exec:Elevated` | Elevated permissions | `exec` + `elevated.enabled: true` |
| `Exec:Full` | All runtime tools | `group:runtime` |

#### Web
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Web:Search` | Web search | `web_search` |
| `Web:Fetch` | Fetch URLs | `web_fetch` |
| `Web:Full` | All web tools | `group:web` |

#### Memory
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Memory:Search` | Search memory | `memory_search` |
| `Memory:Get` | Get specific memories | `memory_get` |
| `Memory:Full` | All memory operations | `group:memory` |

#### Sessions
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Sessions:View` | View sessions | `sessions_list`, `sessions_history`, `session_status` |
| `Sessions:Send` | Send to sessions | `sessions_send` |
| `Sessions:Spawn` | Create sessions | `sessions_spawn` |
| `Sessions:Full` | All session operations | `group:sessions` |

#### Messaging
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Message:Read` | Receive messages | (passive, no tool) |
| `Message:Send` | Send messages | `message` |
| `Message:Broadcast` | Broadcast messages | `message` + `tools.message.broadcast.enabled` |
| `Message:Full` | All messaging | `group:messaging` |

#### UI
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Browser:Use` | Browser automation | `browser` |
| `Canvas:Use` | Canvas/drawing | `canvas` |
| `UI:Full` | All UI tools | `group:ui` |

#### Automation
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Cron:Schedule` | Schedule tasks | `cron` |
| `Gateway:Access` | Gateway operations | `gateway` |
| `Automation:Full` | All automation | `group:automation` |

#### Agents
| Permission | Description | OpenClaw Tools |
|------------|-------------|----------------|
| `Agents:List` | List agents | `agents_list` |
| `Agents:Spawn` | Spawn sub-agents | `tools.subagents.*` |
| `Agents:Full` | Full agent control | `agents_list` + subagent config |

---

## Integration with Plugins

### Plugin Tool Permissions

Plugins register tools dynamically. Bonsai exposes plugin permissions using the plugin ID:

```
{PluginId}:{Action}
```

Examples:
- `NanoBanana:Read` — Read from NanoBanana service
- `NanoBanana:Write` — Write to NanoBanana service
- `Voice:Call` — Make voice calls (voice-call plugin)
- `Matrix:Send` — Send to Matrix channels

### Plugin Permission Mapping

When a plugin registers tools, Bonsai creates permission entries:

```typescript
// Plugin registers tools
api.registerTool(nanaBananaReadTool);
api.registerTool(nanaBananaWriteTool);

// Bonsai creates permissions
permissions = {
  "NanoBanana:Read": { allow: ["nanabanana_read"] },
  "NanoBanana:Write": { allow: ["nanabanana_read", "nanabanana_write"] },
  "NanoBanana:Full": { allow: ["nanabanana"] }, // group:nanabanana
}
```

---

## Skills Integration

### Skill Permissions

Skills are a separate concept from tools. Bonsai exposes skill permissions:

```
Skill:{SkillName}
```

Examples:
- `Skill:commit` — Can use /commit skill
- `Skill:code-review` — Can use code review skill
- `Skill:frontend-design` — Can use frontend design skill

### Skill Permission Mapping

```typescript
permissions = {
  "Skill:commit": {
    skills: { entries: { "commit": { enabled: true } } }
  },
  "Skill:All": {
    skills: { allowBundled: ["*"] }
  },
}
```

---

## Attaching Roles to Personas

### In settings.json

Each persona has a `settings.json` that includes role assignments:

```json
{
  "roles": ["Developer", "GitHub:Write", "Skill:commit"],
  "tools": {
    "profile": "coding",
    "alsoAllow": ["github_pr", "github_issue"],
    "deny": []
  }
}
```

### Role Resolution

When Bonsai runs a persona, it resolves roles to OpenClaw config:

```typescript
function resolveRoles(roles: string[]): AgentToolsConfig {
  const config: AgentToolsConfig = {
    allow: [],
    deny: [],
  };

  for (const role of roles) {
    const resolved = ROLE_REGISTRY[role];
    if (resolved.profile) config.profile = resolved.profile;
    if (resolved.allow) config.allow.push(...resolved.allow);
    if (resolved.deny) config.deny.push(...resolved.deny);
  }

  // Deny always wins
  config.allow = config.allow.filter(t => !config.deny.includes(t));

  return config;
}
```

### Inheritance and Precedence

Role resolution follows these rules:

1. **Base profile** — If any role specifies a profile, use the most permissive
2. **Allow accumulates** — All `allow` entries are merged
3. **Deny wins** — Any `deny` entry blocks the tool regardless of `allow`
4. **Explicit overrides roles** — `settings.json` `tools` config overrides role defaults

---

## Permission Schema

### Role Definition

Roles are defined in `~/.bonsai/roles/`:

```
~/.bonsai/roles/
├── developer.json
├── reviewer.json
├── researcher.json
└── custom/
    └── my-role.json
```

### Role JSON Schema

```json
{
  "id": "developer",
  "name": "Developer",
  "description": "Full coding capabilities with file and exec access",
  "permissions": [
    "Files:Full",
    "Exec:Sandbox",
    "Memory:Full",
    "Sessions:Full",
    "Web:Full"
  ],
  "tools": {
    "profile": "coding"
  },
  "skills": {
    "entries": {
      "commit": { "enabled": true },
      "code-review": { "enabled": true }
    }
  }
}
```

### Permission JSON Schema

```json
{
  "id": "GitHub:Write",
  "resource": "GitHub",
  "action": "Write",
  "description": "Push commits, create PRs and issues",
  "tools": {
    "alsoAllow": ["github_pr", "github_issue", "github_push"]
  },
  "requires": ["Files:Read", "Exec:Sandbox"]
}
```

---

## UI Representation

### Role Assignment Interface

The Bonsai web UI provides a role assignment interface:

```
┌─────────────────────────────────────────────────────────────┐
│  Devon (Developer Persona)                                   │
├─────────────────────────────────────────────────────────────┤
│  Assigned Roles                                              │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐            │
│  │ Developer ✕ │ │ GitHub:Write│ │ Skill:commit│            │
│  └─────────────┘ └─────────────┘ └─────────────┘            │
│                                                              │
│  Available Roles                                             │
│  ○ Reviewer      ○ Researcher    ○ Messenger                │
│  ○ Observer      ○ Admin                                     │
│                                                              │
│  Quick Permissions                                           │
│  ☑ Files:Full    ☑ Exec:Sandbox  ☐ Exec:Elevated            │
│  ☑ Web:Full      ☑ Memory:Full   ☐ Browser:Use              │
│                                                              │
│  [ + Add Custom Permission ]                                 │
└─────────────────────────────────────────────────────────────┘
```

### Permission Viewer

```
┌─────────────────────────────────────────────────────────────┐
│  Effective Permissions                                       │
├─────────────────────────────────────────────────────────────┤
│  Files                                                       │
│  ├── read        ✓ (from Developer role)                    │
│  ├── write       ✓ (from Developer role)                    │
│  ├── edit        ✓ (from Developer role)                    │
│  └── apply_patch ✓ (from Developer role)                    │
│                                                              │
│  Runtime                                                     │
│  ├── exec        ✓ (sandbox only)                           │
│  └── process     ✓ (from Developer role)                    │
│                                                              │
│  Web                                                         │
│  ├── web_search  ✓ (from Developer role)                    │
│  └── web_fetch   ✓ (from Developer role)                    │
│                                                              │
│  Denied                                                      │
│  └── elevated    ✗ (not assigned)                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Runtime Flow

### Permission Check Sequence

```
1. User assigns roles to persona in Bonsai UI
2. Bonsai writes settings.json with role list
3. At ticket execution time:
   a. Bonsai loads persona's settings.json
   b. Resolves all roles to tool config
   c. Merges with persona's explicit tools overrides
   d. Injects final config via Gateway RPC message parameter
4. OpenClaw enforces tool policies during agent execution
5. Plugin hooks (before_tool_call) can further gate access
```

### Gateway RPC Integration

When Bonsai runs agent work, it passes resolved permissions:

```typescript
await gateway.agent({
  agentId: "default",
  sessionKey: `agent:default:bonsai:${projectId}:ticket:${ticketId}`,
  message: ticketContext,
  // Injected from resolved roles
  tools: {
    profile: "coding",
    allow: ["github_pr", "github_issue"],
    deny: [],
  },
  skills: {
    entries: {
      "commit": { enabled: true },
    },
  },
});
```

---

## Security Considerations

### Principle of Least Privilege

Bonsai encourages minimal permissions:

1. **Start with Observer** — New personas start with minimal access
2. **Add roles incrementally** — Users explicitly grant capabilities
3. **Deny always wins** — Explicit denials cannot be overridden

### Elevated Access

`Exec:Elevated` is treated specially:

- Requires explicit user confirmation in UI
- Shown with warning indicator
- Logged separately for audit
- Maps to OpenClaw's `elevated.enabled: true`

### Audit Trail

Bonsai logs all permission-relevant events:

```json
{
  "timestamp": "2026-02-04T15:30:00Z",
  "event": "permission_granted",
  "persona": "devon",
  "role": "GitHub:Write",
  "grantedBy": "user",
  "project": "frontend-app"
}
```

---

## Cryptographic Identity & Credential Verification

Bonsai uses **Ed25519 signing** to cryptographically verify the connection between personas, projects, and roles. This prevents impersonation and ensures role assignments are tamper-proof.

### Why Cryptographic Verification

1. **Agent Isolation** — Each persona has its own cryptographic identity
2. **Non-Repudiation** — Only the persona's private key can sign its credentials
3. **Tamper Detection** — Modified role assignments fail verification
4. **Tracking** — Know exactly which persona is authorized for which project/task

### Persona Identity

Each persona has an Ed25519 keypair generated at creation:

```
~/.bonsai/personas/{persona-name}/
├── SOUL.md
├── settings.json
├── identity.json           # Ed25519 keypair
└── credentials/
    ├── project-myapp.cred  # Signed project assignment
    └── role-developer.cred # Signed role grant
```

**identity.json:**
```json
{
  "personaId": "a1b2c3d4...",  // SHA-256 fingerprint of public key
  "publicKeyPem": "-----BEGIN PUBLIC KEY-----\n...",
  "privateKeyPem": "-----BEGIN PRIVATE KEY-----\n...",
  "createdAt": "2026-02-04T10:00:00Z"
}
```

The `personaId` is derived from the public key fingerprint, providing a stable identifier that can be verified cryptographically.

### Signed Credentials

Credentials are JSON documents signed with the persona's private key:

```typescript
interface PersonaCredential {
  version: 1;
  type: "project-assignment" | "role-grant" | "capability";
  personaId: string;        // SHA-256 fingerprint of public key
  subject: {
    projectId?: string;     // For project assignments
    role?: string;          // For role grants
    capabilities?: string[]; // Fine-grained permissions
  };
  issuedAt: number;         // Unix timestamp (ms)
  expiresAt?: number;       // Optional expiration
  issuer: {
    type: "self" | "admin" | "project-owner";
    id: string;
  };
  nonce: string;            // Random value for uniqueness
}

interface SignedCredential {
  credential: PersonaCredential;
  signature: string;        // Base64URL-encoded Ed25519 signature
  signerPublicKey: string;  // Base64URL-encoded public key
}
```

### Credential Types

| Type | Purpose | Example |
|------|---------|---------|
| `project-assignment` | Authorizes persona to work on a project | `{ projectId: "frontend-app" }` |
| `role-grant` | Grants role with capabilities | `{ role: "developer", capabilities: ["Files:Full", "Exec:Sandbox"] }` |
| `capability` | Single permission grant | `{ capabilities: ["GitHub:Write"] }` |

### Verification Flow

```
1. User assigns persona to project in Bonsai UI
2. Bonsai creates signed project-assignment credential
3. User assigns roles to persona
4. Bonsai creates signed role-grant credentials
5. At ticket execution time:
   a. Bonsai loads persona's credentials
   b. Verifies signature on project-assignment
   c. Verifies signature on role-grants
   d. If all valid, resolves roles to OpenClaw config
   e. Injects verified config via Gateway RPC
6. If verification fails:
   a. Persona cannot work on project
   b. Clear error: "Credential verification failed: {reason}"
```

### Signing and Verification

```typescript
import crypto from "node:crypto";

// Sign a credential
function signCredential(
  credential: PersonaCredential,
  privateKeyPem: string,
  publicKeyPem: string
): SignedCredential {
  const payload = JSON.stringify(credential);
  const key = crypto.createPrivateKey(privateKeyPem);
  const sig = crypto.sign(null, Buffer.from(payload, "utf8"), key);

  return {
    credential,
    signature: base64UrlEncode(sig),
    signerPublicKey: extractRawPublicKey(publicKeyPem),
  };
}

// Verify a credential
function verifyCredential(signed: SignedCredential): {
  valid: boolean;
  error?: string;
} {
  // Reconstruct public key
  const key = crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, base64UrlDecode(signed.signerPublicKey)]),
    type: "spki",
    format: "der",
  });

  // Verify signature
  const payload = JSON.stringify(signed.credential);
  const sig = base64UrlDecode(signed.signature);
  const valid = crypto.verify(null, Buffer.from(payload, "utf8"), key, sig);

  if (!valid) return { valid: false, error: "Invalid signature" };

  // Verify persona ID matches signer
  const signerFingerprint = sha256(base64UrlDecode(signed.signerPublicKey));
  if (signerFingerprint !== signed.credential.personaId) {
    return { valid: false, error: "Signer does not match credential persona" };
  }

  // Check expiration
  if (signed.credential.expiresAt && Date.now() > signed.credential.expiresAt) {
    return { valid: false, error: "Credential expired" };
  }

  return { valid: true };
}
```

### Project Assignment Verification

```typescript
function verifyProjectAccess(
  credential: SignedCredential,
  expectedPersonaId: string,
  expectedProjectId: string
): { authorized: boolean; reason?: string } {
  const verification = verifyCredential(credential);
  if (!verification.valid) {
    return { authorized: false, reason: verification.error };
  }

  if (credential.credential.type !== "project-assignment") {
    return { authorized: false, reason: "Wrong credential type" };
  }

  if (credential.credential.personaId !== expectedPersonaId) {
    return { authorized: false, reason: "Persona ID mismatch" };
  }

  if (credential.credential.subject.projectId !== expectedProjectId) {
    return { authorized: false, reason: "Project ID mismatch" };
  }

  return { authorized: true };
}
```

### Role Capability Verification

```typescript
function verifyRoleCapability(
  credential: SignedCredential,
  expectedPersonaId: string,
  requiredCapability: string
): { authorized: boolean; reason?: string } {
  const verification = verifyCredential(credential);
  if (!verification.valid) {
    return { authorized: false, reason: verification.error };
  }

  if (credential.credential.type !== "role-grant") {
    return { authorized: false, reason: "Wrong credential type" };
  }

  const capabilities = credential.credential.subject.capabilities || [];
  if (!capabilities.includes(requiredCapability) && !capabilities.includes("*")) {
    return { authorized: false, reason: `Missing capability: ${requiredCapability}` };
  }

  return { authorized: true };
}
```

### Trust Boundary

**Bonsai handles all verification** — OpenClaw is not aware of credentials.

- Bonsai verifies credentials before invoking OpenClaw
- OpenClaw receives already-authorized requests
- Clean separation of concerns
- If defense-in-depth is needed later, OpenClaw verification can be added

### Attacks Prevented

| Attack | Prevention |
|--------|------------|
| Impersonation | Only persona's private key can sign valid credentials |
| Tampering | Any modification invalidates the signature |
| Replay | Timestamps + nonces prevent reuse |
| Escalation | Role-grant credentials list explicit capabilities |
| Cross-project access | Project-assignment tied to specific project ID |

### Future: DID/VC Compatibility

The design is compatible with W3C Verifiable Credentials:

- **personaId → did:key** — SHA-256 fingerprint can map to `did:key:z6Mk...`
- **SignedCredential → VC** — Structure maps to W3C VC format
- **Gradual adoption** — Start local, add DID resolution later if needed

---

## Key Code References

| Area | OpenClaw File | Reference |
|------|---------------|-----------|
| Tool profiles | `src/agents/tool-policy.ts` | Lines 1-76 |
| Tool groups | `src/agents/tool-policy.ts` | Lines 13-57 |
| Tool expansion | `src/agents/tool-policy.ts` | `expandToolGroups()` |
| Agent tools config | `src/config/types.tools.ts` | Lines 198-222 |
| Skills config | `src/config/types.skills.ts` | Full file |
| Plugin tool registration | `src/plugins/types.ts` | `registerTool` at line 245-248 |
| Plugin hooks (tool gate) | `src/plugins/types.ts` | `before_tool_call` lines 387-396 |
| Auth profiles | `src/agents/auth-profiles/types.ts` | Full file |

---

## Summary

Bonsai's role and permission system provides:

1. **Human-readable format** — `Resource:Action` instead of tool arrays
2. **Pre-built roles** — Developer, Reviewer, Researcher, etc.
3. **Plugin integration** — `PluginId:Action` for plugin tools
4. **Skill permissions** — `Skill:name` for skill access
5. **UI for assignment** — Visual role/permission management
6. **OpenClaw mapping** — Translates to `profile`, `allow`, `deny`, `skills`

The system decorates OpenClaw without modifying it — roles resolve to standard tool configuration at runtime.
