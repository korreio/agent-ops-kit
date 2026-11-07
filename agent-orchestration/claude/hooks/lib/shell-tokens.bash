# shellcheck shell=bash
# Shared by the PreToolUse hooks (sourced, never run; install.sh --hooks links only the top-level
# *.sh, and each hook finds this file through its own resolved link). Heuristic, not a shell parser.
#
# shell_tokens <command> fills the array `toks`, with "$SEP" between commands (newline ; & | ( )
# backticks and an unquoted $( ). Quoted text is ONE token and is data: a commit message, and a
# "$(…)" inside double quotes with everything in it, is never read as a command. Heredoc bodies,
# quoted or not, are skipped. A redirection is one token with its fd and target (2>/dev/null,
# <.env, <<<word). A word starting with # ends the line; backslash-newline joins lines.
# $'…' is its own quote, where a backslash escapes the next character, so \' does not end it.
# `<<` inside arithmetic is a shift, not a heredoc. Unquoted, `ar` stacks the open parentheses, A
# for arithmetic ($(( and (( open two) and C for commands; its contents stay commands, because a
# $(…) can sit in there. Inside double quotes "$((…))" is data up to its last parenthesis.
# Not modelled: the deprecated $[…] and an offset such as ${x:1<<2}, where `<<` still reads as a heredoc.
# Scanned line by line, then word by word, in the C locale: bash 3.2 copies a string to index it,
# so a character loop over a long command is quadratic.
# segments <callback> calls <callback> once per command with its tokens in `seg`.
# `seg_redirs` marks real shell redirections; quoted comparison signs stay ordinary data.
SEP=$'\x1e'
_P0=$'[ \t\'"\\\\;&|()`$<>#]' _PD=$'["\\\\$]' _PS=$'[\'"\\\\()<$]' _PE=$'[\'\\\\]' _PA=$'[()]' _NB=$'[! \t]' _DT=$'[ \t;&|<>()]' _NT=$'[!\t]'
# Byte-wise matching for every hook that sources this file. It is set once here and never as a
# `local` or a command prefix: Homebrew bash 5.3 can crash with SIGSEGV while restoring a temporary
# locale variable when a signal lands, and a hook that crashes exits neither 0 nor 2, so the call
# would proceed unchecked.
LC_ALL=C
shell_tokens() {
  local IFS=$'\n' line w rest run c m hdp="" st="" ar="" tok="" intok=0 tok_redir=0 cont k
  local -a lines words hq=()
  toks=(); toks_redirs=()
  set -f; lines=($1); IFS=$' \t'
  for line in ${lines[@]+"${lines[@]}"}; do
    if [ "${#hq[@]}" -gt 0 ]; then                       # a heredoc body line: data
      w="${hq[0]}"; [ "${w:0:1}" = 1 ] && line="${line#"${line%%$_NT*}"}"
      [ "$line" = "${w:1}" ] && hq=(${hq[@]+"${hq[@]:1}"})
      continue
    fi
    words=($line); k=0; cont=0                           # word by word: no copy is longer than a word
    for w in ${words[@]+"${words[@]}"}; do
      k=$((k+1)); rest="$w"; [ "$k" -lt "${#words[@]}" ] && rest="$w "
      while [ -n "$rest" ]; do
        if [ -n "$hdp" ]; then                           # the heredoc delimiter, quotes removed
          rest="${rest#"${rest%%$_NB*}"}"; run="${rest%%$_DT*}"; rest="${rest:${#run}}"
          case "$run" in \$[\'\"]*) run="${run:1}" ;; esac   # <<$'EOF' ends at EOF
          run="${run//[\'\"\\]/}"; [ -n "$run" ] && { hq+=("$hdp$run"); hdp=""; }   # else: the next word
          [ -n "$rest" ] || break
        fi
        m="${st#"${st%?}"}"                              # mode: '' unquoted, D "…", S "$(…", Q '…', E $'…', A "$((…"
        case "$m" in Q) run="${rest%%\'*}" ;; D) run="${rest%%$_PD*}" ;; S) run="${rest%%$_PS*}" ;; E) run="${rest%%$_PE*}" ;; A) run="${rest%%$_PA*}" ;; *) run="${rest%%$_P0*}" ;; esac
        [ -n "$run" ] && { [ "${#tok}" -lt 4096 ] && tok="$tok$run"; intok=1; rest="${rest:${#run}}"; }   # no path or flag is longer
        [ -n "$rest" ] || break
        c="${rest:0:1}"; rest="${rest:1}"
        case "$m$c" in
          "Q'"|"E'"|'D"'|'S)'|'A)') st="${st%?}" ;;
          "'"|"S'") st="${st}Q"; intok=1 ;;
          '"'|'S"') st="${st}D"; intok=1 ;;
          'A(') st="${st}A" ;;
          'S(') if [ "${rest:0:1}" = '(' ]; then st="${st}AA"; rest="${rest:1}"; else st="${st}S"; fi ;;
          'S$') if [ "${rest:0:1}" = "'" ]; then st="${st}E"; rest="${rest:1}"; else tok="$tok\$"; fi ;;
          'D$') case "$rest" in
                  '(('*) st="${st}AA"; rest="${rest:2}"; tok="$tok\$((" ;;
                  '('*) st="${st}S"; rest="${rest:1}"; tok="$tok\$(" ;;
                  *) tok="$tok\$" ;;
                esac ;;
          '$') case "$rest" in
                 "'"*) st="${st}E"; rest="${rest:1}"; intok=1 ;;
                 '('*) rest="${rest:1}"; _cut; _open "$c" ;;
                 *) tok="$tok\$"; intok=1 ;;
               esac ;;
          '\'|'D\'|'S\'|'E\') if [ -z "$rest" ]; then cont=1; else tok="$tok${rest:0:1}"; intok=1; rest="${rest:1}"; fi ;;
          ' '|$'\t') [ "$intok" = 1 ] && _push_token; tok=""; intok=0; tok_redir=0 ;;
          '(') _cut; _open ;;
          ')') _cut; ar="${ar%?}" ;;
          ';'|'&'|'|'|'`') _cut ;;
          '#') if [ "$intok" = 1 ]; then tok="$tok#"; else break 2; fi ;;
          '<'|'>'|'S<')
            run="${rest%%[!<>&|]*}"; rest="${rest:${#run}}"
            if [ "$c$run" = '<<' ] && { [ -n "$m" ] || [ "${ar%A}" = "$ar" ]; }; then   # heredoc: its delimiter comes next
              [ -z "$m" ] && { [ "$intok" = 1 ] && _push_token; tok=""; intok=0; tok_redir=0; }
              hdp=0; [ "${rest:0:1}" = - ] && { hdp=1; rest="${rest:1}"; }
            elif [ -z "$m" ]; then                       # redirection: fd, operator and target
              case "$tok" in *[!0-9]*|'') [ "$intok" = 1 ] && _push_token; tok="" ;; esac
              tok="$tok$c$run"; intok=1; tok_redir=1; rest="${rest#"${rest%%$_NB*}"}"
            fi ;;
        esac
      done
    done
    case "${st#"${st%?}"}" in
      '') [ "$cont" = 1 ] || _cut ;;
      D|Q|E) [ "${#tok}" -lt 4096 ] && tok="$tok"$'\n' ;;
    esac
  done
  set +f; _cut
}
_push_token() { toks+=("$tok"); toks_redirs+=("$tok_redir"); }
_cut() { [ "$intok" = 1 ] && _push_token; tok=""; intok=0; tok_redir=0; toks+=("$SEP"); toks_redirs+=(0); }
_open() {   # one unquoted ( was read; $1 is set when it followed $. In arithmetic a plain ( only groups.
  if [ "${ar#"${ar%?}"}${1:-}" = A ]; then ar="${ar}A"
  elif [ "${rest:0:1}" = '(' ]; then ar="${ar}AA"; rest="${rest:1}"
  else ar="${ar}C"; fi
}
segments() {
  local t k=0
  seg=(); seg_redirs=()
  for t in ${toks[@]+"${toks[@]}"}; do
    if [ "$t" = "$SEP" ]; then "$1"; seg=(); seg_redirs=(); else seg+=("$t"); seg_redirs+=("${toks_redirs[$k]}"); fi
    k=$((k+1))
  done
}
# cmd_start → sets CMD_AT to the command word, past assignments, redirections, keywords
# (if then else elif while until do ! {) and wrappers (env sudo exec time nohup nice caffeinate
# timeout arch, also by path, with their options, option values and numbers); returns 1 for none
# and `command -v|-V`.
cmd_start() {
  local k=0 t w=""
  while [ "$k" -lt "${#seg[@]}" ]; do
    t="${seg[$k]}"
    case "$t" in
      -*) wrapper_value "$w" "$t" && k=$((k+1)) ;;
      [A-Za-z_]*=*|[0-9]*|*[\<\>]*|if|then|else|elif|while|until|do|!|\{) ;;
      *) w="${t##*/}"
         case "$w" in
           command) case "${seg[$((k+1))]:-}" in -v|-V) return 1 ;; esac ;;
           env|sudo|exec|time|nohup|nice|caffeinate|timeout|arch) ;;
           *) break ;;
         esac ;;
    esac
    k=$((k+1))
  done
  [ "$k" -lt "${#seg[@]}" ] && CMD_AT=$k
}
# wrapper_value <wrapper> <option> → 0 when the next word is that option's value. A short cluster is
# read up to its first value letter, which takes the next word only when it ends the cluster.
wrapper_value() {
  local v c
  case "$1:$2" in
    sudo:--user|sudo:--group|sudo:--host|sudo:--prompt|sudo:--chdir|sudo:--chroot|sudo:--close-from) return 0 ;;
    sudo:--command-timeout|sudo:--other-user|env:--unset|env:--chdir|timeout:--signal|timeout:--kill-after) return 0 ;;
    arch:-arch|arch:-d|arch:-e) return 0 ;;
    sudo:-[!-]*) v=CDghpRTUu ;;
    env:-[!-]*) v=CPu ;;
    timeout:-[!-]*) v=ks ;;
    exec:-[!-]*) v=a ;;
    time:-[!-]*) v=o ;;
    *) return 1 ;;
  esac
  c="${2#-}"; c="${c%%[$v]*}"
  [ "${#2}" = "$(( ${#c} + 2 ))" ]
}
# git_sub <i> → when seg[i] is git, sets GIT_SUB (the subcommand) and GIT_ARG (index of its first
# argument), past git's global options (-C <path>, -c k=v, …); returns 1 otherwise.
git_sub() {
  local j=$(( $1 + 1 ))
  [ "${seg[$1]##*/}" = git ] || return 1
  while [ "$j" -lt "${#seg[@]}" ]; do
    case "${seg[$j]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix|--exec-path) j=$((j+2)) ;;
      -*) j=$((j+1)) ;;
      *) break ;;
    esac
  done
  GIT_SUB="${seg[$j]:-}"; GIT_ARG=$((j+1))
}
