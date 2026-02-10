#!/bin/bash
set -e

echo "Bonsai Heartbeat Uninstaller"
echo "============================="

PLATFORM=$(uname -s)
USER=$(whoami)
HOME=$(eval echo ~$USER)

if [ "$PLATFORM" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.bonsai.heartbeat.plist"

  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm "$PLIST"
    echo "✓ Removed launchd agent"
  else
    echo "No launchd agent found"
  fi

elif [ "$PLATFORM" = "Linux" ]; then
  # Remove from crontab
  crontab -l | grep -v "bonsai-heartbeat" | crontab - || true
  echo "✓ Removed cron entry"

else
  echo "Unsupported platform: $PLATFORM"
  exit 1
fi

echo ""
echo "Uninstallation complete."
echo "Note: Log files in ~/.bonsai/ were NOT deleted."
