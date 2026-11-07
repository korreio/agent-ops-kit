#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). `gh workflow run` starts remote CI work: the hook asks the owner
# first by printing, with exit 0,
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"…"}}
# so the run waits for the permission prompt even where a mode or an allow rule would run it.
# gh flags may come before `workflow` or `run` (gh -R o/r workflow run x). A run is EXEMPT (exit 0,
# no output, the normal permission flow applies) only when all three hold:
#   - the repository of the hook input's cwd — the parent of `git rev-parse --path-format=absolute
#     --git-common-dir`, so a worktree counts as its main checkout, realpath'd — is listed in
#     outward-ask.allow beside this script's resolved link (owner-kept);
#   - its workflow, the first operand after `run` (-r/--ref, -f/--raw-field, -F/--field and
#     -R/--repo consume a value), is listed for that repository;
#   - no -R/--repo appears in it.
# --deny, as the Codex wrapper runs it, blocks with exit 2 and a reason naming outward-ask.allow in
# place of the prompt: same rules, same file. Codex parses permissionDecision "ask" but does not
# support it: it marks the hook run failed and continues the tool call, so asking there allows.
# Not inspected, deliberately: a "$(…)" inside double quotes and heredoc bodies (data), a `cd`
# before the run, GH_REPO and other environment, aliases, bash -c, eval and scripts.
# Input: hook JSON on stdin (jq, else python3). A safety guard fails closed: if neither can read it,
# or lib/shell-tokens.bash is missing, it blocks (exit 2) and says what to put back.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
cmd="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.command // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)" ||
  { echo "outward-ask: blocked: cannot read the hook input. Install jq or python3 in your own terminal; Bash stays blocked until one of them can parse it." >&2; exit 2; }
case "$cmd" in *workflow*) ;; *) exit 0 ;; esac
here="${BASH_SOURCE[0]}"; [ -L "$here" ] && { t="$(readlink "$here")"; case "$t" in /*) here="$t" ;; *) here="${here%/*}/$t" ;; esac; }
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
. "$here/lib/shell-tokens.bash" 2>/dev/null || { echo "outward-ask: blocked: $here/lib/shell-tokens.bash is missing. Reinstall the hooks with their lib/ folder; Bash stays blocked until it is back." >&2; exit 2; }

asks=0; names=()
check_seg() {
  local k t pos=""
  cmd_start && [ "${seg[$CMD_AT]##*/}" = gh ] || return 0
  k=$((CMD_AT+1))
  while [ "$k" -lt "${#seg[@]}" ] && [ "$pos" != " workflow run" ]; do   # the first two operands
    t="${seg[$k]}"; k=$((k+1))
    case "$t" in -R|--repo) k=$((k+1)) ;; -*) ;; *) pos="$pos $t" ;; esac
  done
  [ "$pos" = " workflow run" ] || return 0
  for t in "${seg[@]}"; do case "$t" in -R*|--repo|--repo=*) asks=1 ;; esac; done
  while [ "$k" -lt "${#seg[@]}" ]; do
    t="${seg[$k]}"; k=$((k+1))
    case "$t" in -r|--ref|-f|--raw-field|-F|--field|-R|--repo) k=$((k+1)) ;; -*) ;; *) names+=("$t"); return 0 ;; esac
  done
  asks=1   # no workflow named
}
real() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
listed() {   # listed <workflow> → 0 when outward-ask.allow lists it for the cwd's repository
  local r w
  while read -r r w _ || [ -n "$r" ]; do
    case "$r" in ''|'#'*) continue ;; '~/'*) r="${HOME:-}/${r#'~/'}" ;; esac
    [ "$w" = "$1" ] && [ "$(real "$r")" = "$repo" ] && return 0
  done < "$here/outward-ask.allow"
  return 1
}
shell_tokens "$cmd"; segments check_seg
[ "$asks" = 1 ] || [ "${#names[@]}" -gt 0 ] || exit 0
if [ "$asks" = 0 ] && [ -r "$here/outward-ask.allow" ]; then
  cwd="$(printf '%s' "$input" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null ||
    printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("cwd") or "")' 2>/dev/null)"
  repo="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && repo="$(real "${repo%/*}")" || repo=""
  for n in "${names[@]}"; do [ -n "$repo" ] && listed "$n" || { asks=1; break; }; done
  [ "$asks" = 0 ] && exit 0
fi
if [ "${1:-}" = --deny ]; then
  echo "outward-ask: blocked: gh workflow run starts remote CI work and Codex hooks cannot ask for confirmation. It stays with the coordinator under the owner's authority: the owner runs it, or lists this repository and workflow in $(real "$here")/outward-ask.allow (a -R/--repo run is never exempt)." >&2
  exit 2
fi
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"outward-ask: gh workflow run starts remote CI work. It stays with the coordinator under the owner'"'"'s authority; confirm this exact command."}}'
exit 0
