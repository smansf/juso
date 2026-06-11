#!/usr/bin/env bash
# help-runs.sh — Verify each staged help-aware *.sh script exits 0 with non-empty
# output for --help. Skips scripts that don't accept --help.

set -euo pipefail

fail=0
for file in "$@"; do
  [[ -f "$file" ]] || continue
  [[ "$(basename "$file")" == _* ]] && continue
  if ! grep -qE -- '--help|usage\(\)' "$file"; then
    continue
  fi
  out=$(bash "$file" --help 2>&1) || {
    echo "help-runs: ${file}: --help exited non-zero" >&2
    fail=1
    continue
  }
  if [[ -z "$out" ]]; then
    echo "help-runs: ${file}: --help produced no output" >&2
    fail=1
  fi
done
exit $fail
