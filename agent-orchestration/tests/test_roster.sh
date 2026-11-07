#!/usr/bin/env bash
# The roster (roster.md) is the one place a model is named. This suite fails when a copy differs:
#   1. every Claude Code roster row that names an agent has claude/agents/<agent>.md with the same
#      `model:` and `effort:`, and every agent file has a roster row;
#   2. each "Across families" pin equals the exact roster row it names;
#   3. the standing orders, the routed reference, the cross-review skills and the agent bodies name
#      no model, by id or by alias, and carry no `--model` / `--effort` flag with a value. The two
#      exceptions are an agent's `model:` line, and the roster pin itself: on a line of the routed
#      reference or the cross-review skill that names one launcher, that launcher's pin may stand
#      once, verbatim (`--model <model> --effort <effort>`) and set off by spaces, tabs, backticks
#      or the line's edge. A file that cannot be read is a failure, never a pass.
# The check reads text, line by line. It parses neither Markdown nor shell: what a shell would make
# of an example is outside it, and so is a document written to deceive it. What it catches is
# drift: a roster change that was not copied, a second flag, a model named in prose.
# Its limits: it does not require an example to carry a pin, though it expects at least two pinned
# examples in all. A model name is found by pattern: the roster's own names, `gpt` or `gemini`
# followed by a digit, and the aliases; a name written another way is not seen. A flag is found by
# the launchers' own spelling, `--model` and `--effort`; a model or an effort set another way is
# not seen.
# Read-only and hermetic: no provider CLI, no model call, no network; it writes nothing but the
# shell's own here-document temporaries.
# Optional argument: a package directory to check instead of this one (the mutation cases in
# tests/test_launchers.sh section 9 run it on scratch copies). Run:
# agent-orchestration/tests/test_roster.sh
set -uo pipefail
PKG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
R="$PKG/roster.md"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
[ -s "$R" ] || { echo "roster.md missing or empty at $R" >&2; exit 1; }

# rows <heading> -> the table rows under "## <heading>", cells trimmed and joined by tabs
rows() {
  awk -v h="## $1" '
    $0==h {on=1; next} /^## /{on=0}
    on && /^\|/ && $0 !~ /^\|[- |]+\|$/ {
      n=split($0,c,"|"); line=""
      for(i=2;i<n;i++){gsub(/^[ \t]+|[ \t]+$/,"",c[i]); gsub(/`/,"",c[i]); line=line (i>2?"\t":"") c[i]}
      if(++seen>1) print line
    }' "$R"
}
fm() { awk -v k="$2" 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} index($0,k": ")==1{print substr($0,length(k)+3); exit}' "$1"; }

echo "-- 1. Claude Code agent definitions equal the roster"
claude_rows="$(rows 'Claude Code')"; codex_rows="$(rows 'Codex')"
[ -n "$claude_rows" ] && ok "roster has Claude Code rows" || bad "roster has no Claude Code rows"
[ -n "$codex_rows" ] && ok "roster has Codex rows" || bad "roster has no Codex rows"
listed=" "
while IFS=$'\t' read -r role model effort agent _; do
  [ -n "$role" ] || continue
  [ "$agent" = "-" ] && continue
  f="$PKG/claude/agents/$agent.md"; listed="$listed$agent "
  if [ ! -f "$f" ]; then bad "$role: claude/agents/$agent.md exists"; continue; fi
  [ "$(fm "$f" name)" = "$agent" ] && ok "$agent: name" || bad "$agent: name is '$(fm "$f" name)'"
  [ "$(fm "$f" model)" = "$model" ] && ok "$agent: model $model" || bad "$agent: model is '$(fm "$f" model)', roster says '$model'"
  [ "$(fm "$f" effort)" = "$effort" ] && ok "$agent: effort $effort" || bad "$agent: effort is '$(fm "$f" effort)', roster says '$effort'"
done <<EOF
$claude_rows
EOF
for f in "$PKG"/claude/agents/*.md; do
  a="$(basename "$f" .md)"
  case "$listed" in *" $a "*) ok "$a: has a roster row";; *) bad "$a: agent file with no roster row";; esac
done

echo "-- 2. the cross-family pins equal the roster"
# row_pair <platform:role> -> "model effort" of that exact roster row, or empty
row_pair() {
  case "$1" in claude:*) src="$claude_rows";; codex:*) src="$codex_rows";; *) return 0;; esac
  printf '%s\n' "$src" | awk -F'\t' -v r="${1#*:}" '$1==r{print $2" "$3; exit}'
}
pin_codex=""; pin_claude=""    # what a codex-review / claude-review example must carry
families="$(rows 'Across families')"
[ -n "$families" ] && ok "roster has Across families rows" || bad "roster has no Across families rows"
while IFS=$'\t' read -r from row pins; do
  [ -n "$from" ] || continue
  want="$(row_pair "$row")"
  case "$from:$row" in
    Claude:codex:*)  who=codex;;
    Codex:claude:*)  who=claude;;
    *) bad "Across families: '$from' must name a row of the other platform, got '$row'"; continue;;
  esac
  [ -n "$want" ] || { bad "Across families, from $from: row '$row' is not in the roster"; continue; }
  # The whole cell is the row's pin and nothing else: a second flag in it is drift too.
  pin="--model ${want% *} --effort ${want#* }"
  if [ "$pins" = "$pin" ]; then ok "Across families, from $from: pins equal the $row row ($want)"
  else bad "Across families, from $from: the cell '$pins' is not the $row row's pin '$pin'"; fi
  if [ "$who" = codex ]; then pin_codex="$want"; else pin_claude="$want"; fi
done <<EOF
$families
EOF
[ -n "$pin_codex" ] && [ -n "$pin_claude" ] && ok "both cross-family pins are defined" || bad "a cross-family pin is missing (codex='$pin_codex' claude='$pin_claude')"
# check_document <file> <may carry examples: 0|1> -> one record per line of the report:
#   O <line> <text>   the line carries its launcher's roster pin
#   E <line> <text>   a `--model` / `--effort` stands outside that pin
#   H <line> <text>   a model is named outside that pin
# The pin is taken out of a line only where the file may carry examples, the line names exactly
# one launcher, and the pin stands there verbatim as whole words; it is taken out once. What is
# left of every line is then checked. Two notations stay legal for the flags: the bare flag in
# inline code (`--model`) and a placeholder value (`--model <slug>`).
check_document() {
  awk -v examples="$2" -v forbidden="$pat" \
      -v pc="--model ${pin_codex% *} --effort ${pin_codex#* }" \
      -v ph="--model ${pin_claude% *} --effort ${pin_claude#* }" '
    function without_pin(text, pin,    off, i, start, before, after) {
      off = 0
      while ((i = index(substr(text, off + 1), pin)) > 0) {
        start = off + i
        before = (start == 1) ? " " : substr(text, start - 1, 1)
        after = substr(text, start + length(pin), 1)
        if (before ~ /[ \t`]/ && (after == "" || after ~ /[ \t`]/)) {
          found = 1
          return substr(text, 1, start - 1) substr(text, start + length(pin))
        }
        off = start
      }
      return text
    }
    {
      text = $0; found = 0; who = ""
      if (examples) {
        c = index($0, "codex-review") > 0; h = index($0, "claude-review") > 0
        if (c && !h) { who = "codex"; text = without_pin($0, pc) }
        else if (h && !c) { who = "claude"; text = without_pin($0, ph) }
      }
      if (found) print "O\t" NR "\t" who " example carries the roster pin"
      rest = text
      while (match(rest, /--(model|effort)/)) {
        flag = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        if (rest ~ /^`/ || rest ~ /^[ \t]+</) continue
        print "E\t" NR "\t" flag " outside the roster pin"; break
      }
      if (tolower(text) ~ tolower(forbidden)) print "H\t" NR "\t" text
    }' "$1"
}

echo "-- 3. no model and no model or effort flag outside the roster pin"
names="$(printf '%s\n%s\n' "$claude_rows" "$codex_rows" | awk -F'\t' 'NF{print $2}' | sort -u | grep -vE '^(opus|sonnet|haiku|fable)$')"
pat="$(printf '%s\n' "$names" | paste -sd'|' -)"
pat="${pat:+$pat|}(gpt|gemini)[- ]?[0-9]|(^|[^A-Za-z])(opus|sonnet|haiku|fable)([^A-Za-z]|$)"
n=0
# scan <relative file> <label> [agent]: check the file once and report its pins, stray flags and
# names. An agent definition is checked without its `model:` line, which section 1 compares.
scan() {
  f="$PKG/$1"
  { [ -f "$f" ] && [ -r "$f" ]; } || { bad "$1 is a readable file"; return 0; }
  allow=0
  case "$1" in orchestration-reference.md|claude/skills/cross-review/SKILL.md) allow=1;; esac
  if [ "${3:-}" = agent ]; then report="$(sed -E 's/^model: .*$//' "$f" | check_document - 0)"; rc=$?
  else report="$(check_document "$f" "$allow")"; rc=$?; fi
  [ "$rc" -eq 0 ] || { bad "$1 could not be checked (awk exit $rc)"; return 0; }
  hits=""
  while IFS=$'\t' read -r kind number detail; do
    case "$kind" in
      O) n=$((n+1)); ok "$(basename "$f"):$number: $detail";;
      E) bad "$(basename "$f"):$number: $detail";;
      H) hits="$hits$number:$detail
";;
    esac
  done <<EOF
$report
EOF
  [ -z "$hits" ] && ok "$1 names no model$2" || bad "$1 names a model$2: $(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
}
scan standing-orders.md ""
scan orchestration-reference.md " outside its roster pins"
scan claude/skills/cross-review/SKILL.md " outside its roster pin"
[ "$n" -ge 2 ] && ok "found $n pinned examples" || bad "expected at least 2 pinned examples, found $n"
for f in "$PKG"/claude/agents/*.md; do
  scan "claude/agents/$(basename "$f")" " outside its model line" agent
done

echo "-- 4. native Codex roles equal the roster and fit counterpart budgets"
if python3 - "$PKG" "$pat" <<'PY_NATIVE'
import pathlib,re,sys,tomllib
pkg=pathlib.Path(sys.argv[1]); errors=[]
def check(ok,message):
    if not ok: errors.append(message)
rows={}; on=False
for line in (pkg/'roster.md').read_text().splitlines():
    if line=='## Codex': on=True; continue
    if line.startswith('## '): on=False
    if on and line.startswith('| '):
        row=[c.strip() for c in line.strip('|').split('|')]
        if row[0]!='Role': rows[row[0]]=tuple(row[1:3])
mapping={'reviewer':'reviewer-wide','reviewer-deep':'reviewer-deep','reviewer-wide':'reviewer-wide','escalation':'reviewer-deep','writer-bounded':'writer','writer-takeover':'writer','explorer-locate':'explorer-locate','explorer-trace':'explorer-trace','designer':'designer','verifier':'verifier','relay':'relay'}
check({'coordinator','reviewer','reviewer-deep','reviewer-wide','writer-bounded','writer-takeover','escalation'}<=set(rows),'required native roster row missing')
found={f.stem for f in (pkg/'codex/agents').glob('*.toml')}
check(found==set(mapping),'missing or unknown native role: '+str(found.symmetric_difference(mapping)))
for role,counterpart in mapping.items():
    path=pkg/'codex/agents'/f'{role}.toml'
    try:
        raw=path.read_bytes(); data=tomllib.loads(raw.decode())
        check(data.get('name')==role,role+': name')
        check(bool(data.get('description')),role+': description')
        check((data.get('model'),data.get('model_reasoning_effort'))==rows.get(role,rows.get('coordinator')),role+': roster pin')
        instructions=data.get('developer_instructions','')
        check(bool(instructions),role+': instructions')
        prose=re.sub(r'^model = .*$', '', raw.decode(),flags=re.M)
        check(not re.search(sys.argv[2],prose,re.I),role+': model in instructions or description')
        check('four fifths' in instructions and 'before ending' in instructions,role+': early report')
        check('sandbox_mode' not in data,role+': misleading native sandbox override')
        check('run this lane through' not in instructions,role+': worker self-launch instruction')
        counterpart_raw=(pkg/'claude/agents'/f'{counterpart}.md').read_bytes()
        check(len(raw)<=len(counterpart_raw) and len(raw.splitlines())<=len(counterpart_raw.splitlines()),role+': counterpart byte/line budget')
    except Exception as error: errors.append(role+': '+str(error))
try:
    config=tomllib.loads((pkg/'codex/config-fragment.toml').read_text())
    check((config.get('model'),config.get('model_reasoning_effort'))==rows.get('coordinator'),'native config: coordinator roster pins')
except Exception as error: errors.append('native config: '+str(error))
for error in errors: print(error,file=sys.stderr)
sys.exit(bool(errors))
PY_NATIVE
then ok "all native roles, pins, instructions and budgets"; else bad "native Codex role contract"; fi
scan codex/skills/cross-review/SKILL.md ""

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
