#!/usr/bin/env bash
# audit-acl.sh — Static ACL ownership and mode checks for one workload.
# Verifies scripts/{agent,ops,lib}/ ownership matrix and openclaw.json
# ownership/mode. JSON output, same shape as audit.sh.
# Installed at /usr/local/bin/audit-acl.sh; invoked via sudo.

set -euo pipefail

usage() { echo "Usage: audit-acl.sh <workload>"; }

[[ "${1:-}" == "--help" ]] && {
  usage
  exit 0
}

workload="${1:-}"
if [[ -z "$workload" ]]; then
  usage >&2
  exit 1
fi

if ! getent group juso-workloads | grep -qw "$workload"; then
  echo "audit-acl: '$workload' is not a juso-workloads member" >&2
  exit 1
fi

home="/home/${workload}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
checks=()

add_check() {
  local json
  json=$(jq -n \
    --arg name "$1" --arg display_name "$2" --arg layer "$3" \
    --arg what "$4" --arg expected "$5" --arg actual "$6" \
    --arg result "$7" --arg evidence "$8" \
    '{name: $name, display_name: $display_name, layer: $layer,
      what: $what, expected: $expected, actual: $actual,
      result: $result, evidence: $evidence}')
  checks+=("$json")
}

check_path() {
  local name="$1" path="$2" expected_owner="$3" expected_mode="$4"
  if [[ ! -e "$path" ]]; then
    add_check "$name" "$name" "acl-static" \
      "stat ${path}" "exists, ${expected_owner}, ${expected_mode}" \
      "missing" "FAIL" "stat: not found"
    return
  fi
  local actual_owner actual_mode
  actual_owner=$(stat -c '%U:%G' "$path")
  actual_mode=$(stat -c '%a' "$path")
  if [[ "$actual_owner" == "$expected_owner" && "$actual_mode" == "$expected_mode" ]]; then
    add_check "$name" "$name" "acl-static" \
      "stat ${path}" "${expected_owner}, ${expected_mode}" \
      "${actual_owner}, ${actual_mode}" "PASS" \
      "stat: matches"
  else
    add_check "$name" "$name" "acl-static" \
      "stat ${path}" "${expected_owner}, ${expected_mode}" \
      "${actual_owner}, ${actual_mode}" "FAIL" \
      "stat: mismatch"
  fi
}

check_path "static_scripts_root" "${home}/scripts" "root:root" "755"
check_path "static_scripts_agent" "${home}/scripts/agent" "root:root" "755"
check_path "static_scripts_ops" "${home}/scripts/ops" "root:root" "750"
check_path "static_scripts_lib" "${home}/scripts/lib" "root:root" "755"
check_path "static_openclaw_json" "${home}/.openclaw/openclaw.json" "root:${workload}" "640"

checks_json=$(printf '%s\n' "${checks[@]}" | jq -s '.')
jq -n --arg ts "$TIMESTAMP" --argjson checks "$checks_json" \
  '{timestamp: $ts, workload: "'"$workload"'", checks: $checks}'
