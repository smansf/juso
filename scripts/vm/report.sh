#!/usr/bin/env bash
# report.sh
# Generates a health, status, and progress report for all agents in a workload.
# Safe to run at any time — before, during, or after an agent run.
# Usage: bash report.sh <workload>
# Runs as: the workload Linux user (juso-<workload>)

set -uo pipefail

# ─── Arguments ───────────────────────────────────────────────────────────────

WORKLOAD="${1:-}"
if [[ -z "$WORKLOAD" ]]; then
  echo "Usage: bash report.sh <workload>"
  exit 1
fi

# ─── Paths ───────────────────────────────────────────────────────────────────

WORKSPACE_BASE="${HOME}/.openclaw/workspace"
SESSIONS_BASE="${HOME}/.openclaw/agents"
SHARED_DIR="${HOME}/shared"
REPORTS_DIR="${HOME}/shared/reports"
DATE="$(date +%Y-%m-%d)"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M)"

# ─── Output ──────────────────────────────────────────────────────────────────
# emit() prints to stdout and appends to a temp file.
# At the end the temp file is copied to the final report location.

REPORT_TMPFILE="$(mktemp /tmp/juso-report-XXXXXX.md)"
trap 'rm -f "${REPORT_TMPFILE}"' EXIT

emit() {
  printf '%s\n' "${1:-}" | tee -a "${REPORT_TMPFILE}"
}

mkdir -p "${REPORTS_DIR}" 2>/dev/null || {
  echo "⚠ Warning: could not create ${REPORTS_DIR} — report will not be saved to disk" >&2
  REPORTS_DIR=""
}

# ─── Header ──────────────────────────────────────────────────────────────────

emit "# Workload Report: ${WORKLOAD}"
emit "Generated: ${TIMESTAMP}"
emit ""

# ─── Section 1: Infrastructure Health ────────────────────────────────────────

emit "## Infrastructure Health"
emit ""

GATEWAY_UP=false

# Gateway liveness
# "running" appears when systemd reports active; "RPC probe: ok" confirms the process
# is alive and responding when systemd user services are unavailable (juso's setup).
gateway_output="$(openclaw gateway status 2>&1)" || true
if echo "${gateway_output}" | grep -qi "running\|RPC probe: ok"; then
  emit "✓ PASS — gateway: running"
  GATEWAY_UP=true
else
  emit "✗ FAIL — gateway: not running"
  emit "  Output: ${gateway_output}"
fi

# Ollama reachability
if curl -sf --max-time 5 http://192.168.64.1:11434/api/version >/dev/null 2>&1; then
  emit "✓ PASS — ollama: reachable at 192.168.64.1:11434"
else
  emit "✗ FAIL — ollama: unreachable at 192.168.64.1:11434"
fi

# Ollama model availability
MODEL=""
if [[ -f "${HOME}/.openclaw/openclaw.json" ]]; then
  MODEL="$(jq -r '.provider.model // empty' "${HOME}/.openclaw/openclaw.json" 2>/dev/null)" || true
fi
if [[ -n "${MODEL}" ]]; then
  tags_output="$(curl -sf --max-time 5 http://192.168.64.1:11434/api/tags 2>&1)" || true
  if echo "${tags_output}" | grep -q "${MODEL}"; then
    emit "✓ PASS — model: ${MODEL} available"
  else
    available="$(echo "${tags_output}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')" || true
    emit "✗ FAIL — model: ${MODEL} not found in Ollama"
    emit "  Available: ${available:-none}"
  fi
else
  emit "⚠ WARN — model: could not read model name from openclaw.json"
fi

# VM clock sync
clock_output="$(timedatectl show --no-pager 2>&1)" || true
if echo "${clock_output}" | grep -q "NTPSynchronized=yes"; then
  emit "✓ PASS — clock: NTP synchronized"
else
  clock_detail="$(echo "${clock_output}" | grep -i "NTP\|sync" | head -3 | tr '\n' ' ')" || true
  emit "✗ FAIL — clock: NTP not synchronized"
  emit "  Detail: ${clock_detail:-no sync info found}"
fi

emit ""

# ─── Discover agents ─────────────────────────────────────────────────────────

AGENTS=()
if [[ -d "${WORKSPACE_BASE}" ]]; then
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] && AGENTS+=("${entry}")
  done < <(ls -1 "${WORKSPACE_BASE}/" 2>/dev/null || true)
fi

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  emit "⚠ No agents found for workload '${WORKLOAD}' in ${WORKSPACE_BASE}/"
  if [[ -n "${REPORTS_DIR}" ]]; then
    cp "${REPORT_TMPFILE}" "${REPORTS_DIR}/${TIMESTAMP}.md"
    echo "Report written to: ${REPORTS_DIR}/${TIMESTAMP}.md"
  fi
  exit 0
fi

# ─── Per-agent sections ───────────────────────────────────────────────────────

for AGENT in "${AGENTS[@]}"; do

  # ── Section 2: Agent Status ─────────────────────────────────────────────────

  emit "## Agent: ${AGENT}"
  emit ""

  # Session JSONL recency
  SESSIONS_DIR="${SESSIONS_BASE}/${AGENT}/sessions"
  LATEST_SESSION=""
  SESSION_AGE_SECONDS=0

  if [[ -d "${SESSIONS_DIR}" ]]; then
    LATEST_SESSION="$(find "${SESSIONS_DIR}" -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null \
      | sort -n | tail -1 | awk '{print $2}')" || true
  fi

  if [[ -n "${LATEST_SESSION}" ]]; then
    FILE_MTIME="$(stat -c %Y "${LATEST_SESSION}" 2>/dev/null)" || FILE_MTIME=0
    NOW="$(date +%s)"
    SESSION_AGE_SECONDS=$(( NOW - FILE_MTIME ))

    if (( SESSION_AGE_SECONDS < 60 )); then
      emit "Last session activity: ${SESSION_AGE_SECONDS} seconds ago"
    elif (( SESSION_AGE_SECONDS < 3600 )); then
      emit "Last session activity: $(( SESSION_AGE_SECONDS / 60 )) minutes ago"
    else
      ACTIVITY_TIME="$(date -d "@${FILE_MTIME}" "+%Y-%m-%d %H:%M" 2>/dev/null)" || ACTIVITY_TIME="unknown"
      emit "Last session activity: ${ACTIVITY_TIME}"
    fi
  else
    emit "Last session activity: none"
  fi

  # Inferred run status
  SESSION_LOG="${WORKSPACE_BASE}/${AGENT}/memory/${DATE}.md"
  LOG_PRESENT=absent
  [[ -s "${SESSION_LOG}" ]] && LOG_PRESENT=present

  if [[ "${GATEWAY_UP}" == false ]]; then
    RUN_STATUS="NOT RUNNING (gateway down)"
  elif [[ -z "${LATEST_SESSION}" ]]; then
    RUN_STATUS="NOT STARTED (no sessions found)"
  elif (( SESSION_AGE_SECONDS < 300 )); then
    RUN_STATUS="LIKELY ACTIVE"
  elif [[ "${LOG_PRESENT}" == present ]]; then
    RUN_STATUS="LIKELY COMPLETE"
  elif (( SESSION_AGE_SECONDS < 3600 )); then
    RUN_STATUS="LIKELY STALLED OR RECENTLY COMPLETED"
  else
    RUN_STATUS="IDLE (last activity >1 hour ago)"
  fi

  emit "Run status: ${RUN_STATUS}"
  emit "Status basis: session file age=${SESSION_AGE_SECONDS}s, today's session log=${LOG_PRESENT}"
  emit ""

  # ── Section 3: Hook output ───────────────────────────────────────────────────

  HOOK="${WORKSPACE_BASE}/${AGENT}/report-hook.sh"
  if [[ -f "${HOOK}" ]]; then
    HOOK_STDERR_FILE="$(mktemp /tmp/juso-hook-stderr-XXXXXX)"
    export WORKLOAD AGENT DATE
    export WORKSPACE_DIR="${WORKSPACE_BASE}/${AGENT}"
    export SHARED_DIR

    HOOK_EXIT=0
    hook_stdout="$(timeout 30 bash "${HOOK}" 2>"${HOOK_STDERR_FILE}")" || HOOK_EXIT=$?

    emit "### Progress: ${AGENT}"
    emit ""

    if (( HOOK_EXIT == 0 )) && [[ -n "${hook_stdout}" ]]; then
      emit "${hook_stdout}"
    elif (( HOOK_EXIT == 124 )); then
      emit "⚠ Hook timed out after 30 seconds"
    else
      HOOK_STDERR="$(cat "${HOOK_STDERR_FILE}" 2>/dev/null)" || true
      emit "⚠ Hook failed (exit code: ${HOOK_EXIT})"
      [[ -n "${HOOK_STDERR}" ]] && emit "${HOOK_STDERR}"
    fi

    emit ""
    rm -f "${HOOK_STDERR_FILE}"
  fi

  # ── Section 4: Session log tail ──────────────────────────────────────────────

  if [[ -s "${SESSION_LOG}" ]]; then
    emit "### Session Log: ${AGENT} (last 20 lines)"
    emit ""
    log_tail="$(tail -20 "${SESSION_LOG}")"
    emit "${log_tail}"
  else
    emit "### Session Log: ${AGENT}"
    emit ""
    emit "(no session log for today)"
  fi

  emit ""

done

# ─── Write report file ────────────────────────────────────────────────────────

if [[ -n "${REPORTS_DIR}" ]]; then
  cp "${REPORT_TMPFILE}" "${REPORTS_DIR}/${TIMESTAMP}.md"
  echo "Report written to: ${REPORTS_DIR}/${TIMESTAMP}.md"
fi
