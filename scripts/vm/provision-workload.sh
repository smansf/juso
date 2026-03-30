#!/usr/bin/env bash
# provision-workload.sh
# Creates a Linux user and sets up a dedicated OpenClaw gateway instance for a workload.
# Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>
# Run from the repo root as juso-admin-vm.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEFORE_RULES="/etc/ufw/before.rules"
BASE_PORT=18789
RESERVED=("root" "juso" "juso-admin-vm" "daemon" "nobody" "sudo")

# ─── Parse arguments ─────────────────────────────────────────────────────────

INTERNET="none"
MODEL_ID=""
CONTEXT_TOKENS=""
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
    --model-id=*)
      MODEL_ID="${1#--model-id=}"
      shift
      ;;
    --model-id)
      MODEL_ID="${2:-}"
      shift 2
      ;;
    --context-tokens=*)
      CONTEXT_TOKENS="${1#--context-tokens=}"
      shift
      ;;
    --context-tokens)
      CONTEXT_TOKENS="${2:-}"
      shift 2
      ;;
    -*)
      echo "Error: unknown option '$1'"
      echo "Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>"
      exit 1
      ;;
    *)
      WORKLOAD="$1"
      shift
      ;;
  esac
done

if [[ -z "$WORKLOAD" ]]; then
  echo "Usage: sudo ~/juso/scripts/provision-workload.sh [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>"
  echo "Example: sudo ~/juso/scripts/provision-workload.sh --internet=open --model-id qwen3:30b --context-tokens 32768 research"
  exit 1
fi

if [[ "$INTERNET" != "none" && "$INTERNET" != "open" ]]; then
  echo "Error: --internet must be 'none' or 'open' (got '${INTERNET}')."
  exit 1
fi

if [[ -z "$MODEL_ID" ]]; then
  echo "Error: --model-id is required. Specify the Ollama model to use (e.g. --model-id qwen3:30b)."
  exit 1
fi

if [[ -z "$CONTEXT_TOKENS" ]]; then
  echo "Error: --context-tokens is required. Specify the context window size (e.g. --context-tokens 32768)."
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
echo "    Linux user     : ${USER}"
echo "    Port           : ${PORT}"
echo "    Internet       : ${INTERNET}"
echo "    Model          : ${MODEL_ID}"
echo "    Context tokens : ${CONTEXT_TOKENS}"
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

# ─── Onboard openclaw, apply juso config, validate ───────────────────────────

SERVICE_FILE="${USER_HOME}/.config/systemd/user/openclaw-gateway.service"
CONFIG="${OPENCLAW_DIR}/openclaw.json"

if [[ -f "$SERVICE_FILE" ]]; then
  echo "[skip] Gateway already provisioned"
else
  echo "[+] Running openclaw onboard as ${USER}..."
  sudo -u "$USER" bash -c "
    export HOME=${USER_HOME}
    export XDG_RUNTIME_DIR=/run/user/${USER_UID}
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
    openclaw onboard \
      --non-interactive \
      --auth-choice ollama \
      --custom-base-url 'http://192.168.64.1:11434' \
      --custom-model-id '${MODEL_ID}' \
      --gateway-port ${PORT} \
      --gateway-bind loopback \
      --skip-skills \
      --install-daemon \
      --accept-risk
  "

  echo "[+] Applying juso configuration..."
  sudo -u "$USER" bash -c "
    export HOME=${USER_HOME}

    echo '  [1/18] models.mode = merge  (preserve onboard channel settings alongside juso overrides)'
    openclaw config set models.mode merge

    echo '  [2/18] agents.defaults.model.primary = ollama/${MODEL_ID}'
    openclaw config set agents.defaults.model.primary 'ollama/${MODEL_ID}'

    echo '  [3/18] agents.defaults.contextTokens = ${CONTEXT_TOKENS}  (match Ollama model context window)'
    openclaw config set --strict-json agents.defaults.contextTokens ${CONTEXT_TOKENS}

    echo '  [4/18] tools.profile = default  (coding profile includes apply_patch/image which are unavailable with Ollama)'
    openclaw config set tools.profile default

    echo '  [5/18] agents.defaults.memorySearch.enabled = true'
    openclaw config set --strict-json agents.defaults.memorySearch.enabled true

    echo '  [6/18] agents.defaults.memorySearch.provider = openai  (Ollama exposes an OpenAI-compatible embedding API)'
    openclaw config set agents.defaults.memorySearch.provider openai

    echo '  [7/18] agents.defaults.memorySearch.model = nomic-embed-text  (local embedding model pulled via Ollama)'
    openclaw config set agents.defaults.memorySearch.model nomic-embed-text

    echo '  [8/18] agents.defaults.memorySearch.remote.baseUrl = http://192.168.64.1:11434/v1/  (Ollama on host machine, reachable from VM)'
    openclaw config set agents.defaults.memorySearch.remote.baseUrl 'http://192.168.64.1:11434/v1/'

    echo '  [9/18] agents.defaults.memorySearch.remote.apiKey = ollama-local  (placeholder; local Ollama requires no auth)'
    openclaw config set agents.defaults.memorySearch.remote.apiKey 'ollama-local'

    echo '  [10/18] agents.defaults.memorySearch.query.hybrid.enabled = true  (blend vector similarity with keyword search)'
    openclaw config set --strict-json agents.defaults.memorySearch.query.hybrid.enabled true

    echo '  [11/18] agents.defaults.memorySearch.query.hybrid.vectorWeight = 0.7  (70% vector, 30% keyword)'
    openclaw config set --strict-json agents.defaults.memorySearch.query.hybrid.vectorWeight 0.7

    echo '  [12/18] agents.defaults.memorySearch.query.hybrid.textWeight = 0.3'
    openclaw config set --strict-json agents.defaults.memorySearch.query.hybrid.textWeight 0.3

    echo '  [13/18] agents.defaults.memorySearch.query.hybrid.candidateMultiplier = 4  (retrieve 4x candidates before reranking)'
    openclaw config set --strict-json agents.defaults.memorySearch.query.hybrid.candidateMultiplier 4

    echo '  [14/18] agents.defaults.memorySearch.store.path = ~/.openclaw/memory/{agentId}.sqlite  (per-agent SQLite store)'
    openclaw config set agents.defaults.memorySearch.store.path '~/.openclaw/memory/{agentId}.sqlite'

    echo '  [15/18] agents.defaults.compaction.mode = safeguard  (flush memory before compacting context)'
    openclaw config set agents.defaults.compaction.mode safeguard

    echo '  [16/18] agents.defaults.compaction.memoryFlush.enabled = true'
    openclaw config set --strict-json agents.defaults.compaction.memoryFlush.enabled true

    echo '  [17/18] agents.defaults.compaction.memoryFlush.softThresholdTokens = 4000  (trigger flush at 4000 tokens remaining)'
    openclaw config set --strict-json agents.defaults.compaction.memoryFlush.softThresholdTokens 4000

    echo '  [18/18] skills.allowBundled = []  (no bundled skills; juso controls tool access via workspace files)'
    openclaw config set --strict-json skills.allowBundled '[]'
  "
  chown "${USER}:${USER}" "$CONFIG"

  echo "[+] Validating with openclaw doctor..."
  sudo -u "$USER" bash -c "
    export HOME=${USER_HOME}
    export XDG_RUNTIME_DIR=/run/user/${USER_UID}
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus
    openclaw doctor --non-interactive
  "
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
echo "    Port           : ${PORT}"
echo "    Internet       : ${INTERNET}"
echo "    Model          : ${MODEL_ID}"
echo "    Context tokens : ${CONTEXT_TOKENS}"
echo "    Config         : ${CONFIG}"
echo "    Service        : openclaw-gateway (user service for ${USER})"
echo ""
echo "    Next steps:"
echo "    1. Add agents    : sudo ~/juso/scripts/add-agent.sh ${WORKLOAD} <role>"
echo "       Agent IDs use role names only  e.g. ${WORKLOAD} collector"
echo "       Note: 'main' is configured automatically — do not add it manually."
echo "    2. Start gateway : sudo juso-ctl ${WORKLOAD} start"
echo ""
