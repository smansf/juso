#!/usr/bin/env bash
# remove-agent.sh
# Removes an agent from an existing workload's OpenClaw gateway.
# Usage: sudo ~/juso/scripts/remove-agent.sh <workload-name> <agent-name>
# Run from the repo root as juso-admin-vm.
#
# Stops the gateway, removes the agent via the OpenClaw CLI, removes
# the workspace directory, and restarts the gateway if other agents remain.
#
# This operation is irreversible — agent workspace and session history
# are permanently deleted.

set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────

WORKLOAD="${1:-}"
AGENT="${2:-}"

if [[ -z "$WORKLOAD" || -z "$AGENT" ]]; then
  echo "Usage: sudo ~/juso/scripts/remove-agent.sh <workload-name> <agent-name>"
  echo "Example: sudo ~/juso/scripts/remove-agent.sh research collector"
  exit 1
fi

# ─── Validate names ──────────────────────────────────────────────────────────

if ! [[ "$WORKLOAD" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: invalid workload name '${WORKLOAD}'."
  exit 1
fi

if ! [[ "$AGENT" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: invalid agent name '${AGENT}'."
  exit 1
fi

# ─── Check workload exists ───────────────────────────────────────────────────

USER="juso-${WORKLOAD}"

if ! id "$USER" &>/dev/null; then
  echo "Error: workload '${WORKLOAD}' is not provisioned (user '${USER}' not found)."
  exit 1
fi

USER_UID=$(id -u "$USER")
USER_HOME="/home/${USER}"
OPENCLAW_DIR="${USER_HOME}/.openclaw"
WORKSPACE_DIR="${OPENCLAW_DIR}/workspace/${AGENT}"

# ─── Check agent exists ──────────────────────────────────────────────────────

if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo "Error: agent '${AGENT}' not found in workload '${WORKLOAD}'."
  echo "  Expected workspace: ${WORKSPACE_DIR}"
  exit 1
fi

# ─── Confirm ─────────────────────────────────────────────────────────────────

echo ""
echo "==> Remove agent: ${AGENT}"
echo "    Workload  : ${WORKLOAD}"
echo "    Workspace : ${WORKSPACE_DIR}"
echo ""
echo "    This will permanently delete the agent's configuration, workspace,"
echo "    and all session history. This cannot be undone."
echo ""
read -rp "    Type the agent name to confirm: " CONFIRM
if [[ "$CONFIRM" != "$AGENT" ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""

# ─── Check gateway status ────────────────────────────────────────────────────

GATEWAY_WAS_RUNNING=false
if juso-ctl "$WORKLOAD" is-active 2>/dev/null | grep -q "^active"; then
  GATEWAY_WAS_RUNNING=true
fi

# ─── Stop gateway ────────────────────────────────────────────────────────────

if [[ "$GATEWAY_WAS_RUNNING" == true ]]; then
  echo "[+] Stopping gateway..."
  juso-ctl "$WORKLOAD" stop
fi

# ─── Remove agent via OpenClaw CLI ───────────────────────────────────────────

echo "[+] Removing agent from OpenClaw config..."
sudo -u "$USER" bash -c "
  export HOME=${USER_HOME}
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
  openclaw agents delete ${AGENT} --force
" || {
  echo "    Warning: openclaw agents delete exited non-zero."
  echo "    The agent may still be referenced in openclaw.json."
  echo "    Run: openclaw agents list (as ${USER}) to verify."
}

# ─── Remove workspace directory ──────────────────────────────────────────────

if [[ -d "$WORKSPACE_DIR" ]]; then
  echo "[+] Removing workspace directory..."
  rm -rf "$WORKSPACE_DIR"
fi

# ─── Count remaining agents ──────────────────────────────────────────────────

REMAINING=$(find "${OPENCLAW_DIR}/workspace" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

# ─── Restart gateway if it was running and agents remain ─────────────────────

if [[ "$GATEWAY_WAS_RUNNING" == true ]]; then
  if [[ "$REMAINING" -gt 0 ]]; then
    echo "[+] Restarting gateway..."
    juso-ctl "$WORKLOAD" start
  else
    echo "    No agents remain — gateway not restarted."
  fi
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Agent '${AGENT}' removed from workload '${WORKLOAD}'."
if [[ "$REMAINING" -gt 0 ]]; then
  echo "    ${REMAINING} agent(s) remain in this workload."
else
  echo "    No agents remain. The workload is empty but still provisioned."
  echo "    To deprovision entirely: sudo ~/juso/scripts/destroy-workload.sh ${WORKLOAD}"
fi
echo ""
