#!/usr/bin/env bash
# deploy-scripts.sh
# Deploys scripts and validation files from the repo to the Mac mini and VM.
# Usage: ./scripts/macbook/deploy-scripts.sh
# Run from the repo root on the MacBook.
#
# Safe to re-run — copies always overwrite.
# After running, re-run install-vm-infrastructure.sh on the VM to pick up any
# changes to system-wide binaries (juso-ctl, juso-workload-list):
#   ssh -t vm "sudo ~/juso/scripts/install-vm-infrastructure.sh"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo ""
echo "==> Deploying juso scripts"
echo ""

# ─── VM scripts ──────────────────────────────────────────────────────────────

echo "[+] Deploying VM scripts..."
ssh vm "mkdir -p ~/juso/scripts"
scp "${REPO_ROOT}/scripts/vm/"* vm:~/juso/scripts/
ssh vm "chmod +x ~/juso/scripts/*.sh"

# ─── VM validation ───────────────────────────────────────────────────────────

echo "[+] Deploying VM validation files..."
ssh vm "mkdir -p ~/juso/validation/agents"
scp -r "${REPO_ROOT}/validation/"* vm:~/juso/validation/

# ─── Mini scripts ────────────────────────────────────────────────────────────

echo "[+] Deploying mini scripts..."
scp "${REPO_ROOT}/scripts/mini/"* mini:~/
echo "    sudo password for mini required:"
ssh -t mini "sudo mkdir -p /Users/juso/scripts \
  && sudo chown juso:staff /Users/juso/scripts \
  && sudo cp ~/configure-ollama.sh /Users/juso/scripts/ \
  && sudo chown juso:staff /Users/juso/scripts/configure-ollama.sh"

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "==> Deployment complete."
echo ""
echo "    If juso-ctl or juso-workload-list changed, update the VM binaries:"
echo "    ssh -t vm 'sudo ~/juso/scripts/install-vm-infrastructure.sh'"
echo ""
