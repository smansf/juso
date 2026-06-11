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

# ─── juso-config-set ─────────────────────────────────────────────────────────

echo "[+] Installing juso-config-set to /usr/local/bin..."
cp "${SCRIPT_DIR}/juso-config-set.sh" /usr/local/bin/juso-config-set
chmod 755 /usr/local/bin/juso-config-set

# ─── juso-rsync-scripts ──────────────────────────────────────────────────────

echo "[+] Installing juso-rsync-scripts to /usr/local/bin..."
cp "${SCRIPT_DIR}/juso-rsync-scripts.sh" /usr/local/bin/juso-rsync-scripts
chmod 755 /usr/local/bin/juso-rsync-scripts

# ─── juso-ops-exec ───────────────────────────────────────────────────────────

echo "[+] Installing juso-ops-exec to /usr/local/bin..."
cp "${SCRIPT_DIR}/juso-ops-exec.sh" /usr/local/bin/juso-ops-exec
chmod 755 /usr/local/bin/juso-ops-exec

# ─── audit-acl.sh ────────────────────────────────────────────────────────────

echo "[+] Installing audit-acl.sh to /usr/local/bin..."
cp "${SCRIPT_DIR}/audit-acl.sh" /usr/local/bin/audit-acl.sh
chmod 755 /usr/local/bin/audit-acl.sh

# ─── audit.sh ────────────────────────────────────────────────────────────────
# audit.sh is also installed by provision-workload.sh per-workload, but having
# it here lets infrastructure refreshes update audit.sh without reprovisioning.

echo "[+] Installing audit.sh to /usr/local/bin..."
cp "${SCRIPT_DIR}/audit.sh" /usr/local/bin/audit.sh
chmod 755 /usr/local/bin/audit.sh

# ─── sudoers ─────────────────────────────────────────────────────────────────

echo "[+] Writing sudoers rules..."
cat >"$SUDOERS_FILE" <<EOF
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-workload-list
validation ALL=(root) NOPASSWD: /usr/local/bin/juso-workload-list
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-ctl
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/provision-workload.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/destroy-workload.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/add-agent.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/remove-agent.sh
juso-admin-vm ALL=(root) NOPASSWD: /home/juso-admin-vm/juso/scripts/install-vm-infrastructure.sh
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-config-set
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-rsync-scripts
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/juso-ops-exec
juso-admin-vm ALL=(root) NOPASSWD: /usr/local/bin/audit-acl.sh
juso-admin-vm ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /usr/bin/rsync
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /bin/bash
juso-admin-vm ALL=(%juso-workloads) NOPASSWD: /usr/local/bin/openclaw dashboard
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"

# ─── openclaw bash completion ────────────────────────────────────────────────
# Generates the completion file for juso-admin-vm so the stale source line
# in .bashrc resolves cleanly. Skips gracefully if openclaw is not yet on PATH.

echo "[+] Generating openclaw bash completion for juso-admin-vm..."
if command -v openclaw >/dev/null 2>&1; then
  sudo -u juso-admin-vm bash -c \
    'mkdir -p ~/.local/share/bash-completion/completions && \
     openclaw completion bash > ~/.local/share/bash-completion/completions/openclaw'
  echo "    ~/.local/share/bash-completion/completions/openclaw"
else
  echo "    [skip] openclaw not found — re-run after installing openclaw, or run manually:"
  echo "    openclaw completion bash > ~/.local/share/bash-completion/completions/openclaw"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Infrastructure installed."
echo ""
echo "    /usr/local/bin/juso-workload-list"
echo "    /usr/local/bin/juso-ctl"
echo "    /usr/local/bin/juso-config-set"
echo "    /usr/local/bin/juso-rsync-scripts"
echo "    /usr/local/bin/juso-ops-exec"
echo "    /usr/local/bin/audit-acl.sh"
echo "    ${SUDOERS_FILE}"
echo "    ~/.local/share/bash-completion/completions/openclaw (juso-admin-vm)"
echo ""
