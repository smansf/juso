#!/bin/bash
# configure-ollama.sh
#
# Configures Ollama to run as a persistent LaunchAgent bound to
# 192.168.64.1:11434 (UTM virtual network interface), so the Linux VM
# can reach it while keeping it off the local network.
#
# Replaces the Ollama.app GUI auto-start with a direct 'ollama serve'
# LaunchAgent. OLLAMA_HOST is embedded directly in the plist rather than
# set via launchctl setenv — this survives Ollama updates and app restarts.
#
# Run as juso. Safe to re-run after Ollama updates.
# Usage: bash ~/juso/scripts/configure-ollama.sh
#
# After running:
#   - Remove Ollama.app from System Settings → General → Login Items
#     (the LaunchAgent replaces it — having both causes port conflicts)
#   - Do not open the Ollama.app manually while the LaunchAgent is active

set -euo pipefail

OLLAMA_BIN="/usr/local/bin/ollama"
OLLAMA_HOST_VALUE="192.168.64.1:11434"
PLIST_DIR="$HOME/Library/LaunchAgents"
NEW_PLIST="$PLIST_DIR/com.juso.ollama-serve.plist"

# ─── Verify ollama binary ─────────────────────────────────────────────────────

if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "Error: ollama binary not found at $OLLAMA_BIN"
  echo "Install Ollama first: https://ollama.com/download"
  exit 1
fi

# ─── Stop any running Ollama processes ───────────────────────────────────────

echo "Stopping Ollama..."
osascript -e 'quit app "Ollama"' 2>/dev/null || true
killall ollama 2>/dev/null || true
sleep 2

# ─── Unload existing serve LaunchAgent if present ────────────────────────────

if [[ -f "$NEW_PLIST" ]]; then
  launchctl unload "$NEW_PLIST" 2>/dev/null || true
fi

# ─── Create LaunchAgents directory if needed ─────────────────────────────────

mkdir -p "$PLIST_DIR"

# ─── Write serve LaunchAgent ──────────────────────────────────────────────────
# OLLAMA_HOST is set directly in EnvironmentVariables — not via launchctl setenv.
# This means it is always in effect regardless of how Ollama is started,
# and is not affected by Ollama GUI updates resetting the environment.

echo "Writing LaunchAgent: $NEW_PLIST"
cat > "$NEW_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.juso.ollama-serve</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OLLAMA_BIN}</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_HOST</key>
        <string>${OLLAMA_HOST_VALUE}</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ollama.error.log</string>
</dict>
</plist>
EOF

# ─── Load the LaunchAgent ─────────────────────────────────────────────────────
# Use bootstrap (not the deprecated 'load') so this works correctly whether
# run from a full login session or a 'su juso' shell from jusoadmin.

echo "Loading LaunchAgent..."
launchctl bootout "gui/$(id -u)" "$NEW_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$NEW_PLIST"

# ─── Wait and verify ──────────────────────────────────────────────────────────

echo "Waiting for Ollama to start..."
sleep 3

echo ""
if lsof -i :11434 | grep -q "${OLLAMA_HOST_VALUE%%:*}"; then
  echo "✓ Ollama is listening on ${OLLAMA_HOST_VALUE}"
else
  echo "⚠ Ollama may not be bound correctly. Check:"
  echo "  lsof -i :11434"
  echo "  cat /tmp/ollama.error.log"
fi

echo ""
echo "─── Post-run action required ────────────────────────────────────────────"
echo ""
echo "  Remove Ollama from Login Items AND App Background Activity:"
echo "  System Settings → General → Login Items & Extensions"
echo "    Login Items: remove Ollama from the list"
echo "    App Background Activity: disable the toggle for Ollama"
echo "  Both must be disabled — if App Background Activity is left on, macOS"
echo "  starts Ollama at login without OLLAMA_HOST, binding to 127.0.0.1"
echo "  before this LaunchAgent fires."
echo ""
echo "  To update Ollama in future:"
echo "  1. Download and install the new Ollama.app"
echo "  2. Re-run this script (re-registers the LaunchAgent with the new binary)"
echo "  3. Do not launch Ollama.app directly after updating"
echo ""
