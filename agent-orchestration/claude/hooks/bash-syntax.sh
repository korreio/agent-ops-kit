#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write|MultiEdit). Runs `bash -n` on the edited file when its first
# line is a bash/sh shebang (#!/bin/bash, #!/bin/sh, #!/usr/bin/env bash, …), or when it has no
# shebang and ends in .sh or .bash. Any other shebang (zsh, python …) is skipped, even for a .sh.
# The check uses /opt/homebrew/bin/bash when it exists, else /bin/bash, so bash-4 syntax is not
# misreported. A syntax error exits 2 with the bash message on stderr, which Claude Code feeds back
# to Claude (the edit itself has already happened). Anything else, or a missing file, exits 0.
# Input: hook JSON on stdin (jq, else python3); if neither can read it, it warns and exits 0.
set -u
input=""; IFS= read -r -d "" input || true   # builtin read: works on a bare PATH
f="$(printf '%s' "$input" 2>/dev/null | jq -r '.tool_input.file_path // empty' 2>/dev/null ||
  printf '%s' "$input" 2>/dev/null | python3 -I -B -c 'import json,sys; sys.stdout.write((json.load(sys.stdin).get("tool_input") or {}).get("file_path") or "")' 2>/dev/null)" ||
  { echo "bash-syntax: cannot read the hook input (needs jq or python3); not checked" >&2; exit 0; }
[ -n "$f" ] && [ -f "$f" ] || exit 0

first=""; IFS= read -r first < "$f" || true
re='^#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$)'
case "$first" in
  '#!'*) [[ "$first" =~ $re ]] || exit 0 ;;
  *) case "$f" in *.sh|*.bash) ;; *) exit 0 ;; esac ;;
esac
b=/opt/homebrew/bin/bash; [ -x "$b" ] || b=/bin/bash
if ! out="$("$b" -n "$f" 2>&1)"; then
  printf 'bash-syntax: `bash -n %s` failed:\n%s\n' "$f" "$out" >&2
  exit 2
fi
exit 0
