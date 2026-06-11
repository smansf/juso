#!/usr/bin/env bash
# help-snapshots.sh — Verify `bash <script> --help` matches the checked-in
# snapshot under test-fixtures/help-snapshots/. Run as a pre-commit hook.
set -euo pipefail
fail=0
for file in "$@"; do
  [[ -f "$file" ]] || continue
  [[ "$(basename "$file")" == _* ]] && continue
  if ! grep -qE -- '--help|usage\(\)' "$file"; then continue; fi
  snapshot="test-fixtures/help-snapshots/$(basename "$file").help.txt"
  if [[ ! -f "$snapshot" ]]; then
    echo "help-snapshots: ${file}: no snapshot at ${snapshot}" >&2
    fail=1
    continue
  fi
  actual=$(bash "$file" --help 2>&1) || true
  if ! printf '%s\n' "$actual" | cmp -s - "$snapshot"; then
    echo "help-snapshots: ${file}: --help output differs from ${snapshot}" >&2
    printf '%s\n' "$actual" | diff - "$snapshot" >&2 || true
    fail=1
  fi
done
exit $fail
