#!/usr/bin/env bash
# add-agent.sh
# Adds a new agent to an existing workload's OpenClaw gateway.
# Usage: sudo ~/juso/scripts/add-agent.sh <workload-name> <agent-name>
# Run from the repo root as juso-admin-vm.
#
# Runs the OpenClaw agent creation wizard as the workload user.
# The wizard is interactive — you will be prompted for agent configuration.
# After the wizard exits, the gateway is restarted if it was running.

set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────

WORKLOAD="${1:-}"
AGENT="${2:-}"

if [[ -z "$WORKLOAD" || -z "$AGENT" ]]; then
  echo "Usage: sudo ~/juso/scripts/add-agent.sh <workload-name> <agent-name>"
  echo "Example: sudo ~/juso/scripts/add-agent.sh research collector"
  exit 1
fi

# ─── Validate workload name ──────────────────────────────────────────────────

if ! [[ "$WORKLOAD" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: workload name must use lowercase letters, digits, and hyphens only,"
  echo "       start with a letter, and be 31 characters or fewer."
  exit 1
fi

# ─── Validate agent name ─────────────────────────────────────────────────────

if ! [[ "$AGENT" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: agent name must use lowercase letters, digits, and hyphens only,"
  echo "       start with a letter, and be 31 characters or fewer."
  exit 1
fi

# main is OpenClaw's reserved default agent — configured automatically at provision time
if [[ "$AGENT" == "main" ]]; then
  echo "Error: 'main' is OpenClaw's reserved agent. It is configured automatically at"
  echo "       provision time. Do not add it manually."
  echo "  To deploy workspace files use: juso-push-agent ${WORKLOAD} main"
  exit 1
fi

# ─── Check workload exists ───────────────────────────────────────────────────

USER="juso-${WORKLOAD}"

if ! id "$USER" &>/dev/null; then
  echo "Error: workload '${WORKLOAD}' is not provisioned (user '${USER}' not found)."
  echo "  Run: sudo ~/juso/scripts/provision-workload.sh ${WORKLOAD}"
  exit 1
fi

USER_UID=$(id -u "$USER")
USER_HOME="/home/${USER}"
OPENCLAW_DIR="${USER_HOME}/.openclaw"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace/${AGENT}"

# ─── Check agent does not already exist ──────────────────────────────────────

if [[ -d "$WORKSPACE_DIR" ]]; then
  echo "Error: agent '${AGENT}' already exists in workload '${WORKLOAD}'."
  echo "  Workspace: ${WORKSPACE_DIR}"
  exit 1
fi

# ─── Check gateway service status ────────────────────────────────────────────

GATEWAY_WAS_RUNNING=false
if juso-ctl "$WORKLOAD" status 2>/dev/null | grep -q "active (running)"; then
  GATEWAY_WAS_RUNNING=true
fi

# ─── Run openclaw agents add as the workload user ────────────────────────────

echo ""
echo "==> Adding agent '${AGENT}' to workload '${WORKLOAD}'"
echo ""
echo "    The OpenClaw agent wizard will now run."
echo "    Answer the prompts to configure the agent."
echo "    When asked for the workspace path, accept the default or use:"
echo "    ${WORKSPACE_DIR}"
echo ""

sudo -u "$USER" bash -c "
  export HOME=${USER_HOME}
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
  openclaw agents add ${AGENT}
"

# ─── Verify workspace was created ────────────────────────────────────────────

if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo ""
  echo "Warning: workspace directory not found at expected path:"
  echo "  ${WORKSPACE_DIR}"
  echo "  The wizard may have used a different path. Check:"
  echo "  ls ${OPENCLAW_DIR}/workspace/"
  echo ""
else
  echo ""
  echo "==> Agent workspace created:"
  ls "${WORKSPACE_DIR}"
  echo ""
  # Scaffold memory/ subdirectory for daily logs (standard OpenClaw convention)
  mkdir -p "${WORKSPACE_DIR}/memory"
  chown "${USER}:${USER}" "${WORKSPACE_DIR}/memory"
  echo "    memory/ directory created."
  echo ""
fi

# ─── Patch main agent workspace path ─────────────────────────────────────────
# openclaw agents add re-inserts a bare {"id":"main"} entry into agents.list as a
# side effect. Ensure main always has a workspace path and default:true after every
# agent add, regardless of the re-add. Also creates main's directories defensively
# in case provision did not create them.

CONFIG="${OPENCLAW_DIR}/openclaw.json"
MAIN_WORKSPACE="${OPENCLAW_DIR}/workspace/main"

mkdir -p "${MAIN_WORKSPACE}/memory"
mkdir -p "${OPENCLAW_DIR}/agents/main/agent"
mkdir -p "${OPENCLAW_DIR}/agents/main/sessions"
chown -R "${USER}:${USER}" "${MAIN_WORKSPACE}"
chown -R "${USER}:${USER}" "${OPENCLAW_DIR}/agents"

# Check whether main's agents.list entry is missing the workspace field
MAIN_HAS_WORKSPACE=$(jq -r '(.agents.list[] | select(.id == "main") | .workspace) // ""' "$CONFIG" 2>/dev/null)

if [[ -z "$MAIN_HAS_WORKSPACE" ]]; then
  echo "[+] Patching main agent workspace path..."
  if jq -e '.agents.list[] | select(.id == "main")' "$CONFIG" > /dev/null 2>&1; then
    jq --arg ws "${MAIN_WORKSPACE}" \
      '.agents.list = [.agents.list[] | if .id == "main" then . + {"workspace": $ws, "default": true} else . end]' \
      "$CONFIG" > /tmp/openclaw_main_patch.json
  else
    jq --arg ws "${MAIN_WORKSPACE}" \
      '.agents.list += [{"id": "main", "workspace": $ws, "default": true}]' \
      "$CONFIG" > /tmp/openclaw_main_patch.json
  fi
  mv /tmp/openclaw_main_patch.json "$CONFIG"
  chown "${USER}:${USER}" "$CONFIG"
else
  echo "[skip] main agent workspace already configured"
fi

# ─── Restart gateway if it was running ───────────────────────────────────────

if [[ "$GATEWAY_WAS_RUNNING" == true ]]; then
  echo "[+] Restarting gateway to pick up new agent..."
  juso-ctl "$WORKLOAD" restart
  echo "    Gateway restarted."
else
  echo "    Gateway is not running. Start it when ready:"
  echo "    sudo juso-ctl ${WORKLOAD} start"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Agent '${AGENT}' added to workload '${WORKLOAD}'."
echo ""
echo "    Before starting the gateway, edit the workspace files to define"
echo "    the agent's persona and behavior:"
echo ""
echo "    ${WORKSPACE_DIR}/SOUL.md      ← persona and behavioral boundaries"
echo "    ${WORKSPACE_DIR}/AGENTS.md    ← operating instructions"
echo "    ${WORKSPACE_DIR}/USER.md      ← information about the user"
echo "    ${WORKSPACE_DIR}/MEMORY.md    ← long-term memory seed"
echo "    ${WORKSPACE_DIR}/BOOTSTRAP.md ← first-run setup ritual"
echo ""
echo "    If this agent uses web search, configure the search provider API key"
echo "    in the workload's openclaw.json or via the dashboard before use."
echo ""
