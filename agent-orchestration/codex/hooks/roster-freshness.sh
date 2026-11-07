#!/usr/bin/env bash
# Native SessionStart: the shared check, claude/hooks/roster-freshness.sh, so Codex gets the same line
# for date, catalog and alias drift, plus the runtime model its input supplies. Advisory: exit 0.
guard="${BASH_SOURCE[0]%/*}/shared-guard.sh"
[ -f "$guard" ] && /bin/bash "$guard" roster-freshness
exit 0
