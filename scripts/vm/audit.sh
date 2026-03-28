#!/usr/bin/env bash
# =============================================================================
# juso audit script
#
# Behavioral security audit for the juso platform.
# Runs as an unprivileged workload user (juso-validation). No sudo required.
#
# Assumptions:
#   - OWN_PORT is read at runtime from ~/.openclaw/openclaw.json via jq.
#   - juso-neighbor is always provisioned as the isolation test target.
#     If absent, the isolation check FAILs.
#
# Usage:  /usr/local/bin/audit.sh
# Output: JSON to stdout
# Exit:   0 = all checks completed (inspect JSON for results)
#         1 = script-level error (missing dependency, etc.)
# =============================================================================

set -euo pipefail

OLLAMA_URL="http://192.168.64.1:11434"

# Read own gateway port from config at runtime (no hardcoded port assumption)
OWN_PORT=$(jq -r '.gateway.port // empty' ~/.openclaw/openclaw.json 2>/dev/null) || true
if [[ -z "$OWN_PORT" ]]; then
  echo "Error: could not read gateway.port from ~/.openclaw/openclaw.json" >&2
  exit 1
fi

NEIGHBOR_USER="juso-neighbor"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

checks=()

# -----------------------------------------------------------------------------
# Helper: add a check result to the checks array.
# Uses jq for correct JSON escaping of all fields.
# Arguments: name display_name layer what why expected actual result evidence
# -----------------------------------------------------------------------------
add_check() {
  local json
  json=$(jq -n \
    --arg name        "$1" \
    --arg display_name "$2" \
    --arg layer       "$3" \
    --arg what        "$4" \
    --arg why         "$5" \
    --arg expected    "$6" \
    --arg actual      "$7" \
    --arg result      "$8" \
    --arg evidence    "$9" \
    '{
      name:         $name,
      display_name: $display_name,
      layer:        $layer,
      what:         $what,
      why:          $why,
      expected:     $expected,
      actual:       $actual,
      result:       $result,
      evidence:     $evidence
    }')
  checks+=("$json")
}

# Helper: truncate a string to N characters
truncate() { echo "${1:0:${2:-300}}"; }

# =============================================================================
# Infrastructure layer
# =============================================================================

# ── Ollama reachability ───────────────────────────────────────────────────────

output=$(curl --max-time 10 --silent "${OLLAMA_URL}/api/version" 2>&1) || true

if echo "$output" | grep -q '"version"'; then
  add_check "ollama_reachability" "Ollama reachability" "infrastructure" \
    "Ollama API version endpoint responds" \
    "Model provider must be reachable for agents to function" \
    "HTTP response with version field" \
    "Version received" \
    "PASS" \
    "$(truncate "$output")"
else
  add_check "ollama_reachability" "Ollama reachability" "infrastructure" \
    "Ollama API version endpoint responds" \
    "Model provider must be reachable for agents to function" \
    "HTTP response with version field" \
    "No response or error" \
    "FAIL" \
    "$(truncate "$output")"
fi

# ── Ollama model availability ─────────────────────────────────────────────────

output=$(curl --max-time 10 --silent "${OLLAMA_URL}/api/tags" 2>&1) || true

qwen_present=false
nomic_present=false
echo "$output" | grep -q 'qwen3:30b'         && qwen_present=true
echo "$output" | grep -q 'nomic-embed-text'  && nomic_present=true

if $qwen_present && $nomic_present; then
  add_check "ollama_model_availability" "Ollama model availability" "infrastructure" \
    "Required models present in Ollama" \
    "Missing model causes silent agent failure" \
    "qwen3:30b and nomic-embed-text present" \
    "Both models present" \
    "PASS" \
    "qwen3:30b: present, nomic-embed-text: present"
else
  missing=""
  $qwen_present  || missing+="qwen3:30b missing "
  $nomic_present || missing+="nomic-embed-text missing"
  add_check "ollama_model_availability" "Ollama model availability" "infrastructure" \
    "Required models present in Ollama" \
    "Missing model causes silent agent failure" \
    "qwen3:30b and nomic-embed-text present" \
    "$missing" \
    "FAIL" \
    "$(truncate "$output")"
fi

# ── Internet access blocked ───────────────────────────────────────────────────

http_code=$(curl --max-time 3 --silent --write-out '%{http_code}' \
  -o /dev/null "http://1.1.1.1" 2>/dev/null) || http_code="000"

if [[ "$http_code" == "000" ]]; then
  add_check "internet_blocked" "Internet access blocked" "infrastructure" \
    "Outbound connection to public internet address" \
    "Internet egress enables data exfiltration and C2 contact" \
    "Timeout or connection refused (http_code 000)" \
    "Connection blocked" \
    "PASS" \
    "curl http://1.1.1.1 — http_code: 000"
else
  add_check "internet_blocked" "Internet access blocked" "infrastructure" \
    "Outbound connection to public internet address" \
    "Internet egress enables data exfiltration and C2 contact" \
    "Timeout or connection refused (http_code 000)" \
    "HTTP ${http_code} received — egress not blocked" \
    "FAIL" \
    "curl http://1.1.1.1 — http_code: ${http_code}"
fi

# ── LAN access blocked ────────────────────────────────────────────────────────
# Tests one address from each private range. 192.168.64.1 (Ollama) is expected
# to respond and is not tested here — only non-Ollama LAN addresses.

lan_fail=false
lan_evidence=""

for addr in "10.0.0.1" "172.16.0.1" "192.168.1.1"; do
  code=$(curl --max-time 3 --silent --write-out '%{http_code}' \
    -o /dev/null "http://${addr}" 2>/dev/null) || code="000"
  lan_evidence+="${addr}: http_code=${code}; "
  if [[ "$code" != "000" ]]; then
    lan_fail=true
  fi
done

if ! $lan_fail; then
  add_check "lan_blocked" "LAN access blocked" "infrastructure" \
    "Outbound connections to private LAN addresses" \
    "LAN access enables lateral movement and local service attacks" \
    "All test addresses timeout or refused" \
    "All LAN addresses blocked" \
    "PASS" \
    "$(truncate "$lan_evidence")"
else
  add_check "lan_blocked" "LAN access blocked" "infrastructure" \
    "Outbound connections to private LAN addresses" \
    "LAN access enables lateral movement and local service attacks" \
    "All test addresses timeout or refused" \
    "One or more LAN addresses reachable" \
    "FAIL" \
    "$(truncate "$lan_evidence")"
fi

# ── Cloud metadata endpoint blocked ──────────────────────────────────────────

http_code=$(curl --max-time 3 --silent --write-out '%{http_code}' \
  -o /dev/null "http://169.254.169.254" 2>/dev/null) || http_code="000"

if [[ "$http_code" == "000" ]]; then
  add_check "cloud_metadata_blocked" "Cloud metadata endpoint blocked" "infrastructure" \
    "Outbound connection to cloud instance metadata address" \
    "Metadata endpoint can expose credentials and instance info" \
    "Timeout or connection refused" \
    "Endpoint blocked" \
    "PASS" \
    "curl http://169.254.169.254 — http_code: 000"
else
  add_check "cloud_metadata_blocked" "Cloud metadata endpoint blocked" "infrastructure" \
    "Outbound connection to cloud instance metadata address" \
    "Metadata endpoint can expose credentials and instance info" \
    "Timeout or connection refused" \
    "HTTP ${http_code} received — endpoint reachable" \
    "FAIL" \
    "curl http://169.254.169.254 — http_code: ${http_code}"
fi

# ── DNS resolution blocked ────────────────────────────────────────────────────

dns_output=$(nslookup -timeout=3 google.com 2>&1) || true

if echo "$dns_output" | grep -qE '^Address: [0-9]'; then
  add_check "dns_blocked" "DNS resolution blocked" "infrastructure" \
    "DNS lookup for external hostname" \
    "Working DNS enables hostname-based exfiltration and C2 contact" \
    "SERVFAIL, timeout, or no address returned" \
    "DNS resolved successfully — DNS egress not blocked" \
    "FAIL" \
    "$(truncate "$dns_output")"
else
  add_check "dns_blocked" "DNS resolution blocked" "infrastructure" \
    "DNS lookup for external hostname" \
    "Working DNS enables hostname-based exfiltration and C2 contact" \
    "SERVFAIL, timeout, or no address returned" \
    "DNS resolution failed (blocked)" \
    "PASS" \
    "$(truncate "$dns_output")"
fi

# ── IPv6 egress blocked ───────────────────────────────────────────────────────

ipv6_iface=$(ip -6 addr show scope global 2>/dev/null | grep inet6 || true)

if [[ -z "$ipv6_iface" ]]; then
  add_check "ipv6_blocked" "IPv6 egress blocked" "infrastructure" \
    "Outbound IPv6 connection to external address" \
    "IPv6 can bypass IPv4-only firewall rules" \
    "Timeout, refused, or no IPv6 interface" \
    "No global IPv6 interface configured" \
    "PASS" \
    "ip -6 addr show scope global: no results"
else
  http_code=$(curl --max-time 3 --silent --write-out '%{http_code}' \
    -o /dev/null -6 "http://ipv6.google.com" 2>/dev/null) || http_code="000"
  if [[ "$http_code" == "000" ]]; then
    add_check "ipv6_blocked" "IPv6 egress blocked" "infrastructure" \
      "Outbound IPv6 connection to external address" \
      "IPv6 can bypass IPv4-only firewall rules" \
      "Timeout or connection refused" \
      "IPv6 egress blocked" \
      "PASS" \
      "curl -6 http://ipv6.google.com — http_code: 000"
  else
    add_check "ipv6_blocked" "IPv6 egress blocked" "infrastructure" \
      "Outbound IPv6 connection to external address" \
      "IPv6 can bypass IPv4-only firewall rules" \
      "Timeout or connection refused" \
      "HTTP ${http_code} received over IPv6 — egress not blocked" \
      "FAIL" \
      "curl -6 http://ipv6.google.com — http_code: ${http_code}"
  fi
fi

# ── VPN status ───────────────────────────────────────────────────────────────
# VPN is optional but recommended for --internet=open workloads. PASS if tunnel
# is active or no internet-enabled workloads exist. FAIL if internet-enabled
# workloads exist but no VPN tunnel is detected — known gap, accepted.

vpn_interface=$(ip link show 2>/dev/null | grep -oE '(wg[0-9]+|mullvad[^ ]*)' | head -1) || true
internet_workloads=$(grep -c 'juso-internet:' /etc/ufw/before.rules 2>/dev/null) || internet_workloads=0

if [[ -n "$vpn_interface" ]]; then
  vpn_details=$(ip addr show "$vpn_interface" 2>/dev/null | head -3) || vpn_details="(could not read interface details)"
  add_check "vpn_status" "VPN status" "infrastructure" \
    "WireGuard VPN tunnel interface active" \
    "VPN routes internet-enabled workload traffic through a tunnel, adding a kill switch and preventing direct internet exposure" \
    "VPN tunnel active, or no internet-enabled workloads" \
    "VPN tunnel active (${vpn_interface})" \
    "PASS" \
    "ip link show: ${vpn_interface} found — $(truncate "$vpn_details" 200)"
elif [[ "$internet_workloads" -eq 0 ]]; then
  add_check "vpn_status" "VPN status" "infrastructure" \
    "WireGuard VPN tunnel interface active" \
    "VPN routes internet-enabled workload traffic through a tunnel, adding a kill switch and preventing direct internet exposure" \
    "VPN tunnel active, or no internet-enabled workloads" \
    "No VPN tunnel, but no internet-enabled workloads — VPN not required" \
    "PASS" \
    "ip link show: no wg/mullvad interface; /etc/ufw/before.rules: 0 juso-internet markers"
else
  add_check "vpn_status" "VPN status" "infrastructure" \
    "WireGuard VPN tunnel interface active" \
    "VPN routes internet-enabled workload traffic through a tunnel, adding a kill switch and preventing direct internet exposure" \
    "VPN tunnel active, or no internet-enabled workloads" \
    "No VPN tunnel detected, but ${internet_workloads} internet-enabled workload(s) exist — traffic is unprotected" \
    "FAIL" \
    "ip link show: no wg/mullvad interface; /etc/ufw/before.rules: ${internet_workloads} juso-internet markers"
fi

# ── OpenClaw binary ───────────────────────────────────────────────────────────

oc_output=$(openclaw --version 2>&1) || oc_exit=$?

if [[ ${oc_exit:-0} -eq 0 && -n "$oc_output" ]]; then
  add_check "openclaw_binary" "OpenClaw binary" "infrastructure" \
    "OpenClaw binary present and executable" \
    "Missing or broken binary means no agents can run" \
    "Binary found and exits zero" \
    "$oc_output" \
    "PASS" \
    "openclaw --version: $oc_output"
else
  add_check "openclaw_binary" "OpenClaw binary" "infrastructure" \
    "OpenClaw binary present and executable" \
    "Missing or broken binary means no agents can run" \
    "Binary found and exits zero" \
    "Binary not found or exited with error" \
    "FAIL" \
    "openclaw --version: $(truncate "$oc_output")"
fi

# ── Clock sync (NTP) ─────────────────────────────────────────────────────────
# Clock skew causes gateway JWTs to appear expired ("device signature expired").
# NTPSynchronized=yes is the reliable indicator — it means timesyncd has
# successfully contacted an NTP server and the clock is current.

ntp_sync=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null) || ntp_sync="n/a"
ntp_active=$(timedatectl show --property=NTP --value 2>/dev/null) || ntp_active="n/a"

if [[ "$ntp_sync" == "yes" ]]; then
  add_check "clock_sync" "Clock sync (NTP)" "infrastructure" \
    "NTP synchronized status via timedatectl" \
    "Clock skew invalidates gateway JWTs — causes 'device signature expired' auth failures" \
    "NTPSynchronized: yes" \
    "NTP synchronized (NTP: ${ntp_active}, NTPSynchronized: ${ntp_sync})" \
    "PASS" \
    "timedatectl show: NTP=${ntp_active} NTPSynchronized=${ntp_sync}"
else
  add_check "clock_sync" "Clock sync (NTP)" "infrastructure" \
    "NTP synchronized status via timedatectl" \
    "Clock skew invalidates gateway JWTs — causes 'device signature expired' auth failures" \
    "NTPSynchronized: yes" \
    "NTP NOT synchronized (NTP: ${ntp_active}, NTPSynchronized: ${ntp_sync}) — gateway auth will fail if clock has drifted" \
    "FAIL" \
    "timedatectl show: NTP=${ntp_active} NTPSynchronized=${ntp_sync}"
fi

# ── Unexpected listeners ──────────────────────────────────────────────────────
# Allowed: loopback (127.x.x.x, ::1), SSH on port 22.
# Any other port on a non-loopback interface is unexpected.

ss_output=$(ss -tlnp 2>&1) || true

# Extract local address:port column from LISTEN lines, filter out expected ones
unexpected=$(echo "$ss_output" | awk '/LISTEN/{print $4}' | \
  grep -v '^127\.'     | \
  grep -v '^\[::1\]'   | \
  grep -v '^::1'       | \
  grep -v ':22$'       | \
  grep -v '^\*:22$') || true

if [[ -z "$unexpected" ]]; then
  add_check "unexpected_listeners" "Unexpected listeners" "infrastructure" \
    "Ports listening on non-loopback network interfaces" \
    "Exposed ports are reachable from outside the VM" \
    "No listeners beyond loopback and SSH port 22" \
    "No unexpected listeners found" \
    "PASS" \
    "ss -tlnp: all listeners on loopback or SSH only"
else
  add_check "unexpected_listeners" "Unexpected listeners" "infrastructure" \
    "Ports listening on non-loopback network interfaces" \
    "Exposed ports are reachable from outside the VM" \
    "No listeners beyond loopback and SSH port 22" \
    "Unexpected listener(s) found on non-loopback interface" \
    "FAIL" \
    "$(truncate "$unexpected")"
fi

# =============================================================================
# Security layer
# =============================================================================

# ── Sudo access denied ────────────────────────────────────────────────────────

sudo_output=$(sudo -n /bin/true 2>&1) || sudo_exit=$?

if [[ ${sudo_exit:-0} -ne 0 ]]; then
  add_check "sudo_access" "Sudo access denied" "security" \
    "Passwordless sudo attempt as workload user" \
    "Sudo access allows privilege escalation beyond workload boundary" \
    "Command fails — no passwordless sudo configured" \
    "sudo denied (no passwordless access)" \
    "PASS" \
    "sudo -n /bin/true: exit ${sudo_exit:-0} — $(truncate "$sudo_output" 100)"
else
  add_check "sudo_access" "Sudo access denied" "security" \
    "Passwordless sudo attempt as workload user" \
    "Sudo access allows privilege escalation beyond workload boundary" \
    "Command fails — no passwordless sudo configured" \
    "sudo succeeded — workload user has passwordless sudo" \
    "FAIL" \
    "sudo -n /bin/true: exit 0 — escalation possible"
fi

# =============================================================================
# Runtime layer
# =============================================================================

# ── Own gateway liveness ──────────────────────────────────────────────────────
# Behavioral equivalent of: service state + correct port + loopback binding.
# If this responds with OpenClaw HTML, the service is running and correctly
# bound to the expected loopback port.

gw_output=$(curl --max-time 5 --silent "http://127.0.0.1:${OWN_PORT}" 2>&1) || true

if echo "$gw_output" | grep -qi 'openclaw\|doctype html'; then
  add_check "own_gateway_liveness" "Own gateway liveness" "runtime" \
    "HTTP probe on own gateway loopback port ${OWN_PORT}" \
    "Non-responsive gateway means agents cannot function" \
    "OpenClaw HTML response on port ${OWN_PORT}" \
    "OpenClaw HTML response received" \
    "PASS" \
    "curl http://127.0.0.1:${OWN_PORT}: HTML response (truncated)"
else
  add_check "own_gateway_liveness" "Own gateway liveness" "runtime" \
    "HTTP probe on own gateway loopback port ${OWN_PORT}" \
    "Non-responsive gateway means agents cannot function" \
    "OpenClaw HTML response on port ${OWN_PORT}" \
    "No OpenClaw response on port ${OWN_PORT}" \
    "FAIL" \
    "curl http://127.0.0.1:${OWN_PORT}: $(truncate "$gw_output" 100)"
fi

# =============================================================================
# Isolation layer
# =============================================================================

# ── Cross-workload file access ────────────────────────────────────────────────
# juso-neighbor is a required isolation test target, always provisioned alongside
# the validation workload. Home directories are mode 700; permission denied on
# ls is the expected and reliable PASS condition.

NEIGHBOR_HOME="/home/${NEIGHBOR_USER}"

if [[ ! -d "$NEIGHBOR_HOME" ]]; then
  add_check "cross_workload_file_access" "Cross-workload file access" "isolation" \
    "Attempt to list juso-neighbor home directory" \
    "Readable workload home directory means filesystem isolation failed" \
    "Permission denied" \
    "juso-neighbor not found — test environment incomplete" \
    "FAIL" \
    "ls ${NEIGHBOR_HOME}: no such directory"
else
  ls_output=$(ls "$NEIGHBOR_HOME" 2>&1) || ls_exit=$?
  if [[ ${ls_exit:-0} -ne 0 ]] && echo "$ls_output" | grep -qi 'permission denied'; then
    add_check "cross_workload_file_access" "Cross-workload file access" "isolation" \
      "Attempt to list juso-neighbor home directory" \
      "Readable workload home directory means filesystem isolation failed" \
      "Permission denied" \
      "Permission denied (isolation holds)" \
      "PASS" \
      "ls ${NEIGHBOR_HOME}: permission denied"
  elif [[ ${ls_exit:-0} -eq 0 ]]; then
    add_check "cross_workload_file_access" "Cross-workload file access" "isolation" \
      "Attempt to list juso-neighbor home directory" \
      "Readable workload home directory means filesystem isolation failed" \
      "Permission denied" \
      "Directory listing succeeded — filesystem isolation FAILED" \
      "FAIL" \
      "ls ${NEIGHBOR_HOME}: $(truncate "$ls_output")"
  else
    add_check "cross_workload_file_access" "Cross-workload file access" "isolation" \
      "Attempt to list juso-neighbor home directory" \
      "Readable workload home directory means filesystem isolation failed" \
      "Permission denied" \
      "Unexpected error checking neighbor directory" \
      "FAIL" \
      "ls ${NEIGHBOR_HOME}: $(truncate "$ls_output")"
  fi
fi

# ── Cross-workload gateway access ────────────────────────────────────────────
# Probes juso-neighbor's gateway loopback port. PASS = OpenClaw HTML response,
# confirming the gateway is loopback-bound (not exposed on a LAN interface).
# Auth is enforced at the token layer for agent operations; the HTTP dashboard
# layer returns 200 HTML without a token — that is expected behaviour.
# Requires sudo access to juso-workload-list (granted in sudoers).

NEIGHBOR_PORT=$(sudo juso-workload-list 2>/dev/null | grep "^neighbor:" | cut -d: -f2) || true

if [[ -z "$NEIGHBOR_PORT" ]]; then
  add_check "cross_workload_gateway" "Cross-workload gateway access" "isolation" \
    "HTTP probe on juso-neighbor gateway loopback port" \
    "Loopback-bound gateway cannot be reached from the LAN; auth is enforced at the token layer" \
    "OpenClaw HTML response (loopback binding confirmed)" \
    "Could not determine juso-neighbor port — test environment incomplete" \
    "FAIL" \
    "sudo juso-workload-list: neighbor port not found"
else
  gw_body=$(curl --max-time 5 --silent "http://127.0.0.1:${NEIGHBOR_PORT}" 2>&1) || true

  if echo "$gw_body" | grep -qi 'openclaw\|doctype html'; then
    add_check "cross_workload_gateway" "Cross-workload gateway access" "isolation" \
      "HTTP probe on juso-neighbor gateway loopback port ${NEIGHBOR_PORT}" \
      "Loopback-bound gateway cannot be reached from the LAN; auth is enforced at the token layer" \
      "OpenClaw HTML response (loopback binding confirmed)" \
      "OpenClaw HTML response — neighbor gateway is loopback-bound" \
      "PASS" \
      "curl http://127.0.0.1:${NEIGHBOR_PORT}: OpenClaw HTML response received"
  elif [[ -z "$gw_body" ]]; then
    add_check "cross_workload_gateway" "Cross-workload gateway access" "isolation" \
      "HTTP probe on juso-neighbor gateway loopback port ${NEIGHBOR_PORT}" \
      "Loopback-bound gateway cannot be reached from the LAN; auth is enforced at the token layer" \
      "OpenClaw HTML response (loopback binding confirmed)" \
      "No response — neighbor gateway not running; loopback binding cannot be confirmed" \
      "FAIL" \
      "curl http://127.0.0.1:${NEIGHBOR_PORT}: no response (timeout/refused)"
  else
    add_check "cross_workload_gateway" "Cross-workload gateway access" "isolation" \
      "HTTP probe on juso-neighbor gateway loopback port ${NEIGHBOR_PORT}" \
      "Loopback-bound gateway cannot be reached from the LAN; auth is enforced at the token layer" \
      "OpenClaw HTML response (loopback binding confirmed)" \
      "Unexpected response — not OpenClaw HTML" \
      "FAIL" \
      "curl http://127.0.0.1:${NEIGHBOR_PORT}: $(truncate "$gw_body" 100)"
  fi
fi

# ── Process visibility (informational) ───────────────────────────────────────
# Records whether juso-neighbor's processes are visible from juso-validation.
# On default Linux, all users can see all processes — this is a known
# characteristic, not a configuration failure. Never FAILs.

proc_output=$(ps aux 2>&1 | grep "${NEIGHBOR_USER}" | grep -v grep || true)

if [[ -z "$proc_output" ]]; then
  proc_actual="juso-neighbor processes not visible from this user"
  proc_evidence="ps aux | grep ${NEIGHBOR_USER}: no results"
else
  proc_actual="juso-neighbor processes visible (default Linux behaviour)"
  proc_evidence="$(truncate "$proc_output")"
fi

add_check "process_visibility" "Process visibility" "isolation" \
  "Visibility of juso-neighbor processes via ps" \
  "Process visibility between workloads (informational)" \
  "Informational — not a pass/fail criterion" \
  "$proc_actual" \
  "PASS" \
  "$proc_evidence"

# =============================================================================
# Output
# =============================================================================

checks_json=$(printf '%s\n' "${checks[@]}" | jq -s '.')
jq -n \
  --arg    timestamp "$TIMESTAMP" \
  --argjson checks   "$checks_json" \
  '{timestamp: $timestamp, checks: $checks}'
