#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash), the global secrets guard (agent-ops-kit). Blocks (exit 2) a display
# command — cat less more head tail bat nl strings xxd od base64, git show, git cat-file, and the
# grep family (grep egrep fgrep rg, git grep: its first operand is the pattern unless -e/-f gave
# one) — when an argument (quotes and a `<rev>:` prefix stripped) is a secret file:
#   .env, .env.* or a .env glob (.env*, .env.?*) (templates *.example *.sample *.template *.dist
#   pass; other names such as .env.md also match this heuristic), key.properties, a .*_history
#   file or fish_history, anything in a .ssh directory, and at
#   the home path (~/, $HOME/, /Users/<u>/) .aws/*, .netrc, .npmrc, .pgpass, .config/gh/hosts.yml;
#   as a file argument only (not a redirection): *.pem *.key *.p12 *.pfx *.jks *.keystore *.p8,
#   credentials*.json, secrets*.json, a file named password, and ~/.codex/auth.json.
# Names match in any letter case, templates included: on the default case-insensitive APFS volume
# .ENV, ~/.SSH and Auth.json open the real files.
# sed and awk are blocked when a file they read is secret: an -f script file or a file operand,
# found by the native macOS option grammar (sed_awk below). Programs, sed -i/-I backup extensions
# and awk -F/-v values are data.
# Also blocked: an input redirect from a secret file in any command (< .env), and `history`.
# Everything else passes: loading (source .env, --env-file .env), file tests, git check-ignore, cp.
# Not inspected, deliberately: a "$(…)" inside double quotes and heredoc bodies (data), other
# readers (python …), what a sed/awk program itself reads or writes, other globs, variables and
# other runtime-built paths, bash -c, eval and scripts, grep options with a separate value other
# than -e -f -A -B -C -m -g -t -T. Names match in any ASCII letter case; a Unicode lookalike that a
# case-insensitive volume folds to the same file, such as the Kelvin sign for K, is not matched.
# Read/Edit of these files are denied by permissions.deny in settings-fragment.json.
# Input: hook JSON on stdin (jq, else python3). A safety guard fails closed: if neither can read it,
# or lib/shell-tokens.bash is missing, it blocks (exit 2) and says what to put back.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
cmd="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.command // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")' 2>/dev/null)" ||
  { echo "secrets-guard: blocked: cannot read the hook input. Install jq or python3 in your own terminal; Bash stays blocked until one of them can parse it." >&2; exit 2; }
shopt -s nocasematch   # any letter case, see the header; only here and in secret()
case "$cmd" in *.env*|*key.properties*|*history*|*.ssh*|*.aws*|*.netrc*|*.npmrc*|*.pgpass*|*hosts.yml*) ;;
  *auth.json*|*.pem*|*.key*|*.p12*|*.pfx*|*.jks*|*.p8*|*credentials*|*secrets*|*password*) ;; *) exit 0 ;; esac
shopt -u nocasematch
here="${BASH_SOURCE[0]}"; [ -L "$here" ] && { t="$(readlink "$here")"; case "$t" in /*) here="$t" ;; *) here="${here%/*}/$t" ;; esac; }
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
. "$here/lib/shell-tokens.bash" 2>/dev/null || { echo "secrets-guard: blocked: $here/lib/shell-tokens.bash is missing. Reinstall the hooks with their lib/ folder; Bash stays blocked until it is back." >&2; exit 2; }

# secret <word> [d] → 0 when it names a secret file, in any letter case; d (a display command's
# file argument) adds the display-only names. nocasematch is on only for this call: the option
# grammar below tells -e from -E.
secret() { local s=0; shopt -s nocasematch; _secret "$@" || s=1; shopt -u nocasematch; return "$s"; }
_secret() {
  local r="${1##*/}"
  case "$r" in *.example|*.sample|*.template|*.dist) ;; .env|.env.*|key.properties|.*_history|fish_history) return 0 ;;
    .env*[\*\?\[]*) return 0 ;;   # a .env glob
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.p8|credentials*.json|secrets*.json|password) [ -n "${2:-}" ] && return 0 ;; esac
  case "$1" in .ssh/*|*/.ssh/*) return 0 ;; '~/'*|'$HOME/'*|'${HOME}/'*) r="${1#*/}" ;; /Users/*/*) r="${1#/[Uu][Ss][Ee][Rr][Ss]/*/}" ;; *) return 1 ;; esac
  case "$r" in .aws/*|.netrc|.npmrc|.pgpass|.config/gh/hosts.yml) return 0 ;; .codex/auth.json) [ -n "${2:-}" ] && return 0 ;; esac
  return 1
}
hits=""
# sed_awk <sed|awk> <index of its first argument>: the native macOS grammar, redirections aside.
# Options end at `--` or the first operand. sed clusters its short options (getopt EI:ae:f:i:lnru);
# awk reads one per word (-f -F -v). A value is the rest of its word, else the next word, even an
# empty one: -e program text, -i/-I backup extension and -F/-v value are data, -f is a script file
# (a read). Then come the program, unless -e/-f gave one, and the file operands (awk: not var=value).
sed_awk() {
  local r="$1" t o v kind k=0 prog=0
  local -a a=()
  for ((k=$2; k<${#seg[@]}; k++)); do [ "${seg_redirs[$k]}" = 1 ] || a+=("${seg[$k]}"); done
  k=0
  while [ "$k" -lt "${#a[@]}" ]; do
    t="${a[$k]}"; kind=""; v=""
    case "$t" in --) k=$((k+1)); break ;; -?*) k=$((k+1)) ;; *) break ;; esac
    case "$t" in
      --expression|--file|--field-separator|--assign) kind="$t"; v="${a[$k]:-}"; k=$((k+1)) ;;   # GNU long forms
      --expression=*|--file=*|--field-separator=*|--assign=*) kind="${t%%=*}"; v="${t#*=}" ;;
      --*) ;;
      *) t="${t#-}"
         while [ -n "$t" ]; do   # letter by letter, up to the first one that takes a value
           o="${t:0:1}"; t="${t:1}"
           case "$r$o" in
             sed[efiI]|awk[fFv]) kind="$o"; v="$t"; [ -n "$v" ] || { v="${a[$k]:-}"; k=$((k+1)); }; break ;;
             awk*) break ;;
           esac
         done ;;
    esac
    case "$kind" in e|--expression) prog=1 ;; f|--file) prog=1; secret "$v" d && hits="$hits $v" ;; esac
  done
  while [ "$k" -lt "${#a[@]}" ]; do
    t="${a[$k]}"; k=$((k+1))
    if [ "$prog" = 0 ]; then prog=1; continue; fi   # the program, not a file
    [ "$r" = awk ] && [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
    secret "$t" d && hits="$hits $t"
  done
}
check_seg() {
  local t c k d g=0 pat=1 skip=0
  for t in ${seg[@]+"${seg[@]}"}; do
    case "$t" in '<'*|[0-9]'<'*) secret "${t#*<}" && hits="$hits $t" ;; esac
  done
  cmd_start || return 0
  k=$((CMD_AT+1))
  case "${seg[$CMD_AT]##*/}" in
    history) hits="$hits history"; return 0 ;;
    cat|less|more|head|tail|bat|nl|strings|xxd|od|base64) ;;
    grep|egrep|fgrep|rg) g=1; pat=0 ;;
    sed|awk) sed_awk "${seg[$CMD_AT]##*/}" "$k"; return 0 ;;
    git) git_sub "$CMD_AT"; k=$GIT_ARG
         case "$GIT_SUB" in show|cat-file) ;; grep) g=1; pat=0 ;; *) return 0 ;; esac ;;
    *) return 0 ;;
  esac
  for t in "${seg[@]:$k}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$g$t" in
      1--regexp|1--file) pat=1; skip=1; continue ;;
      1--regexp=*|1--file=*) pat=1; continue ;;
      1--glob|1--iglob|1--type|1--type-not|1--include|1--exclude|1--exclude-dir|1--max-count|1--context|1--after-context|1--before-context|1--max-depth) skip=1; continue ;;   # long options whose value is the next word
      1-[A-Za-z]*)   # a short cluster up to its first value letter; e/f give the pattern
        c="${t#-}"; c="${c#"${c%%[efABCmgtT]*}"}"
        case "$c" in [ef]*) pat=1 ;; esac
        [ "${#c}" = 1 ] && skip=1   # the cluster ends with it: the next word is its value
        continue ;;
      ?-*) continue ;;
    esac
    if [ "$pat" = 0 ]; then pat=1; continue; fi   # the grep pattern, not a file
    case "$t" in *[\<\>]*) d="" ;; *) d=d ;; esac   # a redirection is not a file argument
    { secret "$t" "$d" || secret "${t#*:}" "$d"; } && hits="$hits $t"
  done
}
shell_tokens "$cmd"; segments check_seg
[ -z "$hits" ] && exit 0
echo "secrets-guard: blocked (${hits# }): global secrets guard (agent-ops-kit): don't print secret files; load them instead (source, --env-file)." >&2
exit 2
