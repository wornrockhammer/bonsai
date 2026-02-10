# Bonsai Design — Adversarial Review TODOs

Date: 2026-02-04

Issues identified during adversarial review of design documents 01-12.

---

## Critical

- [x] **Session Key Format Disagreement** (INCONSISTENCY) ✅ RESOLVED
  - Doc 02 vs Doc 03: Different session key formats shown
  - **Resolution:** OpenClaw uses hierarchical colon-separated keys: `agent:<agentId>:<rest>`. Custom suffixes supported. Bonsai canonical format: `agent:<worker>:bonsai:project:<projId>:ticket:<ticketId>`. Agent research completed — see session key research output. Docs need updating to use this canonical format.

- [x] **Persona File Injection Mechanism Undefined** (UNDEFINED) ✅ RESOLVED
  - **Resolution:** Two paths discovered: (A) place SOUL.md in agent workspace dir, OpenClaw reads it automatically via `loadWorkspaceBootstrapFiles()`, or (B) use `extraSystemPrompt` Gateway RPC parameter. Path B recommended — no filesystem manipulation needed. Doc 07 updated with section 3.9 documenting the mechanism.

- [x] **Concurrent Ticket Git Conflicts** (UNDEFINED) ✅ RESOLVED
  - **Resolution:** Two problems addressed in Doc 08 section 3.3:
    1. **Git operation contention** — Added per-project `GitOperationQueue` to serialize all git commands that touch shared `.git/` (fetch, commit, branch, rebase, gc, push). Worktree-local reads (status, diff) run unserialized.
    2. **Rebase-time merge conflicts** — Added pre-flight conflict detection, agent-assisted resolution flow, human-required fallback, and ticket state transitions for conflicts. Finalization serialized via `AsyncLock`.

- [x] **No Web UI Authentication** (SECURITY) ✅ RESOLVED
  - **Resolution:** Added "Security: Web UI Authentication" section to Doc 12. Startup token auth (Jupyter-style): random 32-byte hex token generated on first run, stored at `~/.bonsai/web-token` (mode 0600). Next.js middleware validates cookie/Bearer header/query param on all routes. Server binds to 127.0.0.1 only. v2 path includes passkey and multi-user support.

- [x] **Path Traversal in API Routes** (SECURITY) ✅ RESOLVED
  - **Resolution:** Replaced `path.resolve()` with `fs.realpath()` in Doc 05's validatePath function. Now resolves symlinks before checking against ALLOWED_ROOTS. Also realpath's the roots themselves. Handles non-existent files by resolving parent dir. Added path separator check to prevent prefix attacks (e.g., `/allowed-root-extra/` matching `/allowed-root/`).

---

## High

- [x] **Persona File Location Inconsistency** (INCONSISTENCY) ✅ RESOLVED
  - **Resolution:** Source of truth is `~/.bonsai/personas/`. These are NOT copied to workspace. Instead, persona content is injected via `extraSystemPrompt` Gateway RPC parameter (see Doc 07, section 3.9). Workspace SOUL.md is OpenClaw's native mechanism; Bonsai bypasses it.

- [x] **Database File Location Inconsistency** (INCONSISTENCY) ✅ RESOLVED
  - **Resolution:** Canonical location is `~/.bonsai/bonsai.db`. Updated Doc 12 datasource URL and directory listing to match Docs 05/07.

- [x] **Project Manager Scheduling Details Missing** (UNDEFINED) ✅ RESOLVED
  - **Resolution:** "auto" concurrency = delegate to OpenClaw's lane system (it handles rate limits per auth provider). Bonsai's scheduler only owns the dispatch queue: priority by board position/age/urgency flags, dispatch to gateway, track running vs waiting. Wake conditions: ticket state change, human comment, timer. Doc 06 needs update to reflect this delegation model.

- [x] **Session Cookie Expiration Handling** (EDGE_CASE) ✅ RESOLVED
  - **Resolution:** Bonsai doesn't manage auth — OpenClaw handles cookie validity. If a run fails with auth error, Bonsai marks ticket as blocked, surfaces in UI. User re-authenticates through OpenClaw's existing flow.

- [x] **Gateway Restart During Agent Work** (FAILURE_MODE) ✅ RESOLVED
  - **Resolution:** Bonsai's persistent job manifest tracks dispatched work. On startup, check for runs that were "in_progress" but never completed — re-dispatch. Idempotency keys prevent duplicate work. Agent picks up new session or starts over.

- [x] **Vault Key Recovery** (FAILURE_MODE) ✅ RESOLVED
  - **Resolution:** Document that users should back up `~/.bonsai/vault-key.txt`. v2: derive from passphrase instead of random bytes (regeneratable). v1: document the risk and backup procedure.

- [x] **SQLite Concurrent Access** (FAILURE_MODE) ✅ RESOLVED
  - **Resolution:** Enable WAL mode in Prisma datasource. SQLite WAL handles concurrent readers + one writer. Bonsai services are all local, low-throughput — WAL is sufficient.

- [x] **Tight Coupling to OpenClaw Internals** (ARCHITECTURE) ✅ RESOLVED
  - **Resolution:** Agent extraction research completed — see AGENT_EXTRACT_TODO.md. Catalogs all coupling points, clean extraction surfaces, and recommended abstraction strategy (wrapper + config injection).

---

## Medium

- [ ] **GitHub Token Permission Failures** (ASSUMPTION)
  - Only "repo" scope mentioned
  - Fine-grained PATs, SSO, org restrictions not handled
  - **Action:** Validate permissions at onboarding, provide clear error messages

- [ ] **Single Machine Assumption** (ASSUMPTION)
  - No multi-device sync story
  - **Action:** Document limitation or plan cloud sync

- [x] **Auto Concurrency Detection Undefined** (COMPLEXITY) ✅ RESOLVED
  - **Resolution:** Concurrency bounded by API rate limits + local resources (RAM, Docker containers). Bonsai's scheduler dispatches work; concurrency limit is configurable with sensible default. No "auto" detection — explicit setting.

- [ ] **No Offline/Degraded Mode** (ARCHITECTURE)
  - Requires internet for Claude API
  - No local caching or offline editing
  - **Action:** Document limitation, consider offline ticket editing

- [ ] **Worktree Already Exists** (EDGE_CASE)
  - `createTicketWorktree()` doesn't check for existing worktree
  - **Action:** Add existence check before `git worktree add`

- [ ] **Vault Key File Permission Race** (SECURITY)
  - File created then chmod'd (brief exposure window)
  - **Action:** Create with atomic permissions or in protected directory

- [ ] **No Log Rotation** (OPERATIONS)
  - `~/.bonsai/logs/` accumulates indefinitely
  - **Action:** Add log rotation (logrotate config or built-in)

- [ ] **No Backup/Export Strategy** (OPERATIONS)
  - No documented backup procedure
  - Vault key gitignored but critical
  - **Action:** Document backup/migration procedure

- [ ] **Worktree Disk Usage** (SCALABILITY)
  - 20 worktrees on 2GB repo = 40GB+ disk
  - **Action:** Document disk requirements, add cleanup on ticket idle

- [ ] **Ticket Rejection UX** (UX)
  - No flow for providing feedback on rejected work
  - **Action:** Design revision/feedback flow

- [ ] **Session ID Instructions Browser-Specific** (UX)
  - F12 → Application → Cookies varies by browser
  - Non-technical users may struggle
  - **Action:** Add browser-specific instructions or simplification

- [ ] **No Agent Progress Visibility** (UX)
  - Cards show "Active" but not what agent is doing
  - **Action:** Add progress indicators, thought stream, or activity log

- [ ] **Role Permission Conflict Resolution** (UNDEFINED)
  - Same tool in allow and deny from different roles
  - Order-dependent resolution unclear
  - **Action:** Document explicit precedence rules

- [ ] **Research → Ready Transition Criteria** (UNDEFINED)
  - "Approved" undefined (human? PM? status change?)
  - **Action:** Define approval mechanism

---

## Low

- [ ] **Git Version Requirement** (COMPLEXITY)
  - Worktrees require modern git
  - Minimum version not validated
  - **Action:** Add git version check at onboarding

- [ ] **SQLite Scale Limits** (SCALABILITY)
  - Single DB for all projects/tickets
  - 50+ projects may degrade performance
  - **Action:** Add indexes, document scale limits

- [ ] **Persona Profile Picture Generation** (UNDEFINED)
  - `generatedWith: "stable-diffusion"` mentioned but not specified
  - **Action:** Document generation process or remove reference

- [ ] **Port 18789 Availability** (ASSUMPTION)
  - Port finding mentioned but not implemented in shown code
  - **Action:** Implement port-finding, communicate chosen port to web app

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 5 |
| High | 8 |
| Medium | 14 |
| Low | 4 |
| **Total** | **31** |
