#!/usr/bin/env bash
# header-cap.sh — Fail if a shell script's leading comment block exceeds 8 lines.
# Run as a pre-commit hook on staged *.sh files.

set -euo pipefail

MAX_LINES=8

fail=0
for file in "$@"; do
  [[ -f "$file" ]] || continue
  count=$(awk '
    NR == 1 && /^#!/ { next }
    /^[[:space:]]*$/ { lines++; next }
    /^#/ { lines++; next }
    { print lines; printed=1; exit }
    END { if (!printed) print lines }
  ' "$file")
  if ((count > MAX_LINES)); then
    echo "header-cap: ${file}: ${count} header lines (max ${MAX_LINES})" >&2
    fail=1
  fi
done
exit $fail
