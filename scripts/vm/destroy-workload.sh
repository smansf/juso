#!/usr/bin/env bash
# destroy-workload.sh
# Completely deprovisions a juso workload.
# Usage: sudo ~/juso/scripts/destroy-workload.sh <workload-name>
# Run from the repo root as juso-admin-vm.
#
# Stops the gateway, uninstalls the systemd service via the OpenClaw CLI,
# stops the user session, deletes the Linux user and home directory (including
# all agent workspaces and session history), and removes any iptables rules.
#
# This operation is irreversible.

set -euo pipefail

# ─── Usage ───────────────────────────────────────────────────────────────────

WORKLOAD="${1:-}"

if [[ -z "$WORKLOAD" ]]; then
  echo "Usage: sudo ~/juso/scripts/destroy-workload.sh <workload-name>"
  echo "Example: sudo ~/juso/scripts/destroy-workload.sh research"
  exit 1
fi

# ─── Validate name ───────────────────────────────────────────────────────────

if ! [[ "$WORKLOAD" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: invalid workload name '${WORKLOAD}'."
  exit 1
fi

USER="juso-${WORKLOAD}"

# ─── Check workload exists ───────────────────────────────────────────────────

if ! id "$USER" &>/dev/null; then
  echo "Error: workload '${WORKLOAD}' is not provisioned (user '${USER}' not found)."
  exit 1
fi

USER_UID=$(id -u "$USER")
USER_HOME="/home/${USER}"

# ─── Confirm ─────────────────────────────────────────────────────────────────

echo ""
echo "==> Destroy workload: ${WORKLOAD}"
echo ""
echo "    This will permanently delete:"
echo "    - Linux user  : ${USER}"
echo "    - Home dir    : ${USER_HOME}"
echo "      (all agents, workspaces, openclaw.json, session history)"
echo "    - Gateway systemd service"
echo "    - iptables rules (if any)"
echo ""
echo "    This cannot be undone."
echo ""
read -rp "    Type the workload name to confirm: " CONFIRM
if [[ "$CONFIRM" != "$WORKLOAD" ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""

# ─── Stop gateway ────────────────────────────────────────────────────────────

echo "[+] Stopping gateway..."
juso-ctl "$WORKLOAD" stop 2>/dev/null || true

# ─── Uninstall gateway service via OpenClaw CLI ──────────────────────────────

echo "[+] Uninstalling gateway service..."
sudo -u "$USER" bash -c "
  export HOME=${USER_HOME}
  export XDG_RUNTIME_DIR=/run/user/${USER_UID}
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
  openclaw gateway uninstall
" 2>/dev/null || {
  echo "    Warning: openclaw gateway uninstall failed. Removing service file manually..."
  SERVICE_FILE="${USER_HOME}/.config/systemd/user/openclaw-gateway.service"
  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    sudo -u "$USER" bash -c "
      export XDG_RUNTIME_DIR=/run/user/${USER_UID}
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
      systemctl --user daemon-reload
    " 2>/dev/null || true
  fi
}

# ─── Stop user session ───────────────────────────────────────────────────────

echo "[+] Stopping user session..."
systemctl stop "user@${USER_UID}.service" 2>/dev/null || true

# ─── Disable linger ──────────────────────────────────────────────────────────

echo "[+] Disabling linger..."
loginctl disable-linger "$USER" 2>/dev/null || true

# ─── Remove internet access iptables rule ────────────────────────────────────

BEFORE_RULES="/etc/ufw/before.rules"
RULE_MARKER="# juso-internet: ${WORKLOAD}"

if grep -qF "$RULE_MARKER" "$BEFORE_RULES" 2>/dev/null; then
  echo "[+] Removing internet access rule from before.rules..."
  # Remove the marker line and the rule line immediately following it
  sed -i "/${RULE_MARKER}/,+1d" "$BEFORE_RULES"
  echo "[+] Reloading UFW..."
  ufw reload
else
  echo "[skip] No internet access rule found for ${WORKLOAD}"
fi

# ─── Remove DNS block iptables rule ──────────────────────────────────────────

DNS_RULE_MARKER="# juso-nodns: ${WORKLOAD}"

if grep -qF "$DNS_RULE_MARKER" "$BEFORE_RULES" 2>/dev/null; then
  echo "[+] Removing DNS block rule from before.rules..."
  # Remove the marker line and the 2 rule lines immediately following it (UDP + TCP)
  sed -i "/${DNS_RULE_MARKER}/,+2d" "$BEFORE_RULES"
  echo "[+] Reloading UFW..."
  ufw reload
else
  echo "[skip] No DNS block rule found for ${WORKLOAD}"
fi

# ─── Delete Linux user and home directory ────────────────────────────────────

echo "[+] Deleting user ${USER} and home directory..."
userdel -r "$USER" 2>/dev/null || {
  # userdel fails if processes are still running — kill them and retry
  echo "    Sending SIGTERM to remaining processes for ${USER}..."
  pkill -u "$USER" 2>/dev/null || true
  sleep 2
  # Check whether processes are still alive; if so, escalate to SIGKILL
  if pgrep -u "$USER" &>/dev/null; then
    echo "    Processes still running — sending SIGKILL..."
    pkill -9 -u "$USER" 2>/dev/null || true
    sleep 2
  fi
  userdel -r "$USER"
}

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Workload '${WORKLOAD}' destroyed."
echo ""
