#!/usr/bin/env bash
# juso-config-set — Patch /home/<workload>/.openclaw/openclaw.json as root,
# preserving root:<workload> 640 ownership. Simple-path mode only; complex jq
# operations are the workload's concern via juso-ops-exec helpers.
# Installed at /usr/local/bin/juso-config-set; invoked via sudo.

set -euo pipefail

usage() {
  cat <<EOF
Usage: juso-config-set <workload> <jq-path> <value> [--strict-json]

  <jq-path>    dotted path, e.g. agents.defaults.timeoutSeconds
  <value>      string by default; with --strict-json, parsed as JSON
EOF
}

[[ "${1:-}" == "--help" ]] && {
  usage
  exit 0
}

workload="${1:-}"
path="${2:-}"
value="${3:-}"
strict_json=false
if [[ "${4:-}" == "--strict-json" ]]; then
  strict_json=true
fi

if [[ -z "$workload" || -z "$path" || -z "$value" ]]; then
  usage >&2
  exit 1
fi

if ! getent group juso-workloads | grep -qw "$workload"; then
  echo "juso-config-set: '$workload' is not a juso-workloads member" >&2
  exit 1
fi

config="/home/${workload}/.openclaw/openclaw.json"
if [[ ! -f "$config" ]]; then
  echo "juso-config-set: ${config} not found" >&2
  exit 1
fi

if $strict_json; then
  jq_expr=".${path} = ${value}"
else
  jq_expr=".${path} = \$v"
fi

tmp=$(mktemp)
if $strict_json; then
  jq "$jq_expr" "$config" >"$tmp"
else
  jq --arg v "$value" "$jq_expr" "$config" >"$tmp"
fi

mv "$tmp" "$config"
chown "root:${workload}" "$config"
chmod 640 "$config"
