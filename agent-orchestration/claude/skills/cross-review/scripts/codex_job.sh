#!/usr/bin/env bash
# COMPATIBILITY SHIM — the real launcher moved to agent-orchestration/bin/codex_job.sh so that
# all three launchers live together and none is buried inside one platform's skill directory.
# This shim keeps working: (a) briefs/notes that still name the old skill path, and (b) a
# ~/.local/bin/codex-review symlink created before the move. Re-run `install.sh --apply --bin`
# to point that symlink at bin/ directly; the shim can go once every Mac has.
# It resolves symlinks on BOTH the file and its directories, so it works whether it is invoked
# through ~/.claude/skills/cross-review (a symlinked directory) or through a symlink to itself.
set -euo pipefail
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  d="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$d/$src";; esac
done
exec "$(cd -P "$(dirname "$src")/../../../../bin" && pwd)/codex_job.sh" "$@"
