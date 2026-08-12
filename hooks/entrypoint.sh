#!/usr/bin/env bash
# Dual-runner Entrypoint for antigravity-cli-check-usage-plugin
# Prefers Python 3 if installed; falls back to pure bash (check_quota.sh) automatically.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Buffer stdin so both runners can receive it cleanly
STDIN_DATA=""
if [ ! -t 0 ]; then
  STDIN_DATA=$(cat)
fi

if command -v python3 >/dev/null 2>&1; then
  echo "$STDIN_DATA" | python3 "${SCRIPT_DIR}/check_quota.py" "$@"
elif command -v python >/dev/null 2>&1; then
  echo "$STDIN_DATA" | python "${SCRIPT_DIR}/check_quota.py" "$@"
else
  echo "$STDIN_DATA" | bash "${SCRIPT_DIR}/check_quota.sh" "$@"
fi
