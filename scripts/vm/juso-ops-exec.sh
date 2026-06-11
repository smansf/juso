#!/usr/bin/env bash
# juso-ops-exec — Execute a script in /home/<workload>/scripts/ops/ as root.
# The only mechanism to invoke ops-tier scripts after the kernel-ACL flip
# (workload user cannot read or exec them).
# Installed at /usr/local/bin/juso-ops-exec; invoked via sudo.

set -euo pipefail

usage() { echo "Usage: juso-ops-exec <workload> <ops-script-name> [args...]"; }

[[ "${1:-}" == "--help" ]] && {
  usage
  exit 0
}

workload="${1:-}"
script_name="${2:-}"
shift 2 2>/dev/null || true

if [[ -z "$workload" || -z "$script_name" ]]; then
  usage >&2
  exit 1
fi

if ! getent group juso-workloads | grep -qw "$workload"; then
  echo "juso-ops-exec: '$workload' is not a juso-workloads member" >&2
  exit 1
fi

if [[ "$script_name" == *"/"* || "$script_name" == *".."* ]]; then
  echo "juso-ops-exec: script name must not contain '/' or '..'" >&2
  exit 1
fi

target="/home/${workload}/scripts/ops/${script_name}"

if [[ ! -f "$target" ]]; then
  echo "juso-ops-exec: ${target} not found" >&2
  exit 1
fi
owner=$(stat -c '%u:%g' "$target")
if [[ "$owner" != "0:0" ]]; then
  echo "juso-ops-exec: ${target} not owned root:root (got ${owner})" >&2
  exit 1
fi

exec bash "$target" "$@"
