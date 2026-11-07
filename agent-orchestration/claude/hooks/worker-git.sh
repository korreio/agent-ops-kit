#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash), shared by both families: codex/hooks/worker-git.sh reaches it
# through shared-guard.sh. Git belongs to the coordinator, so a worker may run only git status, log,
# blame and show <rev>:<path>; any other git subcommand blocks (exit 2). A worker is a hook input
# with agent_id (a subagent or in-process teammate) or a launched lane marked
# CLAUDE_ORCHESTRATION_WORKER=1 or CODEX_ORCHESTRATION_WORKER=1. agent_type alone is no worker: a
# main session started with --agent has it. A coordinator session passes untouched.
# A permitted subcommand still blocks when what runs it can be changed: a GIT_* assignment before
# git (env included), or the global options -c, --config-env, --exec-path, --git-dir and
# --work-tree, joined or separate. A config key such as core.fsmonitor, core.pager or
# diff.external runs a command, so `git -c core.fsmonitor=… status` could commit. -C <dir>,
# --no-pager and --no-optional-locks stay allowed.
# Not inspected, deliberately: a "$(…)" inside double quotes and heredoc bodies (data), aliases,
# bash -c, xargs, eval and scripts, and a GIT_* variable exported earlier. The same heuristic
# tokenizer, not hostile-code isolation.
# Input: hook JSON on stdin (jq, else python3). A safety guard fails closed: if neither can read it,
# or lib/shell-tokens.bash is missing, it blocks (exit 2) and says what to put back.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
unread() { echo "worker-git: blocked: cannot read the hook input. Install jq or python3 in your own terminal; Bash stays blocked until one of them can parse it." >&2; exit 2; }
worker="$(printf '%s' "$input" 2>/dev/null | jq -r '.agent_id // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("agent_id") or "")' 2>/dev/null)" || unread
[ -n "$worker" ] || [ "${CLAUDE_ORCHESTRATION_WORKER:-}" = 1 ] || [ "${CODEX_ORCHESTRATION_WORKER:-}" = 1 ] || exit 0
cmd="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.command // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)" || unread
case "$cmd" in *git*) ;; *) exit 0 ;; esac
here="${BASH_SOURCE[0]}"; [ -L "$here" ] && { t="$(readlink "$here")"; case "$t" in /*) here="$t" ;; *) here="${here%/*}/$t" ;; esac; }
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
. "$here/lib/shell-tokens.bash" 2>/dev/null || { echo "worker-git: blocked: $here/lib/shell-tokens.bash is missing. Reinstall the hooks with their lib/ folder; Bash stays blocked until it is back." >&2; exit 2; }

bad=""
check_seg() {
  cmd_start && git_sub "$CMD_AT" || return 0
  case "$GIT_SUB" in status|log|blame) ;; show) case "${seg[$GIT_ARG]:-}" in *:*) ;; *) bad=show ;; esac ;;
    *) bad="$GIT_SUB" ;;
  esac
  # --output writes a file, on the read-only subcommands too. Git accepts unique prefixes.
  local a
  for a in "${seg[@]:$GIT_ARG}"; do case "$a" in --ou*) bad="$GIT_SUB --output" ;; esac; done
  # What runs git, see the header: the prefix before it, then git's own options before the subcommand.
  for a in "${seg[@]:0:$CMD_AT}"; do case "$a" in GIT_*=*) bad="${GIT_SUB:+$GIT_SUB }with ${a%%=*}" ;; esac; done
  # The directory after -C is a value, whatever it is called (-client is a directory, not -c).
  local i=$((CMD_AT+1))
  while [ "$i" -lt "$((GIT_ARG-1))" ]; do
    a="${seg[$i]}"
    case "$a" in
      -C) i=$((i+2)); continue ;;
      -c*|--config-env*|--exec-path*|--git-dir*|--work-tree*) bad="${GIT_SUB:+$GIT_SUB }with ${a%%=*}" ;;
    esac
    i=$((i+1))
  done
}
shell_tokens "$cmd"; segments check_seg
[ -z "$bad" ] && exit 0
printf 'worker-git: blocked direct git %s; Git belongs to the coordinator.\n' "$bad" >&2
exit 2
