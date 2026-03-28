#!/usr/bin/env bash
# provision-workload.sh
# Creates a Linux user and sets up a dedicated OpenClaw gateway instance for a workload.
# Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] <workload-name>
# Run from the repo root as juso-admin-vm.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/openclaw.json.template"
BEFORE_RULES="/etc/ufw/before.rules"
BASE_PORT=18789
RESERVED=("root" "juso" "juso-admin-vm" "daemon" "nobody" "sudo")

# ─── Parse arguments ─────────────────────────────────────────────────────────

INTERNET="none"
WORKLOAD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --internet=*)
      INTERNET="${1#--internet=}"
      shift
      ;;
    --internet)
      INTERNET="${2:-}"
      shift 2
      ;;
    -*)
      echo "Error: unknown option '$1'"
      echo "Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] <workload-name>"
      exit 1
      ;;
    *)
      WORKLOAD="$1"
      shift
      ;;
  esac
done

if [[ -z "$WORKLOAD" ]]; then
  echo "Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] <workload-name>"
  echo "Example: sudo ~/juso/scripts/provision-workload.sh --internet=open research"
  exit 1
fi

if [[ "$INTERNET" != "none" && "$INTERNET" != "open" ]]; then
  echo "Error: --internet must be 'none' or 'open' (got '${INTERNET}')."
  exit 1
fi

# ─── Validate workload name ───────────────────────────────────────────────────
# Lowercase letters, digits, hyphens only. Must start with a letter. Max 31 chars.

if ! [[ "$WORKLOAD" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "Error: workload name must use lowercase letters, digits, and hyphens only,"
  echo "       start with a letter, and be 31 characters or fewer."
  exit 1
fi

USER="juso-${WORKLOAD}"

for reserved in "${RESERVED[@]}"; do
  if [[ "$WORKLOAD" == "$reserved" || "$USER" == "$reserved" ]]; then
    echo "Error: '${WORKLOAD}' is a reserved name."
    exit 1
  fi
done

# ─── Idempotency: check if already provisioned ──────────────────────────────

EXISTING_PORT=""
if id "$USER" &>/dev/null; then
  CONFIG_CHECK="/home/${USER}/.openclaw/openclaw.json"
  if [[ -f "$CONFIG_CHECK" ]]; then
    EXISTING_PORT=$(jq -r '.gateway.port // empty' "$CONFIG_CHECK" 2>/dev/null) || true
  fi
fi

if [[ -n "$EXISTING_PORT" ]]; then
  echo "Workload '${WORKLOAD}' already provisioned on port ${EXISTING_PORT}."
  echo "Re-running remaining setup steps."
  PORT="$EXISTING_PORT"
else
  # ─── Assign port ───────────────────────────────────────────────────────────
  # Scan all existing workload configs for the highest allocated port.
  LAST_PORT=""
  for cfg in /home/juso-*/.openclaw/openclaw.json; do
    [[ -f "$cfg" ]] || continue
    p=$(jq -r '.gateway.port // empty' "$cfg" 2>/dev/null) || true
    if [[ -n "$p" ]] && [[ -z "$LAST_PORT" || "$p" -gt "$LAST_PORT" ]]; then
      LAST_PORT="$p"
    fi
  done

  if [[ -n "$LAST_PORT" ]]; then
    PORT=$((LAST_PORT + 20))
  else
    PORT=$BASE_PORT
  fi

  # Increment past any ports already in use
  while ss -tlnp | grep -q ":${PORT} "; do
    echo "Port ${PORT} in use, trying $((PORT + 1))..."
    PORT=$((PORT + 1))
  done
fi

echo ""
echo "==> Provisioning workload: ${WORKLOAD}"
echo "    Linux user : ${USER}"
echo "    Port       : ${PORT}"
echo "    Internet   : ${INTERNET}"
echo ""

# ─── Create Linux user ────────────────────────────────────────────────────────

if id "$USER" &>/dev/null; then
  echo "[skip] User ${USER} already exists"
else
  echo "[+] Creating user ${USER}..."
  useradd --create-home --shell /bin/bash --comment "juso workload ${WORKLOAD}" "$USER"
fi

# ─── Add user to juso-workloads group ────────────────────────────────────────
# This group is used by the sudoers rule that allows juso-admin-vm to open a
# shell as any workload user (juso-shell). groupadd is idempotent with --force.

echo "[+] Adding ${USER} to juso-workloads group..."
groupadd --force juso-workloads
usermod -aG juso-workloads "$USER"

# ─── Create .openclaw directory structure ────────────────────────────────────

echo "[+] Setting up ~/.openclaw directory structure..."
USER_HOME="/home/${USER}"
OPENCLAW_DIR="${USER_HOME}/.openclaw"

mkdir -p "${OPENCLAW_DIR}/workspace"
mkdir -p "${OPENCLAW_DIR}/memory"
chown -R "${USER}:${USER}" "${OPENCLAW_DIR}"

# ─── Create shared directory ──────────────────────────────────────────────────

if [[ -d "${USER_HOME}/shared" ]]; then
  echo "[skip] ${USER_HOME}/shared already exists"
else
  echo "[+] Creating ~/shared directory..."
  mkdir -p "${USER_HOME}/shared"
  chown "${USER}:${USER}" "${USER_HOME}/shared"
fi

# ─── Install audit.sh ────────────────────────────────────────────────────────
# Always overwrite — audit.sh must stay in sync with the repo on every provision.

AUDIT_SH_SRC="${SCRIPT_DIR}/audit.sh"
AUDIT_SH_DEST="/usr/local/bin/audit.sh"

if [[ ! -f "$AUDIT_SH_SRC" ]]; then
  echo "Error: audit.sh not found at ${AUDIT_SH_SRC}"
  exit 1
fi

echo "[+] Installing audit.sh to ${AUDIT_SH_DEST}..."
cp "$AUDIT_SH_SRC" "$AUDIT_SH_DEST"
chmod 755 "$AUDIT_SH_DEST"

# ─── Enable linger ───────────────────────────────────────────────────────────

echo "[+] Enabling linger for ${USER}..."
loginctl enable-linger "$USER"

# Start user systemd session so XDG_RUNTIME_DIR is available immediately
systemctl start "user@$(id -u "$USER").service" 2>/dev/null || true

# Wait for XDG_RUNTIME_DIR to be ready (created by user@UID.service)
USER_UID=$(id -u "$USER")
for i in $(seq 1 10); do
  [[ -d "/run/user/${USER_UID}" ]] && break
  sleep 1
done

if [[ ! -d "/run/user/${USER_UID}" ]]; then
  echo "Error: user session did not start within 10 seconds for ${USER}."
  exit 1
fi

# ─── Install gateway service ──────────────────────────────────────────────────

SERVICE_FILE="${USER_HOME}/.config/systemd/user/openclaw-gateway.service"
CONFIG="${OPENCLAW_DIR}/openclaw.json"

if [[ -f "$SERVICE_FILE" ]]; then
  echo "[skip] Gateway service already installed"
else
  echo "[+] Running openclaw gateway install as ${USER}..."
  sudo -u "$USER" bash -c "
    export HOME=${USER_HOME}
    export XDG_RUNTIME_DIR=/run/user/${USER_UID}
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
    openclaw gateway install --port ${PORT}
  "
fi

# ─── Write openclaw.json from template ───────────────────────────────────────
# This runs AFTER `openclaw gateway install` so that our template (which sets
# gateway.bind=loopback and other juso-specific values) wins. `gateway install`
# auto-generates a default config with gateway.bind=lan; if we wrote the
# template first it would be overwritten. Writing it second ensures our values
# are authoritative.
#
# Template context (comments removed from template to keep it valid JSON):
#   - Ollama runs on the Mac mini host at 192.168.64.1 (AVF virtual network address)
#   - native Ollama API (no /v1 path); tool calling is only reliable via native API
#   - memorySearch still uses /v1/ path — correct for embeddings only; provider
#     type must be "openai" (config validator rejects "ollama" as provider value)
#   - agents.list starts empty — agents are added after provisioning by add-agent.sh
#   - gateway binds to loopback only — never exposed on the VM network interface
#   - __PORT__ placeholder is replaced with the workload's assigned port below

if [[ -f "$CONFIG" && -n "$EXISTING_PORT" ]]; then
  echo "[skip] openclaw.json already exists (re-provision)"
else
  echo "[+] Writing openclaw.json from template (port ${PORT})..."
  sed "s/__PORT__/${PORT}/" "$TEMPLATE" > "$CONFIG"
  chown "${USER}:${USER}" "$CONFIG"
fi

# ─── Configure main agent workspace ──────────────────────────────────────────
# openclaw gateway install always adds a bare {"id":"main"} entry to agents.list.
# main is OpenClaw's hardcoded DEFAULT_AGENT_ID — it cannot be removed and is
# re-added by every `openclaw agents add` call. juso does not fight this; instead
# we configure main's workspace so it behaves as the primary conversational agent.

MAIN_WORKSPACE="${OPENCLAW_DIR}/workspace/main"

if [[ -d "$MAIN_WORKSPACE" ]]; then
  echo "[skip] main agent workspace already configured"
else
  echo "[+] Configuring main agent workspace..."
  mkdir -p "${MAIN_WORKSPACE}/memory"
  mkdir -p "${OPENCLAW_DIR}/agents/main/agent"
  mkdir -p "${OPENCLAW_DIR}/agents/main/sessions"
  chown -R "${USER}:${USER}" "${MAIN_WORKSPACE}"
  chown -R "${USER}:${USER}" "${OPENCLAW_DIR}/agents"

  # Update the bare {"id":"main"} entry in agents.list to add workspace path
  # and default:true. If main is absent (template cleared it), append a new entry.
  if jq -e '.agents.list[] | select(.id == "main")' "$CONFIG" > /dev/null 2>&1; then
    jq --arg ws "${MAIN_WORKSPACE}" \
      '.agents.list = [.agents.list[] | if .id == "main" then . + {"workspace": $ws, "default": true} else . end]' \
      "$CONFIG" > /tmp/openclaw_main.json
  else
    jq --arg ws "${MAIN_WORKSPACE}" \
      '.agents.list += [{"id": "main", "workspace": $ws, "default": true}]' \
      "$CONFIG" > /tmp/openclaw_main.json
  fi
  mv /tmp/openclaw_main.json "$CONFIG"
  chown "${USER}:${USER}" "$CONFIG"
fi

# ─── Per-workload internet access ────────────────────────────────────────────
# For --internet=open workloads, add a per-UID iptables ACCEPT rule to
# /etc/ufw/before.rules. This allows all outbound traffic for this workload's
# Linux user while the global UFW default deny outgoing remains in effect for
# all other users. The rule is inserted in the ufw-before-output chain before
# the final COMMIT line and survives reboots/UFW reloads.

RULE_MARKER="# juso-internet: ${WORKLOAD}"

if [[ "$INTERNET" == "open" ]]; then
  WORKLOAD_UID=$(id -u "$USER")
  if grep -qF "$RULE_MARKER" "$BEFORE_RULES" 2>/dev/null; then
    echo "[skip] Internet access rule already present in before.rules"
  else
    echo "[+] Adding internet access rule for ${USER} (UID ${WORKLOAD_UID})..."
    # Insert the rule + marker before the final COMMIT in the *filter section.
    # The COMMIT line we target is the last one in the file (end of *filter).
    sed -i "\$s|^COMMIT|${RULE_MARKER}\n-A ufw-before-output -m owner --uid-owner ${WORKLOAD_UID} -j ACCEPT\nCOMMIT|" "$BEFORE_RULES"
    echo "[+] Reloading UFW..."
    ufw reload
  fi
elif [[ "$INTERNET" == "none" ]]; then
  # Block DNS even on loopback so workloads cannot resolve external names via
  # systemd-resolved at 127.0.0.53. UFW's loopback ACCEPT rule fires before
  # the default-deny-outgoing policy, bypassing it entirely. An explicit
  # UID-based REJECT inserted before the loopback ACCEPT is the only mechanism
  # that intercepts this traffic.
  DNS_RULE_MARKER="# juso-nodns: ${WORKLOAD}"
  WORKLOAD_UID=$(id -u "$USER")
  if grep -qF "$DNS_RULE_MARKER" "$BEFORE_RULES" 2>/dev/null; then
    echo "[skip] DNS block rule already present in before.rules"
  else
    echo "[+] Adding DNS block rule for ${USER} (UID ${WORKLOAD_UID})..."
    sed -i "s|^-A ufw-before-output -o lo -j ACCEPT|${DNS_RULE_MARKER}\n-A ufw-before-output -m owner --uid-owner ${WORKLOAD_UID} -p udp --dport 53 -j REJECT\n-A ufw-before-output -m owner --uid-owner ${WORKLOAD_UID} -p tcp --dport 53 -j REJECT\n-A ufw-before-output -o lo -j ACCEPT|" "$BEFORE_RULES"
    echo "[+] Reloading UFW..."
    ufw reload
  fi
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Workload '${WORKLOAD}' provisioned."
echo ""
echo "    Port     : ${PORT}"
echo "    Internet : ${INTERNET}"
echo "    Config   : ${CONFIG}"
echo "    Service  : openclaw-gateway (user service for ${USER})"
echo ""
echo "    Next steps:"
echo "    1. Add agents    : sudo ~/juso/scripts/add-agent.sh ${WORKLOAD} <role>"
echo "       Agent IDs use role names only  e.g. ${WORKLOAD} collector"
echo "       Note: 'main' is configured automatically — do not add it manually."
echo "    2. Start gateway : sudo juso-ctl ${WORKLOAD} start"
echo ""
