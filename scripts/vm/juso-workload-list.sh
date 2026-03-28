#!/usr/bin/env bash
# juso-workload-list.sh
# Lists all provisioned juso workloads and their gateway ports.
# Scans /home/juso-*/ directories, reads gateway.port from each workload's
# openclaw.json via jq.
#
# Requires root (workload home directories are mode 700).
# Install path: /usr/local/bin/juso-workload-list
#
# Output: one line per workload, format: <name>:<port>
# Exit:   0 = success
#         1 = error (missing jq, etc.)

set -euo pipefail

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

for home_dir in /home/juso-*/; do
  [[ -d "$home_dir" ]] || continue

  username=$(basename "$home_dir")

  # Skip the admin account
  [[ "$username" == "juso-admin-vm" ]] && continue

  # Extract workload name (strip juso- prefix)
  workload="${username#juso-}"

  config="${home_dir}.openclaw/openclaw.json"
  if [[ -f "$config" ]]; then
    port=$(jq -r '.gateway.port // empty' "$config" 2>/dev/null) || true
    if [[ -n "$port" ]]; then
      echo "${workload}:${port}"
    fi
  fi
done
