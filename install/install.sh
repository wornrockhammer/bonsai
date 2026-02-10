#!/bin/bash
set -e

echo "Bonsai Heartbeat Installer"
echo "==========================="

# Detect platform
PLATFORM=$(uname -s)
USER=$(whoami)
HOME=$(eval echo ~$USER)

# Find Node.js
NODE_PATH=$(which node)
if [ -z "$NODE_PATH" ]; then
  echo "Error: Node.js not found in PATH"
  exit 1
fi

# Find heartbeat binary
HEARTBEAT_PATH=$(which bonsai-heartbeat)
if [ -z "$HEARTBEAT_PATH" ]; then
  echo "Error: bonsai-heartbeat not found. Run 'npm link' from agent/ first."
  exit 1
fi

# Verify Claude CLI
if [ ! -f "$HOME/.local/bin/claude" ]; then
  echo "Warning: Claude CLI not found at ~/.local/bin/claude"
  echo "Install from: https://github.com/anthropics/claude-code"
fi

# Create directories
mkdir -p "$HOME/.bonsai/logs"
mkdir -p "$HOME/.bonsai/sessions"
mkdir -p "$HOME/.bonsai-dev/logs"
mkdir -p "$HOME/.bonsai-dev/sessions"

# Platform-specific installation
if [ "$PLATFORM" = "Darwin" ]; then
  echo "Installing launchd agent (macOS)..."

  PLIST_SRC="./launchd/com.bonsai.heartbeat.plist"
  PLIST_DST="$HOME/Library/LaunchAgents/com.bonsai.heartbeat.plist"

  # Substitute placeholders
  sed -e "s|__NODE_PATH__|$NODE_PATH|g" \
      -e "s|__HEARTBEAT_PATH__|$HEARTBEAT_PATH|g" \
      -e "s|__HOME__|$HOME|g" \
      "$PLIST_SRC" > "$PLIST_DST"

  # Load agent
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load "$PLIST_DST"

  echo "✓ Installed: $PLIST_DST"
  echo "✓ Loaded with launchctl"
  echo ""
  echo "Check status: launchctl list | grep bonsai"
  echo "View logs: tail -f ~/.bonsai/logs/launchd.out"

elif [ "$PLATFORM" = "Linux" ]; then
  echo "Installing cron job (Linux)..."

  CRON_SRC="./cron/bonsai-heartbeat"
  CRON_DST="/tmp/bonsai-heartbeat.cron"

  # Substitute placeholders
  sed -e "s|__HEARTBEAT_PATH__|$HEARTBEAT_PATH|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__USER__|$USER|g" \
      "$CRON_SRC" > "$CRON_DST"

  # Add to user crontab
  (crontab -l 2>/dev/null || true; cat "$CRON_DST") | crontab -

  echo "✓ Added to user crontab"
  echo ""
  echo "Check status: crontab -l"
  echo "View logs: tail -f ~/.bonsai/logs/cron.log"

else
  echo "Error: Unsupported platform: $PLATFORM"
  echo "Supported: Darwin (macOS), Linux"
  exit 1
fi

echo ""
echo "Installation complete!"
echo "Heartbeat will run every 60 seconds."
