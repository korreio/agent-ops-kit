#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Stage explicit paths. Blocks (exit 2):
#   git add / git stage with -A, --all, -f, --force, or a short cluster holding A or f (-Av);
#   git add / git stage with -u, --update or a short cluster holding u (-vu), unless a path other
#   than . ./ :/ is named or --pathspec-from-file is used;
#   git commit with -a, --all, or a short cluster holding a (-am, -qam);
#   any of the three with a whole-tree pathspec . ./ :/ * ./* (before or after --).
# For add and stage, a prefix of --all, --force or --update counts as that option, as real git
# reads it (--al, --forc); --a and --u are ambiguous only on newer git.
# A short cluster starts with a letter (-20 is not one) and is read up to the first commit letter
# that takes a value (m F C c t S u; the rest of the cluster, or the next word for m F C c t, is
# that value), so -mchange, -m"text", -ma, -Sabc and -uall pass. -u with a path, -p, -N and
# explicit paths pass. git -C <path> and -c k=v before the subcommand are handled.
# Not inspected, deliberately: a "$(…)" inside double quotes and heredoc bodies (data), aliases,
# bash -c, eval and scripts, variables, pathspec magic (:(top)), what --pathspec-from-file lists.
# Input: hook JSON on stdin (jq, else python3). A safety guard fails closed: if neither can read it,
# or lib/shell-tokens.bash is missing, it blocks (exit 2) and says what to put back.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
cmd="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.command // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)" ||
  { echo "git-staging-guard: blocked: cannot read the hook input. Install jq or python3 in your own terminal; Bash stays blocked until one of them can parse it." >&2; exit 2; }
case "$cmd" in *git*) ;; *) exit 0 ;; esac
here="${BASH_SOURCE[0]}"; [ -L "$here" ] && { t="$(readlink "$here")"; case "$t" in /*) here="$t" ;; *) here="${here%/*}/$t" ;; esac; }
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
. "$here/lib/shell-tokens.bash" 2>/dev/null || { echo "git-staging-guard: blocked: $here/lib/shell-tokens.bash is missing. Reinstall the hooks with their lib/ folder; Bash stays blocked until it is back." >&2; exit 2; }

bad=""
check_seg() {
  local a c v=0 u="" p=0
  cmd_start && git_sub "$CMD_AT" || return 0
  case "$GIT_SUB" in add|stage|commit) ;; *) return 0 ;; esac
  for a in "${seg[@]:$GIT_ARG}"; do
    if [ "$v" = 1 ]; then v=0; continue; fi   # the value of -m -F -C -c -t
    [ "$GIT_SUB" = commit ] || case "$a" in
      --a|--al) a=--all ;; --f|--fo|--for|--forc) a=--force ;; --u|--up|--upd|--upda|--updat) a=--update ;;
    esac
    case "$GIT_SUB:$a" in
      *:--all|*:--force|*:.|*:./|*::/|*:\*|*:./\*) bad="$bad git $GIT_SUB $a;" ;;
      add:--update|stage:--update) u="$a" ;;
      *:--pathspec-from-file*) p=1 ;;
      *:--*) ;;
      commit:-[A-Za-z]*)
        c="${a#-}"; c="${c%%[mFCctSu]*}"
        case "$c" in *a*) bad="$bad git commit $a;" ;; esac
        case "${a#-"$c"}" in [mFCct]) v=1 ;; esac ;;
      *:-[A-Za-z]*)
        case "$a" in *[Af]*) bad="$bad git $GIT_SUB $a;" ;; esac
        case "$a" in *u*) u="$a" ;; esac ;;
      *:*[\<\>]*) ;;   # a redirection, not a path
      *) p=1 ;;
    esac
  done
  [ -n "$u" ] && [ "$p" = 0 ] && bad="$bad git $GIT_SUB $u without file paths: name the files;"
}
shell_tokens "$cmd"; segments check_seg
[ -z "$bad" ] && exit 0
echo "git-staging-guard: blocked:$bad Stage explicit paths: git add path/a path/b, then git commit -m \"…\" (only the files of your change)." >&2
exit 2
