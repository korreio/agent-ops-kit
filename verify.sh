#!/usr/bin/env bash
# Run only fixture suites. Each suite owns a disposable HOME and fake providers.
set -euo pipefail
unset CDPATH   # internal cd output must contain only pwd, never CDPATH diagnostics
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1
command -v python3 >/dev/null || { echo 'Python 3.11+ is required for fixture checks; no python3 on PATH' >&2; exit 2; }
python3 -I -B -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
  || { echo "Python 3.11+ is required for fixture checks; found $(python3 --version 2>&1)" >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq is required for fixture checks' >&2; exit 2; }
for suite in \
  agent-orchestration/tests/test_roster.sh \
  agent-orchestration/tests/test_launchers.sh \
  agent-orchestration/tests/test_install_memory.sh \
  agent-orchestration/tests/test_install_claude.sh \
  agent-orchestration/claude/hooks/test_hooks.sh \
  agent-orchestration/tests/test_codex.sh \
  agent-orchestration/tests/test_install_codex.sh; do
  echo "Running $suite"
  bash "$suite"
done
python3 examples/check.py
python3 tests/check_content.py
