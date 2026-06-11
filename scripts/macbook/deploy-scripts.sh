#!/usr/bin/env bash
# deploy-scripts.sh — Deploy scripts and validation files from the repo to the
# Mac mini and VM. Run from the repo root on the MacBook. Safe to re-run; copies
# always overwrite. After deploy, re-run install-vm-infrastructure.sh on the VM
# to pick up any changes to system-wide binaries.

set -euo pipefail

usage() {
  cat <<EOF
Usage: deploy-scripts.sh [--vm-only]

  --vm-only   Deploy VM scripts and validation only; skip mini scripts.
              Use when mini SSH requires an interactive TTY for sudo.
EOF
  exit "${1:-1}"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VM_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --vm-only) VM_ONLY=true ;;
    -h | --help) usage 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage 1
      ;;
  esac
done

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

if $VM_ONLY; then
  echo "[skip] Mini scripts (--vm-only)"
else
  echo "[+] Deploying mini scripts..."
  scp "${REPO_ROOT}/scripts/mini/"* mini:~/
  echo "    sudo password for mini required:"
  ssh -t mini "sudo mkdir -p /Users/juso/scripts \
    && sudo chown juso:staff /Users/juso/scripts \
    && sudo cp ~/configure-ollama.sh /Users/juso/scripts/ \
    && sudo chown juso:staff /Users/juso/scripts/configure-ollama.sh"
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "==> Deployment complete."
echo ""
echo "    If juso-ctl or juso-workload-list changed, update the VM binaries:"
echo "    ssh -t vm 'sudo ~/juso/scripts/install-vm-infrastructure.sh'"
echo ""
