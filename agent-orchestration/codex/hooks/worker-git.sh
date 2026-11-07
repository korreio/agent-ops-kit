#!/usr/bin/env bash
# Worker direct Git denial: the shared guard, claude/hooks/worker-git.sh, through the wrapper that
# finds it. Codex hashes the hooks.json declaration, not this file, so editing it keeps hook trust.
guard="${BASH_SOURCE[0]%/*}/shared-guard.sh"
[ -f "$guard" ] || { echo "worker-git: blocked: $guard is missing. Reinstall the kit; Bash stays blocked until it is back." >&2; exit 2; }
exec /bin/bash "$guard" worker-git
