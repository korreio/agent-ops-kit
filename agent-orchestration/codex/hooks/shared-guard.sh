#!/usr/bin/env bash
# Resolves the installed script or directory link in the shell, so a machine with jq alone works as
# it does on Claude, then runs the shared Claude hook, which reads the input with jq, else python3.
# Every guard failure blocks: no shared guard here, and in the guard no parser and no tokenizer, exit 2.
# outward-ask runs with --deny: Codex continues the tool call on an ask decision. roster-freshness
# is advisory, so it never blocks, and it adds the runtime model that the Codex input supplies.
set -u
flag=""
case "${1:-}" in
  brew-guards|secrets-guard|git-staging-guard|worker-git) ;;
  outward-ask) flag=--deny ;;
  roster-freshness) flag=--runtime-model ;;
  *) exit 2 ;;
esac
s="${BASH_SOURCE[0]}"; case "$s" in */*) ;; *) s="./$s" ;; esac
for _ in 1 2 3 4 5 6 7 8; do
  [ -L "$s" ] || break; t="$(readlink "$s")" || break
  case "$t" in /*) s="$t" ;; *) s="${s%/*}/$t" ;; esac
done
here="$(cd -P "${s%/*}" 2>/dev/null && pwd -P)"
if [ ! -f "$here/../../claude/hooks/$1.sh" ]; then
  [ "$1" = roster-freshness ] && exit 0
  echo "shared-guard: blocked: cannot find claude/hooks/$1.sh from ${here:-this link}. Reinstall the kit (with readlink on PATH); Bash stays blocked until it is back." >&2
  exit 2
fi
exec /bin/bash "$here/../../claude/hooks/$1.sh" ${flag:+"$flag"}
