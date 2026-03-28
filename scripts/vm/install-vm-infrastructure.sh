#!/usr/bin/env bash
# install-vm-infrastructure.sh
# Installs system-wide juso binaries and sudoers rules on the VM.
# Usage: sudo ~/juso/scripts/install-vm-infrastructure.sh
#
# Run once after deploying scripts to the VM (macbook-setup.md Part 8),
# and re-run whenever scripts are redeployed to pick up updates.
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDOERS_FILE="/etc/sudoers.d/juso-infrastructure"

echo ""
echo "==> Installing juso infrastructure"
echo ""

# ─── juso-workload-list ───────────────────────────────────────────────────────

echo "[+] Installing juso-workload-list..."
cp "${SCRIPT_DIR}/juso-workload-list.sh" /usr/local/bin/juso-workload-list
chmod 755 /usr/local/bin/juso-workload-list

# ─── juso-ctl ────────────────────────────────────────────────────────────────

echo "[+] Installing juso-ctl..."
cp "${SCRIPT_DIR}/juso-ctl.sh" /usr/local/bin/juso-ctl
chmod 755 /usr/local/bin/juso-ctl

# ─── sudoers ─────────────────────────────────────────────────────────────────

echo "[+] Writing sudoers rules..."
cat > "$SUDOERS_FILE" <<EOF
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-workload-list
juso-validation ALL=(root) NOPASSWD: /usr/local/bin/juso-workload-list
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-ctl
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/provision-workload.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/destroy-workload.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/add-agent.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/remove-agent.sh
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /usr/bin/rsync
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /bin/bash
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /usr/local/bin/openclaw dashboard
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Infrastructure installed."
echo ""
echo "    /usr/local/bin/juso-workload-list"
echo "    /usr/local/bin/juso-ctl"
echo "    ${SUDOERS_FILE}"
echo ""
