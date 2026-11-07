#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash), the agent-ops-kit Homebrew rule. A mutating brew — install upgrade
# uninstall remove rm reinstall link ln unlink, tap/untap with an argument, bundle unless its first
# argument is check list dump exec env or sh — must set HOMEBREW_NO_AUTO_UPDATE=1,
# HOMEBREW_NO_INSTALL_CLEANUP=1 and HOMEBREW_NO_AUTOREMOVE=1, inline (`A=1 brew …`, `env A=1 brew …`)
# or by `export A=1` earlier in the same command; else it blocks (exit 2). brew autoremove,
# brew cleanup and brew bundle cleanup always block. Read-only subcommands (list, info, services …)
# pass; brew's own flags before the subcommand are skipped, and so are bundle's options before its
# first argument, with the value of --file.
# Not inspected, deliberately: a "$(…)" inside double quotes and heredoc bodies (data), a guard
# unset or set to 0 later, `env -u`, aliases, bash -c, eval and scripts.
# Input: hook JSON on stdin (jq, else python3). A safety guard fails closed: if neither can read it,
# or lib/shell-tokens.bash is missing, it blocks (exit 2) and says what to put back.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
cmd="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.command // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)" ||
  { echo "brew-guards: blocked: cannot read the hook input. Install jq or python3 in your own terminal; Bash stays blocked until one of them can parse it." >&2; exit 2; }
case "$cmd" in *brew*) ;; *) exit 0 ;; esac
here="${BASH_SOURCE[0]}"; [ -L "$here" ] && { t="$(readlink "$here")"; case "$t" in /*) here="$t" ;; *) here="${here%/*}/$t" ;; esac; }
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
. "$here/lib/shell-tokens.bash" 2>/dev/null || { echo "brew-guards: blocked: $here/lib/shell-tokens.bash is missing. Reinstall the hooks with their lib/ folder; Bash stays blocked until it is back." >&2; exit 2; }

exported=" " problems=""
check_seg() {
  local t k sub arg="" have="$exported" g miss="" v=0
  cmd_start || return 0
  if [ "${seg[$CMD_AT]}" = export ]; then
    for t in "${seg[@]:$((CMD_AT+1))}"; do case "$t" in *=1) exported="$exported${t%%=*} " ;; esac; done
    return 0
  fi
  [ "${seg[$CMD_AT]##*/}" = brew ] || return 0
  for t in "${seg[@]:0:$CMD_AT}"; do case "$t" in *=1) have="$have${t%%=*} " ;; esac; done
  k=$((CMD_AT+1)); while case "${seg[$k]:-}" in -*) true ;; *) false ;; esac; do k=$((k+1)); done
  sub="${seg[$k]:-}"
  for t in "${seg[@]:$((k+1))}"; do
    if [ "$v" = 1 ]; then v=0; continue; fi   # the value of bundle's --file
    case "$sub:$t" in bundle:--file) v=1 ;; *:-*) ;; *) arg="$t"; break ;; esac
  done
  case "$sub:$arg" in
    autoremove:*|cleanup:*|bundle:cleanup)
      [ "$sub" = bundle ] && sub="bundle cleanup"
      problems="${problems}brew $sub is always blocked: no autoremove or package-manager cleanup. "; return 0 ;;
    tap:|untap:|bundle:check|bundle:list|bundle:dump|bundle:exec|bundle:env|bundle:sh) return 0 ;;
    install:*|upgrade:*|uninstall:*|remove:*|rm:*|reinstall:*|link:*|ln:*|unlink:*|tap:*|untap:*|bundle:*) ;;
    *) return 0 ;;
  esac
  for g in HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP HOMEBREW_NO_AUTOREMOVE; do
    case "$have" in *" $g "*) ;; *) miss="$miss $g=1" ;; esac
  done
  [ -z "$miss" ] || problems="${problems}brew $sub is missing$miss (set all three inline or export them earlier in this command). "
}
shell_tokens "$cmd"; segments check_seg
[ -z "$problems" ] && exit 0
echo "brew-guards: blocked: ${problems}agent-ops-kit Homebrew rule: every install, uninstall or upgrade sets HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1." >&2
exit 2
