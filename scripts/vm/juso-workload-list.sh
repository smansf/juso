#!/usr/bin/env bash
# juso-workload-list.sh — List all provisioned juso workloads and their gateway
# ports. Discovers workloads via the juso-workloads group; workload name equals
# Linux username. Requires root (home directories are mode 700). Output: one
# line per workload, format <name>:<port>. Installed at
# /usr/local/bin/juso-workload-list.

set -euo pipefail

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

members=$(getent group juso-workloads 2>/dev/null | cut -d: -f4) || true
[[ -z "$members" ]] && exit 0

while IFS= read -r workload; do
  [[ -z "$workload" ]] && continue
  config="/home/${workload}/.openclaw/openclaw.json"
  if [[ -f "$config" ]]; then
    port=$(jq -r '.gateway.port // empty' "$config" 2>/dev/null) || true
    if [[ -n "$port" ]]; then
      echo "${workload}:${port}"
    fi
  fi
done < <(echo "$members" | tr ',' '\n')
