#!/usr/bin/env bash
# juso-ops.sh
# Shell functions for juso management from the MacBook Pro.
# Activate: add 'source <repo-path>/scripts/macbook/juso-ops.sh' to ~/.zshrc

# ─────────────────────────────────────────────────────────────────────────────
# OLLAMA
# ─────────────────────────────────────────────────────────────────────────────

# Check Ollama on the Mac mini.
function juso-status-ollama() {
  ssh -o ConnectTimeout=3 mini \
    "curl -s http://192.168.64.1:11434/api/version" \
    2>/dev/null || echo "✗ ollama unreachable"
}

# Start Ollama on the Mac mini.
function juso-start-ollama() {
  echo "Starting Ollama on Mac mini..."
  ssh mini "open -a Ollama"
  echo "  Allow a few seconds for Ollama to become ready."
}

# Stop Ollama on the Mac mini.
function juso-stop-ollama() {
  echo "Stopping Ollama on Mac mini..."
  ssh mini "osascript -e 'quit app \"Ollama\"'"
}

# ─────────────────────────────────────────────────────────────────────────────
# VM
# NOTE: start and stop require a local GUI session on the Mac mini.
#       Use Screen Sharing to open UTM and start/stop the VM from there.
# ─────────────────────────────────────────────────────────────────────────────

# Check VM reachability.
function juso-status-vm() {
  ssh -o ConnectTimeout=3 vm "echo '✓ vm is up'" \
    2>/dev/null || echo "✗ vm stopped or unreachable"
}

# Start the VM on the Mac mini.
function juso-start-vm() {
  echo "Cannot start VM over SSH — utmctl requires a local GUI session."
  echo "The VM starts automatically when juso logs in on the Mac mini."
  echo "To start manually: connect via Screen Sharing and use UTM."
}

# Stop the VM on the Mac mini.
function juso-stop-vm() {
  echo "Cannot stop VM over SSH — utmctl requires a local GUI session."
  echo "To stop: connect via Screen Sharing and use UTM."
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
# Usage: juso-provision [--internet=none|open] <workload-name>
function juso-provision() {
  if [[ -z "${1:-}" ]]; then
    echo "Usage: juso-provision [--internet=none|open] <workload-name>"
    return 1
  fi
  ssh -t vm "sudo ~/juso/scripts/provision-workload.sh $*"
}

# Destroy a workload and all its data. This operation is irreversible.
# Usage: juso-destroy <workload-name>
function juso-destroy() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-destroy <workload-name>"
    return 1
  fi
  ssh -t vm "sudo ~/juso/scripts/destroy-workload.sh ${workload}"
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
  local svc_status
  svc_status=$(ssh vm "sudo juso-ctl ${workload} is-active" 2>/dev/null)
  if [[ "$svc_status" == "inactive" ]]; then
    echo "  ✓ ${workload}: stopped"
  else
    echo "  ✗ ${workload}: unexpected state after stop: ${svc_status}"
    return 1
  fi
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
# Lands in the workload user's home directory (/home/juso-<workload>).
# From there: ~/.openclaw/workspace/<agent>/ and ~/shared/ are directly accessible.
# Usage: juso-shell <workload-name>
function juso-shell() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-shell <workload>"
    return 1
  fi
  ssh -t vm "sudo -i -u juso-${workload}"
}

# ─────────────────────────────────────────────────────────────────────────────
# AGENTS
# ─────────────────────────────────────────────────────────────────────────────

# Add an agent to a workload. Runs the OpenClaw agent creation wizard interactively.
# Usage: juso-add-agent <workload-name> <agent-name>
function juso-add-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-add-agent <workload-name> <agent-name>"
    return 1
  fi
  ssh -t vm "sudo ~/juso/scripts/add-agent.sh ${workload} ${agent}"
}

# Push agent workspace files to the VM.
# By default, pushes top-level files only (definition files: SOUL.md, AGENTS.md, etc.).
# Use --all to push everything including subdirectories (work products).
# Never deletes files on the destination — agent runtime files are left untouched.
# To remove a stale file manually:
#   ssh vm "sudo rm /home/juso-<workload>/.openclaw/workspace/<agent>/<file>"
# Run from your workloads repo root.
# Usage: juso-push-agent <workload-name> <agent-name> [--all]
function juso-push-agent() {
  local workload=""
  local agent=""
  local all=false

  for arg in "$@"; do
    case "$arg" in
      --all) all=true ;;
      *)
        if [[ -z "$workload" ]]; then workload="$arg"
        elif [[ -z "$agent" ]]; then agent="$arg"
        fi
        ;;
    esac
  done

  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-push-agent <workload-name> <agent-name> [--all]"
    return 1
  fi

  local role="${agent#${workload}-}"
  local source="${workload}/${role}"

  if [[ ! -d "$source" ]]; then
    echo "Error: '${source}' not found. Run from your workloads repo root."
    return 1
  fi

  local dest="vm:/home/juso-${workload}/.openclaw/workspace/${agent}/"
  local rsync_path="sudo -u juso-${workload} rsync"
  if $all; then
    rsync -av --rsync-path="${rsync_path}" "${source}/" "${dest}"
  else
    rsync -av --rsync-path="${rsync_path}" --exclude='*/' "${source}/" "${dest}"
  fi
}

# Pull agent workspace files from the VM.
# Pulls definition files and work products. Excludes OpenClaw internal state
# files (.openclaw/) that are runtime-generated and should not enter the repo.
# Always pull before pushing to avoid overwriting agent-evolved files.
# Run from your workloads repo root.
# Usage: juso-pull-agent <workload-name> <agent-name>
function juso-pull-agent() {
  local workload="${1:-}"
  local agent="${2:-}"
  if [[ -z "$workload" || -z "$agent" ]]; then
    echo "Usage: juso-pull-agent <workload-name> <agent-name>"
    return 1
  fi
  local role="${agent#${workload}-}"
  local dest="${workload}/${role}"
  if [[ ! -d "$dest" ]]; then
    echo "Error: '${dest}' not found. Run from your workloads repo root."
    return 1
  fi
  local source="vm:/home/juso-${workload}/.openclaw/workspace/${agent}/"
  rsync -av --rsync-path="sudo -u juso-${workload} rsync" --exclude='.openclaw/' "${source}" "${dest}/"
}

# Push workload shared data to the VM.
# Pushes the entire shared/ directory to ~/shared/ on the VM.
# Run from your workloads repo root.
# Usage: juso-push-shared <workload-name>
function juso-push-shared() {
  local workload="${1:-}"
  if [[ -z "$workload" ]]; then
    echo "Usage: juso-push-shared <workload-name>"
    return 1
  fi
  local source="${workload}/shared"
  if [[ ! -d "$source" ]]; then
    echo "Error: '${source}' not found. Run from your workloads repo root."
    return 1
  fi
  local dest="vm:/home/juso-${workload}/shared/"
  rsync -av --rsync-path="sudo -u juso-${workload} rsync" "${source}/" "${dest}"
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
  local source="vm:/home/juso-${workload}/shared/"
  rsync -av --rsync-path="sudo -u juso-${workload} rsync" "${source}" "${dest}/"
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
  token_url=$(ssh vm "sudo -u juso-${workload} openclaw dashboard 2>/dev/null" | grep -o 'http://[^ ]*') || true

  if [[ -n "$token_url" ]]; then
    local local_url="${token_url//127.0.0.1/localhost}"
    echo "Opening dashboard with token: ${local_url}"
    open "$local_url"
  else
    echo "Could not retrieve dashboard token. Opening without token."
    echo "Retrieve manually: ssh vm 'sudo -u juso-${workload} openclaw dashboard'"
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

# Send a message to an agent, bypassing the dashboard. Output streams to the terminal.
# Workaround for GitHub openclaw#48167 (v2026.3.13 loopback regression). The use of --local
# is not an accepted long-term solution — alternatives are being explored.
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
  ssh vm "sudo -u juso-${workload} bash -c 'openclaw agent --agent \"\$1\" --message \"\$2\" --local --timeout 1800' -- '${agent}' '${message}'" # --timeout 1800: 30-minute session ceiling
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
  ssh vm "sudo -u juso-${workload} bash ~/juso/scripts/report.sh ${workload}"
}

# Check all layers at once.
function juso-status() {
  echo ""
  echo "── Ollama (Mac mini) ───────────────────────────────"
  ssh -o ConnectTimeout=3 mini \
    "pgrep -x ollama > /dev/null && echo '✓ running' || echo '✗ stopped'" \
    2>/dev/null || echo "✗ mini unreachable"

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
    2>/dev/null) || { echo "✗ VM unreachable"; echo ""; return; }
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
  echo "    juso-provision [--internet=none|open] <name>   — provision new workload"
  echo "    juso-destroy <workload>                         — destroy workload and all data"
  echo "    juso-start-workload <workload>                  — start workload gateway"
  echo "    juso-stop-workload <workload>                   — stop workload gateway"
  echo "    juso-status-workload <workload>                 — check workload gateway status"
  echo "    juso-shell <workload>                           — open shell as workload user on VM"
  echo ""
  echo "  Agents:"
  echo "    juso-add-agent <workload> <agent>               — add agent (interactive wizard)"
  echo "    juso-push-agent <workload> <agent> [--all]  — push agent files to VM (default: top-level only)"
  echo "    juso-pull-agent <workload> <agent>          — pull agent files from VM (everything)"
  echo "    juso-push-shared <workload>                 — push shared/ to VM"
  echo "    juso-pull-shared <workload>                 — pull shared/ from VM"
  echo "    juso-clean-local <workload>                 — remove local generated artifacts before redeploy"
  echo "    juso-remove-agent <workload> <agent>            — remove agent and workspace"
  echo ""
  echo "  Dashboard:"
  echo "    juso-dashboard <workload>                       — open dashboard in browser"
  echo "    juso-dashboard-stop [workload]                  — close tunnel (all if omitted)"
  echo ""
  echo "  Utilities:"
  echo "    juso-run-agent <workload> <agent> <message>     — run agent with message (bypasses dashboard)"
  echo "    juso-report <workload>                          — generate workload report"
  echo "    juso-status                                     — check all layers at once"
  echo "    juso-help                                       — show this message"
  echo ""
  echo "  Startup order:  ollama → vm → workload(s)"
  echo "  Shutdown order: workload(s) → vm → ollama"
  echo ""
}
