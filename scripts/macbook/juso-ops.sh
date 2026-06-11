#!/usr/bin/env bash
# juso-ops.sh — Shell functions for juso management from the MacBook Pro.
# Activate: source <repo-path>/scripts/macbook/juso-ops.sh from ~/.zshrc.
# ─────────────────────────────────────────────────────────────────────────────
# OLLAMA
# ─────────────────────────────────────────────────────────────────────────────

# Check Ollama on the Mac mini.
function juso-status-ollama() {
  ssh -o ConnectTimeout=3 mini \
    "curl -s http://192.168.64.1:11434/api/version" \
    2>/dev/null || echo "✗ ollama unreachable"
}

# Start Ollama on the Mac mini via the com.juso.ollama-serve LaunchAgent.
# The LaunchAgent binds to 192.168.64.1 (VM-accessible). Starting via
# 'open -a Ollama' binds to 127.0.0.1 (loopback only) and must not be used.
function juso-start-ollama() {
  echo "Starting Ollama on Mac mini (LaunchAgent)..."
  ssh mini 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.juso.ollama-serve.plist'
  echo "  Allow a few seconds for Ollama to become ready."
}

# Stop Ollama on the Mac mini via the com.juso.ollama-serve LaunchAgent.
function juso-stop-ollama() {
  echo "Stopping Ollama on Mac mini (LaunchAgent)..."
  ssh mini 'launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.juso.ollama-serve.plist'
}

# ─────────────────────────────────────────────────────────────────────────────
# VM
# NOTE: stopping the VM works over SSH (systemctl poweroff inside the VM).
#       Starting requires a local GUI session on the Mac mini — utmctl does not
#       work over SSH. The VM starts automatically on juso login via UTM
#       auto-start; manual start requires Screen Sharing.
# ─────────────────────────────────────────────────────────────────────────────

# Check VM reachability.
function juso-status-vm() {
  ssh -o ConnectTimeout=3 vm "echo '✓ vm is up'" \
    2>/dev/null || echo "✗ vm stopped or unreachable"
}

# Start the VM on the Mac mini.
# Cannot be done over SSH — utmctl requires a local GUI session.
# The VM starts automatically when juso logs in on the Mac mini.
# To start manually: connect via Screen Sharing and use UTM.
function juso-start-vm() {
  echo "Cannot start VM over SSH — utmctl requires a local GUI session."
  echo "The VM starts automatically when juso logs in on the Mac mini."
  echo "To start manually: connect via Screen Sharing and use UTM."
}

# Stop the VM on the Mac mini via a graceful poweroff issued from inside the VM.
# systemctl poweroff returns 0 before shutdown begins, so SSH exits cleanly.
# Reachability is checked first so failures surface clearly rather than being
# swallowed by a blanket || true.
function juso-stop-vm() {
  echo "Stopping VM (graceful poweroff)..."
  if ! ssh -o ConnectTimeout=5 vm "echo ok" >/dev/null 2>&1; then
    echo "  ✗ VM unreachable — already stopped?" >&2
    return 1
  fi
  if ! ssh vm "sudo systemctl poweroff"; then
    echo "  ✗ poweroff command failed — check VM sudoers (juso-admin-vm needs NOPASSWD: /usr/bin/systemctl poweroff)" >&2
    return 1
  fi
  echo "  Poweroff command sent. VM will stop within a few seconds."
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKLOADS
# ─────────────────────────────────────────────────────────────────────────────

# List all provisioned workloads and their gateway ports.
function juso-list() {
  local output
  output=$(ssh vm "sudo juso-workload-list")
  if [[ -z "$output" ]]; then
    echo "(no workloads provisioned)"
  else
    echo "$output"
  fi
}

# Provision a new workload.
# Usage: juso-provision [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>
function juso-provision() {
  if [[ -z "${1:-}" ]]; then
    echo "Usage: juso-provision [--internet=none|open] --model-id <model> --context-tokens <n> <workload-name>"
    return 1
  fi
  ssh vm "sudo ~/juso/scripts/provision-workload.sh $*"
}

# Destroy a workload and all its data. This operation is irreversible.
# Without --force: prompts for workload name confirmation (safe interactive use).
# With --force: skips confirmation (for scripted provisioning).
# Usage: juso-destroy [--force] <workload-name>
function juso-destroy() {
  local workload=""
  local force_flag=""
  for arg in "$@"; do
    case "$arg" in
      --force) force_flag="--force" ;;
      *) workload="$arg" ;;
    esac
  done
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-destroy [--force] <workload-name>"
    return 1
  fi
  if [[ -n "$force_flag" ]]; then
    ssh vm "sudo ~/juso/scripts/destroy-workload.sh --force ${workload}"
  else
    ssh -t vm "sudo ~/juso/scripts/destroy-workload.sh ${workload}"
  fi
}

# Start the OpenClaw gateway for a workload.
# Usage: juso-start-workload <workload-name>
function juso-start-workload() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-start-workload <workload-name>"
    return 1
  fi
  echo "Starting workload: ${workload}..."
  ssh vm "sudo juso-ctl ${workload} start"
  ssh vm "sudo juso-ctl ${workload} is-active"
}

# Stop the OpenClaw gateway for a workload.
# Usage: juso-stop-workload <workload-name>
function juso-stop-workload() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-stop-workload <workload-name>"
    return 1
  fi
  echo "Stopping workload: ${workload}..."
  ssh vm "sudo juso-ctl ${workload} stop"
  # juso-ctl is-active exits 3 for inactive (systemctl is-active convention).
  # Capture output without propagating the non-zero exit so set -e callers
  # don't bail before we can check the string value.
  local svc_status
  svc_status=$(ssh vm "sudo juso-ctl ${workload} is-active" 2>/dev/null) || true
  if [[ "$svc_status" == "inactive" ]]; then
    echo "  ✓ ${workload}: stopped"
  else
    echo "  ✗ ${workload}: unexpected state after stop: ${svc_status}"
    return 1
  fi
}

# Grant the workload's CLI device the specified gateway operator scopes.
# Must be called after the workload gateway is running. Required for any
# workload that dispatches agents via CLI (openclaw agent ...) rather than
# the dashboard. Retries up to 5 times to allow for device registration lag.
#
# Scopes are gateway-level — they control what the CLI device can do at the
# gateway API, independent of agent tool permissions (tools.profile).
# Least-privilege defaults (operator.read + operator.write) cover all
# unattended dispatch use cases. Add operator.admin only if the workload
# needs direct system.run access outside an agent session.
#
# Usage: juso-pair-cli-device <workload> [scope ...]
# Default scopes: operator.read operator.write
function juso-pair-cli-device() {
  local workload="${1:-}"
  shift 2>/dev/null || true
  local -a scopes=("$@")

  if [[ -z "$workload" ]]; then
    echo "Usage: juso-pair-cli-device <workload> [scope ...]"
    echo "       Default scopes: operator.read operator.write"
    return 1
  fi

  if [[ ${#scopes[@]} -eq 0 ]]; then
    scopes=(operator.read operator.write)
  fi

  local scope_flags=""
  for scope in "${scopes[@]}"; do
    scope_flags+=" --scope ${scope}"
  done

  echo "  pairing CLI device for ${workload} [${scopes[*]}]"

  # shellcheck disable=SC2087  # Heredoc intentionally mixes Mac-side (${workload}) and VM-side (\$device_id) expansions.
  ssh vm bash -s <<SSHEOF
for attempt in 1 2 3 4 5; do
  device_id=\$(sudo -u ${workload} bash -c 'export HOME=/home/${workload}; openclaw devices list --json 2>/dev/null' | jq -r '.paired[0].deviceId // empty')
  [[ -n "\$device_id" ]] && break
  echo "    attempt \${attempt}/5: waiting for device registration..."
  sleep 2
done
if [[ -z "\$device_id" ]]; then
  echo "  ✗ no device found after 5 attempts — is the gateway running?"
  exit 1
fi
echo "  device: \$device_id"
# On first provision the device is pending (no prior approved device exists).
# Approve it first so rotate can authenticate to the gateway. Safe to call
# when already approved — no pending devices means no-op.
sudo -u ${workload} bash -c 'export HOME=/home/${workload}; openclaw devices approve' 2>/dev/null || true
# rotate sets exactly the specified scopes — no more, no less. Called after
# approve so the device holds a valid token and can authenticate.
sudo -u ${workload} bash -c "export HOME=/home/${workload}; openclaw devices rotate --device \"\$device_id\" --role operator${scope_flags}" \
  && echo "  ✓ device scopes set: ${scopes[*]}"
SSHEOF
}

# Write or update a single secret key in ~/.openclaw/.env on the VM.
# Prompts interactively; value is not echoed. Creates the file if absent.
# Value flows via stdin so it never appears in process arguments or logs.
# Usage: juso-write-secret <workload> <KEY>
function juso-write-secret() {
  local workload="${1:-}"
  local key="${2:-}"
  if [[ -z "$workload" || -z "$key" ]]; then
    echo "Usage: juso-write-secret <workload> <KEY>" >&2
    return 1
  fi
  local value
  read -rsp "  ${key}: " value
  echo
  if [[ -z "$value" ]]; then
    echo "error: ${key}: value must not be empty" >&2
    return 1
  fi
  local env_file="/home/${workload}/.openclaw/.env"
  vm-exec "$workload" "mkdir -p /home/${workload}/.openclaw && touch ${env_file} && chmod 600 ${env_file}"
  printf '%s=%s\n' "$key" "$value" \
    | vm-exec "$workload" "grep -v '^${key}=' ${env_file} >${env_file}.tmp 2>/dev/null; cat >>${env_file}.tmp; mv ${env_file}.tmp ${env_file}; chmod 600 ${env_file}"
  echo "  ✓ ${key} written"
}

# Check whether a secret key is set (non-empty) in ~/.openclaw/.env on the VM.
# Returns 0 if present, 1 if absent or empty. Silent — callers format the error.
# Usage: juso-check-secret <workload> <KEY>
function juso-check-secret() {
  local workload="${1:-}"
  local key="${2:-}"
  if [[ -z "$workload" || -z "$key" ]]; then
    echo "Usage: juso-check-secret <workload> <KEY>" >&2
    return 1
  fi
  vm-exec "$workload" "grep -q '^${key}=.' /home/${workload}/.openclaw/.env 2>/dev/null"
}

# Patch channels.telegram in openclaw.json for a workload.
# Requires TELEGRAM_BOT_TOKEN to already be set via juso-write-secret — enforced
# as a precondition to prevent the gateway starting with an unresolvable SecretRef.
# A gateway restart is required after running this command for the change to take effect.
# Usage: juso-configure-telegram <workload> --allowlist "<user IDs>" [--groups "<group IDs>"] [--ack-reaction <emoji>]
function juso-configure-telegram() {
  local workload=""
  local allowlist=""
  local groups=""
  local ack_reaction=""
  local next_is_allowlist=false
  local next_is_groups=false
  local next_is_ack=false

  for arg in "$@"; do
    case "$arg" in
      --allowlist) next_is_allowlist=true ;;
      --groups) next_is_groups=true ;;
      --ack-reaction) next_is_ack=true ;;
      *)
        if $next_is_allowlist; then
          allowlist="$arg"
          next_is_allowlist=false
        elif $next_is_groups; then
          groups="$arg"
          next_is_groups=false
        elif $next_is_ack; then
          ack_reaction="$arg"
          next_is_ack=false
        elif [[ -z "$workload" ]]; then
          workload="$arg"
        fi
        ;;
    esac
  done

  if [[ -z "$workload" || -z "$allowlist" ]]; then
    echo "Usage: juso-configure-telegram <workload> --allowlist \"<user IDs>\" [--groups \"<group IDs>\"] [--ack-reaction <emoji>]"
    return 1
  fi

  local allowlist_json groups_json
  allowlist_json=$(jq -n --arg ids "$allowlist" '$ids | split(" ") | map(select(. != "") | tonumber)')
  groups_json=$(jq -n --arg ids "$groups" '$ids | split(" ") | map(select(. != "")) | map({(.): {"requireMention": false}}) | add // {}')

  if ! juso-check-secret "$workload" TELEGRAM_BOT_TOKEN; then
    echo "error: TELEGRAM_BOT_TOKEN is not set in ~/.openclaw/.env" >&2
    echo "       Run: juso-write-secret ${workload} TELEGRAM_BOT_TOKEN" >&2
    return 1
  fi

  juso-config-set "$workload" 'channels.telegram.enabled' 'true' --strict-json
  juso-config-set "$workload" 'channels.telegram.botToken' \
    '{"source":"env","provider":"default","id":"TELEGRAM_BOT_TOKEN"}' --strict-json
  juso-config-set "$workload" 'channels.telegram.dmPolicy' 'allowlist'
  juso-config-set "$workload" 'channels.telegram.allowFrom' "$allowlist_json" --strict-json
  juso-config-set "$workload" 'channels.telegram.groups' "$groups_json" --strict-json
  if [[ -n "$ack_reaction" ]]; then
    juso-config-set "$workload" 'channels.telegram.ackReaction' "$ack_reaction"
  fi

  echo "  ✓ channels.telegram configured (token resolved from ~/.openclaw/.env via SecretRef)"
  echo "  Restart the gateway to apply: juso-stop-workload ${workload} && juso-start-workload ${workload}"
}

# Check the OpenClaw gateway status for a workload.
# Usage: juso-status-workload <workload-name>
function juso-status-workload() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-status-workload <workload-name>"
    return 1
  fi
  ssh -o ConnectTimeout=3 vm \
    "sudo juso-ctl ${workload} status" \
    2>/dev/null || echo "✗ VM unreachable"
}

# Open an interactive shell as a workload user on the VM.
# Lands in the workload user's home directory (/home/<workload>).
# From there: ~/.openclaw/workspace/<agent>/ and ~/shared/ are directly accessible.
# Usage: juso-shell <workload-name>
function juso-shell() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-shell <workload>"
    return 1
  fi
  ssh -t vm "sudo -i -u ${workload}"
}

# ─────────────────────────────────────────────────────────────────────────────
# AGENTS
# ─────────────────────────────────────────────────────────────────────────────

# Add an agent to a workload. Runs the OpenClaw agent creation wizard interactively.
# Usage: juso-add-agent <workload-name> <agent-name> [--non-interactive]
function juso-add-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-add-agent <workload-name> <agent-name> [--non-interactive]"
    return 1
  fi
  local extra_flags="${3:-}"
  if [[ "${extra_flags}" == "--non-interactive" ]]; then
    ssh vm "sudo ~/juso/scripts/add-agent.sh --non-interactive ${workload} ${agent}"
  else
    ssh -t vm "sudo ~/juso/scripts/add-agent.sh ${workload} ${agent}"
  fi
}

# Push agent workspace files to the VM.
# By default, pushes top-level files only (definition files: SOUL.md, AGENTS.md, etc.).
# Use --all to push everything including subdirectories (work products).
# Never deletes files on the destination — agent runtime files are left untouched.
# MEMORY.md is excluded from the push if it already exists on the VM, preserving
# the agent's accumulated memory. If absent (fresh provision), it is pushed as normal.
# To remove a stale file manually:
#   ssh vm "sudo rm /home/<workload>/.openclaw/workspace/<agent>/<file>"
# Run from your workloads repo root.
# Usage: juso-push-agent <workload-name> <agent-name> [--all] [--agents-dir <subdir>]
function juso-push-agent() {
  local workload=""
  local agent=""
  local all=false
  local agents_dir=""
  local next_agents_dir=false

  for arg in "$@"; do
    case "$arg" in
      --all) all=true ;;
      --agents-dir) next_agents_dir=true ;;
      *)
        if $next_agents_dir; then
          agents_dir="$arg"
          next_agents_dir=false
        elif [[ -z "$workload" ]]; then
          workload="$arg"
        elif [[ -z "$agent" ]]; then
          agent="$arg"
        fi
        ;;
    esac
  done

  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-push-agent <workload-name> <agent-name> [--all] [--agents-dir <subdir>]"
    return 1
  fi

  local role="${agent#${workload}-}"
  local source
  if [[ -n "$agents_dir" ]]; then
    source="${workload}/${agents_dir}/${role}"
  else
    source="${workload}/${role}"
  fi

  if [[ ! -d "$source" ]]; then
    echo "Error: '${source}' not found. Run from your workloads repo root."
    return 1
  fi

  local dest="vm:/home/${workload}/.openclaw/workspace/${agent}/"
  local rsync_path="sudo -u ${workload} rsync"

  local memory_exclude=()
  if ssh vm "sudo -u ${workload} test -f /home/${workload}/.openclaw/workspace/${agent}/MEMORY.md" 2>/dev/null; then
    memory_exclude=(--exclude=MEMORY.md)
  fi

  if $all; then
    rsync -av --rsync-path="${rsync_path}" "${memory_exclude[@]+"${memory_exclude[@]}"}" "${source}/" "${dest}"
  else
    rsync -av --rsync-path="${rsync_path}" --exclude='*/' "${memory_exclude[@]+"${memory_exclude[@]}"}" "${source}/" "${dest}"
  fi
}

# Pull agent workspace files from the VM.
# Pulls definition files and work products. Excludes OpenClaw internal state
# files (.openclaw/) that are runtime-generated and should not enter the repo.
# Always pull before pushing to avoid overwriting agent-evolved files.
# Run from your workloads repo root.
# Usage: juso-pull-agent <workload-name> <agent-name> [--agents-dir <subdir>]
function juso-pull-agent() {
  local workload=""
  local agent=""
  local agents_dir=""
  local next_agents_dir=false

  for arg in "$@"; do
    case "$arg" in
      --agents-dir) next_agents_dir=true ;;
      *)
        if $next_agents_dir; then
          agents_dir="$arg"
          next_agents_dir=false
        elif [[ -z "$workload" ]]; then
          workload="$arg"
        elif [[ -z "$agent" ]]; then
          agent="$arg"
        fi
        ;;
    esac
  done

  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-pull-agent <workload-name> <agent-name> [--agents-dir <subdir>]"
    return 1
  fi

  local role="${agent#${workload}-}"
  local dest
  if [[ -n "$agents_dir" ]]; then
    dest="${workload}/${agents_dir}/${role}"
  else
    dest="${workload}/${role}"
  fi

  if [[ ! -d "$dest" ]]; then
    echo "Error: '${dest}' not found. Run from your workloads repo root."
    return 1
  fi

  local source="vm:/home/${workload}/.openclaw/workspace/${agent}/"
  rsync -av --rsync-path="sudo -u ${workload} rsync" --exclude='.openclaw/' "${source}" "${dest}/"
}

# Pull workload shared data from the VM.
# Pulls the entire ~/shared/ directory from the VM.
# Run from your workloads repo root.
# Usage: juso-pull-shared <workload-name>
function juso-pull-shared() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-pull-shared <workload-name>"
    return 1
  fi
  local dest="${workload}/shared"
  if [[ ! -d "$dest" ]]; then
    echo "Error: '${dest}' not found. Run from your workloads repo root."
    return 1
  fi
  local source="vm:/home/${workload}/shared/"
  rsync -av --checksum --rsync-path="sudo -u ${workload} rsync" "${source}" "${dest}/"
}

# Clean local workload artifacts before a redeploy.
# Removes generated files that will be regenerated by the next agent run:
#   - <workload>/shared/         (all agent work products)
#   - <workload>/*/memory/*.md   (session memory for all agents)
# Safe to run on an empty or partial tree — missing paths are skipped.
# Run from your workloads repo root.
# Usage: juso-clean-local <workload-name>
function juso-clean-local() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-clean-local <workload-name>"
    return 1
  fi

  echo "Cleaning local artifacts for workload: ${workload}..."

  local cleaned=0

  if [[ -d "${workload}/shared" ]]; then
    rm -rf "${workload}/shared"
    echo "  [+] Removed ${workload}/shared/"
    cleaned=$((cleaned + 1))
  else
    echo "  [skip] ${workload}/shared/ not found"
  fi

  local mem_count
  mem_count=$(find "${workload}" -path "*/memory/*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$mem_count" -gt 0 ]]; then
    find "${workload}" -path "*/memory/*.md" -delete
    echo "  [+] Removed ${mem_count} memory file(s) under ${workload}/*/memory/"
    cleaned=$((cleaned + 1))
  else
    echo "  [skip] No memory files found under ${workload}/*/memory/"
  fi

  echo "Done. (${cleaned}/2 directories had content to remove)"
}

# Remove an agent from a workload. This operation is irreversible.
# Usage: juso-remove-agent <workload-name> <agent-name>
function juso-remove-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-remove-agent <workload-name> <agent-name>"
    return 1
  fi
  ssh -t vm "sudo ~/juso/scripts/remove-agent.sh ${workload} ${agent}"
}

# Clear session transcripts for a workload's agents.
# Removes *.jsonl and sessions.json from /home/<workload>/.openclaw/agents/<agent>/sessions/.
# Without an agent argument, clears sessions for all agents in the workload.
# With an agent argument, clears only that agent's sessions.
# Usage: juso-clear-sessions <workload-name> [agent-name]
function juso-clear-sessions() {
  local workload="${1:-}"
  local agent="${2:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-clear-sessions <workload-name> [agent-name]"
    return 1
  fi
  if [[ -n "$agent" ]]; then
    local sessions="/home/${workload}/.openclaw/agents/${agent}/sessions"
    ssh vm "sudo -u ${workload} bash -c 'rm -f ${sessions}/*.jsonl ${sessions}/sessions.json 2>/dev/null; true'"
    echo "Cleared sessions for ${workload}/${agent}"
  else
    local sessions_base="/home/${workload}/.openclaw/agents"
    ssh vm "sudo -u ${workload} bash -c 'rm -f ${sessions_base}/*/sessions/*.jsonl ${sessions_base}/*/sessions/sessions.json 2>/dev/null; true'"
    echo "Cleared sessions for all agents in ${workload}"
  fi
}

# Wipe an agent's session transcripts and per-session memory logs.
# With --reset-memory: also wipes MEMORY.md (OpenClaw's standard long-term
# memory file). Other workload-specific evolved files (LESSONS.md, scratch
# dirs, etc.) are the workload's responsibility — this atom keeps a narrow,
# OpenClaw-convention-only scope.
# Usage: juso-wipe-agent <workload> <agent> [--reset-memory]
function juso-wipe-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  local reset_memory=false
  shift 2 2>/dev/null || true
  for arg in "$@"; do
    case "$arg" in
      --reset-memory) reset_memory=true ;;
      *)
        echo "Unknown flag: $arg" >&2
        return 1
        ;;
    esac
  done
  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-wipe-agent <workload> <agent> [--reset-memory]" >&2
    return 1
  fi
  local sessions="/home/${workload}/.openclaw/agents/${agent}/sessions"
  local workspace="/home/${workload}/.openclaw/workspace/${agent}"
  ssh vm "sudo -u ${workload} bash -c '
    rm -f ${sessions}/*.jsonl ${sessions}/sessions.json 2>/dev/null
    rm -f ${workspace}/memory/*.md 2>/dev/null
    true
  '"
  if $reset_memory; then
    ssh vm "sudo -u ${workload} bash -c 'rm -f ${workspace}/MEMORY.md'"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DASHBOARD
# ─────────────────────────────────────────────────────────────────────────────

# Open the OpenClaw dashboard for a workload.
# Opens an SSH tunnel, retrieves the dashboard token URL, and launches the browser.
# The token travels over the encrypted SSH tunnel and is never stored on the MacBook.
# Usage: juso-dashboard <workload-name>
function juso-dashboard() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-dashboard <workload-name>"
    echo "Run juso-list to see available workloads."
    return 1
  fi
  local port
  port=$(ssh vm "sudo juso-workload-list | grep '^${workload}:' | cut -d: -f2")
  if [[ -z "$port" ]]; then
    echo "Unknown workload: $workload. Run juso-list to see available workloads."
    return 1
  fi
  ssh -fN -L "${port}:localhost:${port}" vm

  local token_url
  token_url=$(ssh vm "sudo -u ${workload} openclaw dashboard 2>/dev/null" | grep -o 'http://[^ ]*') || true

  if [[ -n "$token_url" ]]; then
    local local_url="${token_url//127.0.0.1/localhost}"
    echo "Opening dashboard with token: ${local_url}"
    open "$local_url"
  else
    echo "Could not retrieve dashboard token. Opening without token."
    echo "Retrieve manually: ssh vm 'sudo -u ${workload} openclaw dashboard'"
    open "http://localhost:${port}"
  fi
}

# Close the dashboard tunnel for a workload, or all dashboard tunnels if no argument given.
# Usage: juso-dashboard-stop [workload-name]
function juso-dashboard-stop() {
  local workload="${1:-}"
  if [[ -n "$workload" ]]; then
    local port
    port=$(ssh vm "sudo juso-workload-list | grep '^${workload}:' | cut -d: -f2")
    pkill -f "ssh.*${port}:localhost:${port}" 2>/dev/null || true
  else
    # Prefix-matches all juso gateway ports (BASE_PORT 18789+)
    pkill -f "ssh.*:localhost:187" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

# Run a command on the VM as the workload user. Output to stdout, exit code
# propagates. The command is a single string (multi-line via heredoc on the
# caller side); stdin is passed through, so callers may pipe content in.
# Usage: vm-exec <workload> <command> [args...]
function vm-exec() {
  local workload="${1:-}"
  shift 2>/dev/null || true
  if [[ -z "$workload" || $# -eq 0 ]]; then
    echo "Usage: vm-exec <workload> <command> [args...]" >&2
    return 1
  fi
  local cmd="$*"
  ssh vm "sudo -u ${workload} bash -c $(printf '%q' "$cmd")"
}

# Push the workload's scripts/ tree to the VM with kernel-ACL ownership.
# Stages content under /tmp/juso-push-staging-<workload>/ (workload-user
# rsync) then invokes the receiver as root via sudo. Receiver applies the
# kernel-ACL ownership matrix and cleans up staging on success.
# Run from your workloads repo root.
# Usage: juso-push-scripts <workload>
function juso-push-scripts() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-push-scripts <workload>" >&2
    return 1
  fi
  local source="${workload}/scripts"
  if [[ ! -d "$source" ]]; then
    echo "Error: '${source}' not found. Run from your workloads repo root." >&2
    return 1
  fi
  local staging="/tmp/juso-push-staging-${workload}"
  ssh vm "sudo -u ${workload} bash -c 'rm -rf ${staging} && mkdir -p ${staging}'"
  rsync -a --rsync-path="sudo -u ${workload} rsync" "${source}/" "vm:${staging}/"
  ssh vm "sudo /usr/local/bin/juso-rsync-scripts ${workload}"
}

# Set a single field in the workload's openclaw.json. Simple-path mode only;
# complex jq operations are the workload's concern (write a helper in your
# ops/ tier and invoke via juso-ops-exec).
# Usage: juso-config-set <workload> <jq-path> <value> [--strict-json]
function juso-config-set() {
  local workload="${1:-}"
  local path="${2:-}"
  local value="${3:-}"
  local strict="${4:-}"
  if [[ -z "$workload" || -z "$path" || -z "$value" ]]; then
    echo "Usage: juso-config-set <workload> <jq-path> <value> [--strict-json]" >&2
    return 1
  fi
  if [[ -n "$strict" && "$strict" != "--strict-json" ]]; then
    echo "Unknown flag: $strict" >&2
    return 1
  fi
  ssh vm "sudo /usr/local/bin/juso-config-set $(printf '%q' "$workload") $(printf '%q' "$path") $(printf '%q' "$value") ${strict}"
}

# Execute a script in the workload's ops/ tier as root.
# Usage: juso-ops-exec <workload> <ops-script-name> [args...]
function juso-ops-exec() {
  local workload="${1:-}"
  local script="${2:-}"
  shift 2 2>/dev/null || true
  if [[ -z "$workload" || -z "$script" ]]; then
    echo "Usage: juso-ops-exec <workload> <ops-script-name> [args...]" >&2
    return 1
  fi
  local args=""
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  ssh vm "sudo /usr/local/bin/juso-ops-exec $(printf '%q' "$workload") $(printf '%q' "$script")${args}"
}

# Run static ACL ownership and mode checks for a workload.
# Output is JSON, same shape as juso-report. PASS/FAIL per check.
# Usage: juso-audit-acl <workload>
function juso-audit-acl() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-audit-acl <workload>" >&2
    return 1
  fi
  ssh vm "sudo /usr/local/bin/audit-acl.sh ${workload}"
}

# Send a message to an agent via the gateway. Output streams to the terminal.
# Each invocation gets an isolated session (clean context window).
# Usage: juso-run-agent <workload-name> <agent-name> <message>
# Example: juso-run-agent research collector "begin run"
function juso-run-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  local message="${3:-}"
  if [[ -z "$workload" || -z "$agent" || -z "$message" ]]; then
    echo "Usage: juso-run-agent <workload> <agent> <message>"
    echo "Example: juso-run-agent research collector \"begin run\""
    return 1
  fi
  local session_id
  session_id="$(date +%Y%m%d-%H%M%S)-$$"
  ssh vm "sudo -u ${workload} bash -c 'openclaw agent --agent \"\$1\" --message \"\$2\" --session-id \"\$3\"' -- '${agent}' '${message}' '${session_id}'"
}

# Tail the active gateway log for a workload. Follows by name (-F) so it waits
# for the file if the gateway has not written today's log yet.
# Log path pattern: /tmp/openclaw-<workload-uid>/openclaw-<yyyy-mm-dd>.log
# The workload UID is resolved on the VM at runtime via `id -u <workload>`.
# Caveat: the date is computed on the VM. If Mac and VM are in different timezones
# the path may not match around midnight, but the juso setup assumes identical timezones.
# Usage: juso-logs <workload-name>
function juso-logs() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-logs <workload-name>"
    return 1
  fi
  ssh -t vm "uid=\$(id -u ${workload}); log=\"/tmp/openclaw-\${uid}/openclaw-\$(date +%Y-%m-%d).log\"; sudo -u ${workload} tail -F \"\${log}\""
}

# Generate a workload report: infrastructure health, agent run status, and hook-provided progress.
# Safe to run at any time — before, during, or after an agent run.
# Usage: juso-report <workload-name>
function juso-report() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-report <workload>"
    return 1
  fi
  ssh vm "sudo -u ${workload} bash ~/juso/scripts/report.sh ${workload}"
}

# Check all layers at once.
function juso-status() {
  echo ""
  echo "── Ollama (Mac mini) ───────────────────────────────"
  # Probe the VM-facing endpoint (192.168.64.1:11434) via juso-status-ollama, not
  # localhost — Ollama binds the UTM bridge interface, so a localhost check sees
  # nothing (or a stray loopback instance) and misreports the workload's Ollama.
  if juso-status-ollama 2>/dev/null | grep -q '"version"'; then
    echo "✓ running"
  else
    echo "✗ stopped or unreachable (no API at 192.168.64.1:11434)"
  fi

  echo ""
  echo "── VM ──────────────────────────────────────────────"
  ssh -o ConnectTimeout=3 vm "echo '✓ running'" \
    2>/dev/null || echo "✗ stopped or unreachable"

  echo ""
  echo "── Workloads ───────────────────────────────────────"
  local workload_output
  workload_output=$(ssh -o ConnectTimeout=3 vm \
    "sudo juso-workload-list 2>/dev/null | while IFS=: read name port; do
       status=\$(sudo juso-ctl \${name} is-active 2>/dev/null || true)
       [[ -z \"\${status}\" ]] && status=\"unknown\"
       echo \"\${name} (\${port}): \${status}\"
     done" \
    2>/dev/null) || {
    echo "✗ VM unreachable"
    echo ""
    return
  }
  if [[ -z "$workload_output" ]]; then
    echo "(no workloads provisioned)"
  else
    echo "$workload_output"
  fi

  echo ""
}

# Show all available juso commands.
function juso-help() {
  echo ""
  echo "juso management commands"
  echo ""
  echo "  Ollama:"
  echo "    juso-status-ollama                              — check Ollama on Mac mini"
  echo "    juso-start-ollama                               — start Ollama on Mac mini"
  echo "    juso-stop-ollama                                — stop Ollama on Mac mini"
  echo ""
  echo "  VM (start/stop require Screen Sharing — utmctl does not work over SSH):"
  echo "    juso-status-vm                                  — check VM reachability"
  echo "    juso-start-vm                                   — print start instructions"
  echo "    juso-stop-vm                                    — print stop instructions"
  echo ""
  echo "  Workloads:"
  echo "    juso-list                                       — list workloads and ports"
  echo "    juso-provision [--internet=none|open] [--model-id <model>] [--context-tokens <n>] <name>   — provision new workload"
  echo "    juso-destroy <workload>                         — destroy workload and all data"
  echo "    juso-start-workload <workload>                  — start workload gateway"
  echo "    juso-stop-workload <workload>                   — stop workload gateway"
  echo "    juso-status-workload <workload>                 — check workload gateway status"
  echo "    juso-pair-cli-device <workload> [scope ...]     — set CLI device scopes (default: operator.read operator.write)"
  echo "    juso-write-secret <workload> <KEY>              — prompt and write a secret to ~/.openclaw/.env"
  echo "    juso-check-secret <workload> <KEY>              — check a secret key is set in ~/.openclaw/.env"
  echo "    juso-configure-telegram <workload> --allowlist \"<ids>\" [--groups \"<ids>\"] [--ack-reaction <emoji>]   — configure Telegram channel"
  echo "    juso-shell <workload>                           — open shell as workload user on VM"
  echo ""
  echo "  Agents:"
  echo "    juso-add-agent <workload> <agent>               — add agent (interactive wizard)"
  echo "    juso-push-agent <workload> <agent> [--all] [--agents-dir <subdir>]  — push agent files to VM"
  echo "    juso-pull-agent <workload> <agent> [--agents-dir <subdir>]        — pull agent files from VM"
  echo "    juso-pull-shared <workload>                 — pull shared/ from VM"
  echo "    juso-clean-local <workload>                 — remove local generated artifacts before redeploy"
  echo "    juso-remove-agent <workload> <agent>            — remove agent and workspace"
  echo "    juso-clear-sessions <workload> [agent]          — clear session transcripts (all agents if no agent given)"
  echo "    juso-wipe-agent <workload> <agent> [--reset-memory]  — wipe agent sessions + memory logs"
  echo ""
  echo "  Dashboard:"
  echo "    juso-dashboard <workload>                       — open dashboard in browser"
  echo "    juso-dashboard-stop [workload]                  — close tunnel (all if omitted)"
  echo ""
  echo "  Utilities:"
  echo "    vm-exec <workload> <command>                    — run command on VM as workload user"
  echo "    juso-push-scripts <workload>                    — push scripts/ tree with kernel ACL"
  echo "    juso-config-set <workload> <path> <val> [--strict-json]  — patch openclaw.json (simple-path)"
  echo "    juso-ops-exec <workload> <script> [args...]     — execute ops/-tier script as root"
  echo "    juso-audit-acl <workload>                       — static ACL audit"
  echo "    juso-run-agent <workload> <agent> <message>     — run agent with message (bypasses dashboard)"
  echo "    juso-logs <workload>                            — tail the active gateway log"
  echo "    juso-report <workload>                          — generate workload report"
  echo "    juso-status                                     — check all layers at once"
  echo "    juso-help                                       — show this message"
  echo ""
  echo "  Startup order:  ollama → vm → workload(s)"
  echo "  Shutdown order: workload(s) → vm → ollama"
  echo ""
}
