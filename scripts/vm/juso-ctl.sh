#!/usr/bin/env bash
# juso-ctl.sh — manage per-workload OpenClaw gateway services
# Install: copied to /usr/local/bin/juso-ctl by install-vm-infrastructure.sh
# Usage:   sudo juso-ctl <workload> <start|stop|restart|status|is-active>
#
# Runs as root (via sudo). Uses runuser to execute systemctl --user
# in the workload user's session context.

set -euo pipefail

WORKLOAD="${1:-}"
ACTION="${2:-}"

if [[ -z "$WORKLOAD" || -z "$ACTION" ]]; then
  echo "Usage: juso-ctl <workload> <start|stop|restart|status|is-active>"
  exit 1
fi

case "$ACTION" in
  start|stop|restart|status|is-active) ;;
  *)
    echo "Error: unknown action '${ACTION}'. Use: start, stop, restart, status, is-active"
    exit 1
    ;;
esac

USER="juso-${WORKLOAD}"

if ! id "$USER" &>/dev/null; then
  echo "Error: user '${USER}' not found. Is workload '${WORKLOAD}' provisioned?"
  exit 1
fi

USER_UID=$(id -u "$USER")
XDG_RUNTIME_DIR="/run/user/${USER_UID}"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus"

if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
  echo "Error: user session not running for '${USER}'. Is linger enabled?"
  echo "  Fix: sudo loginctl enable-linger ${USER}"
  exit 1
fi

runuser -u "$USER" -- \
  env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
  HOME="/home/${USER}" \
  systemctl --user "$ACTION" openclaw-gateway.service
