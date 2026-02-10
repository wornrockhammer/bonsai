# Bonsai

AI agent orchestration platform with three-phase ticket lifecycle automation.

## Repository Structure

This is a monorepo with three main packages:

- **`webapp/`** — Next.js 16 web application (primary codebase)
- **`agent/`** — Standalone TypeScript agent runtime package (`@bonsai/agent`)
- **`docs/`** — Architecture and design documentation

## Heartbeat Automation

The Bonsai heartbeat runs every 60 seconds to dispatch agent work across projects.

### Installation

1. Build and link the agent package:
   ```bash
   cd agent
   npm install
   npm run build
   npm link
   ```

2. Run the installer:
   ```bash
   cd install
   ./install.sh
   ```

This installs a system scheduler (launchd on macOS, cron on Linux) that runs `bonsai-heartbeat` every minute.

### Manual Invocation

```bash
bonsai-heartbeat               # Run once
bonsai-heartbeat --limit 5     # Dispatch up to 5 tickets per phase
bonsai-heartbeat --env dev     # Use development database
bonsai-heartbeat --help        # Show usage
```

### Monitoring

**macOS:**
```bash
# Check if running
launchctl list | grep bonsai

# View logs
tail -f ~/.bonsai/logs/launchd.out
tail -f ~/.bonsai/logs/launchd.err
```

**Linux:**
```bash
# Check cron entry
crontab -l | grep bonsai

# View logs
tail -f ~/.bonsai/logs/cron.log
```

### Troubleshooting

**Heartbeat not running:**
- Verify Claude CLI installed: `~/.local/bin/claude --version`
- Check lock file: `ls -la ~/.bonsai/heartbeat.lock` (should not persist)
- Review logs for errors

**Stale lock file:**
If heartbeat crashed, remove manually:
```bash
rm ~/.bonsai/heartbeat.lock
```

**Uninstall:**
```bash
cd install
./uninstall.sh
```

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and commands.
