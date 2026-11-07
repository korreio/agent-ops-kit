#!/usr/bin/env bash
# Regression tests for `install.sh --agents`, `--hooks` and `--rules` (user-level Claude Code
# agents, hooks + the ~/.claude/settings.json merge, and ~/.claude/rules), for `--bin` (the
# launcher names in ~/.local/bin, the two writer names included), and for the read-only report of
# Codex's project_doc_max_bytes limit in the Codex section.
# Hermetic: every case runs its own COPY of the package (copied as tests/test_install_memory.sh does)
# against its own temp $HOME, so --apply's chmod, and any regression that writes into the package,
# hit the copy and never this checkout. PATH is a curated tool dir (with or without jq; macOS ships
# /usr/bin/jq, so /usr/bin itself is never on PATH). Nothing outside the temp dir is touched.
# Also guards the suites' own sandbox setup: with an unusable TMPDIR every suite must abort before
# arming its rm -rf trap. Run: agent-orchestration/tests/test_install_claude.sh
set -uo pipefail
unset CODEX_HOME CLAUDE_CONFIG_DIR   # a provider home of the caller's would refuse every target below
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAG="$PKG/claude/settings-fragment.json"
# Sandbox guard: never arm the rm -rf trap unless mktemp made a fresh directory under the temp root.
TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd)" || TMP_ROOT=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-orch-claude.XXXXXX" 2>/dev/null)" || TMP=""
{ [ -n "$TMP_ROOT" ] && [ -n "$TMP" ] && [ -d "$TMP" ] && TMP="$(cd "$TMP" && pwd)" && case "$TMP" in "$TMP_ROOT"/?*) true;; *) false;; esac; } \
  || { echo "cannot create a sandbox under ${TMPDIR:-/tmp}; aborting, nothing removed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — expected: $2"; fi; }

# Curated PATH: the tools install.sh uses, plus python3 for the inventory. JQBIN adds jq.
NOJQ="$TMP/tools-nojq"; JQBIN="$TMP/tools-jq"; mkdir -p "$NOJQ" "$JQBIN"
for t in bash env date mkdir mktemp basename dirname readlink cmp ln mv cp chmod rm wc tr sed cat head ls grep python3 stat diff rmdir; do
  p="$(command -v "$t")" || { echo "missing tool $t" >&2; exit 1; }
  ln -s "$p" "$NOJQ/$t"; ln -s "$p" "$JQBIN/$t"
done
JQ="$(command -v jq)" || { echo "jq is required to run this suite" >&2; exit 1; }
ln -s "$JQ" "$JQBIN/jq"
mkpath() { local f; mkdir -p "$1"; for f in "$JQBIN"/*; do ln -s "$(readlink "$f")" "$1/$(basename "$f")"; done; }  # JQBIN, to shim

setup() { # a fresh case: its own package copy P, HOME_T and settings path S
  CASE="$TMP/$1"; mkdir -p "$CASE/home/.claude" "$CASE/pkg"
  P="$(cd "$CASE/pkg" && pwd)"; cp -R "$PKG/." "$P/"; rm -rf "$P/memory/projects"
  HOME_T="$(cd "$CASE/home" && pwd)"; S="$HOME_T/.claude/settings.json"
}
run_install() { # $1 = PATH dir; rest = args. Output in OUT, exit code in RC.
  local p="$1"; shift
  # OUT is consumed by assertion strings through `check`/eval.
  # shellcheck disable=SC2034
  OUT="$(cd "$P" && HOME="$HOME_T" PATH="$p" ./install.sh "$@" 2>&1)"; RC=$?; return $RC
}
# Hash of a tree: every path with inode, type/mode, mtime and link target, plus every file's content.
tree_hash() {
  python3 -I -B - "$1" <<'PY_TREE'
import hashlib, json, os, stat, sys
root = os.path.realpath(sys.argv[1])
if not stat.S_ISDIR(os.stat(root).st_mode):
    raise NotADirectoryError(root)
def traversal_error(error):
    raise error
paths = [root]
for directory, dirs, files in os.walk(root, onerror=traversal_error):
    paths.extend(os.path.join(directory, name) for name in dirs + files)
digest = hashlib.sha256()
for path in sorted(paths, key=lambda p: os.fsencode(os.path.relpath(p, root))):
    info = os.lstat(path)
    link = os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
    content = None
    if stat.S_ISREG(info.st_mode):
        with open(path, 'rb') as handle:
            content = hashlib.sha256(handle.read()).hexdigest()
    record = [os.path.relpath(path, root), info.st_ino, info.st_mode,
              info.st_mtime_ns // 1_000_000_000, link, content]
    digest.update(json.dumps(record, separators=(',', ':')).encode() + b'\n')
print(digest.hexdigest())
PY_TREE
}
file_hash() {
  python3 -I -B - "$@" <<'PY_FILES'
import hashlib, os, sys
digest = hashlib.sha256()
for path in sys.argv[1:]:
    name = os.fsencode(path)
    with open(path, 'rb') as handle:
        content = hashlib.sha256(handle.read()).digest()
    digest.update(len(name).to_bytes(8, 'big') + name + content)
print(digest.hexdigest())
PY_FILES
}
capture_snapshot() {
  local destination="$1" value; shift
  value="$("$@")" || { echo "cannot capture snapshot $destination" >&2; exit 1; }
  [ -n "$value" ] || { echo "empty snapshot $destination" >&2; exit 1; }
  printf -v "$destination" '%s' "$value"
}
snapshot_matches() {
  local baseline="$1" current; shift
  [ -n "$baseline" ] || return 1
  current="$("$@")" || return 1
  [ -n "$current" ] && [ "$current" = "$baseline" ]
}
# Counts come from the fragment, never hard-coded: other changes add deny rules and hooks.
D0="$(jq -r '.permissions.deny[0]' "$FRAG")"   # the one fragment deny rule seed() already holds
n_frag="$(jq '[.permissions.deny[]] + [.hooks[][].hooks[]] | length' "$FRAG")"
n_deny="$(jq '.permissions.deny | length' "$FRAG")"
n_bash="$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]] | length' "$FRAG")"
seed() { # unrelated settings keys, an existing hook, one fragment deny rule already present, a real verifier.md
  jq -n --arg d "$D0" '{model: "opus", env: {X: "1"}, permissions: {allow: ["Bash(ls:*)"], deny: [$d]},
    hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "/opt/other-hook.sh"}]}],
            Stop: [{hooks: [{type: "command", command: "say done"}]}]}}' > "$S"
  mkdir -p "$HOME_T/.claude/agents" "$HOME_T/.claude/rules"
  cp "$P/claude/agents/verifier.md" "$HOME_T/.claude/agents/verifier.md"                  # identical
  cp "$P/claude/rules/00-sample-profile.md" "$HOME_T/.claude/rules/00-sample-profile.md"    # identical
  { cat "$P/claude/rules/10-sample-domain.md"; echo "- newer local line"; } > "$HOME_T/.claude/rules/10-sample-domain.md"  # differs
  printf 'local only\n' > "$HOME_T/.claude/rules/99-local.md"
}
no_tmp() { [ -z "$(ls -A "$HOME_T/.claude" | grep 'settings.json.tmp')" ]; }

echo "== install.sh --agents/--hooks/--rules regression matrix (sandbox: $TMP)"

echo "-- 1. --check writes nothing and lists exactly what --hooks would add"
setup c1; seed; capture_snapshot H0 tree_hash "$HOME_T"; capture_snapshot HP tree_hash "$P"
run_install "$JQBIN" --check
check "exit 0" "[ $RC -eq 0 ]"
check "HOME tree unchanged (hash with inodes and mtimes)" "snapshot_matches \"$H0\" tree_hash \"$HOME_T\""
check "package copy unchanged" "snapshot_matches \"$HP\" tree_hash \"$P\""
check "no backups dir" "[ ! -d \"$HOME_T/.claude/backups\" ]"
check "plans the settings merge" "echo \"\$OUT\" | grep -qF \"merge into $S (backup first; other keys untouched):\""
check "preview describes whole deny prepend and preserved duplicates" "echo \"\$OUT\" | grep -qF 'prepend complete fragment deny block ($n_deny rules); retain original deny array as unchanged suffix, including duplicates'"
check "lists a hook it would add" "echo \"\$OUT\" | grep -qF '+ hooks.PreToolUse[Bash]  \"\$HOME\"/.claude/hooks/git-staging-guard.sh'"
check "lists the already present deny rule because the complete block is prepended" "echo \"\$OUT\" | grep -qF '+ permissions.deny  $D0'"
check "reports the identical real verifier.md" "echo \"\$OUT\" | grep -q 'verifier.md (identical to the package copy)'"
check "warns on the differing rule" "echo \"\$OUT\" | grep -q 'rule 10-sample-domain.md: .* DIFFERS'"
check "keeps machine-local rules outside the kit" "echo \"\$OUT\" | grep -q '99-local.md is machine-local; keep private rules outside this kit'"

echo "-- 2. --apply --agents --hooks --rules: links, merge, backups, other keys kept"
INO0="$(stat -f %i "$S")"
jq '.permissions.deny' "$S" > "$CASE/owner-deny.json"
run_install "$JQBIN" --apply --agents --hooks --rules
check "exit 0" "[ $RC -eq 0 ]"
for f in "$P"/claude/agents/*.md; do b="$(basename "$f")"; check "agent $b linked" "[ \"\$(readlink \"$HOME_T/.claude/agents/$b\")\" = \"$f\" ]"; done
for f in "$P"/claude/hooks/*.sh; do b="$(basename "$f")"; case "$b" in test_*) check "test script $b not linked" "[ ! -e \"$HOME_T/.claude/hooks/$b\" ]"; continue;; esac
  check "hook $b linked" "[ \"\$(readlink \"$HOME_T/.claude/hooks/$b\")\" = \"$f\" ]"; done
check "lib not linked" "[ ! -e \"$HOME_T/.claude/hooks/lib\" ]"
check "settings.json is a regular file" "[ -f \"$S\" ] && [ ! -L \"$S\" ]"
check "unrelated keys preserved" "[ \"\$(jq -c '[.model,.env,.permissions.allow,.hooks.Stop]' \"$S\")\" = '[\"opus\",{\"X\":\"1\"},[\"Bash(ls:*)\"],[{\"hooks\":[{\"type\":\"command\",\"command\":\"say done\"}]}]]' ]"
check "existing hook kept first in its group" "[ \"\$(jq -r '.hooks.PreToolUse[0].hooks[0].command' \"$S\")\" = /opt/other-hook.sh ]"
check "Bash hooks merged into the existing Bash group" "[ \"\$(jq '[.hooks.PreToolUse[] | select(.matcher==\"Bash\")] | length' \"$S\")\" = 1 ] && [ \"\$(jq '.hooks.PreToolUse[0].hooks | length' \"$S\")\" = $((1 + n_bash)) ]"
check "PostToolUse bash-syntax added" "jq -e '.hooks.PostToolUse[] | select(.matcher==\"Edit|Write|MultiEdit\") | .hooks[] | select(.command==\"\\\"\$HOME\\\"/.claude/hooks/bash-syntax.sh\")' \"$S\" >/dev/null"
check "complete ordered fragment precedes the unchanged original owner array" "jq -e --slurpfile f \"$FRAG\" --slurpfile owner \"$CASE/owner-deny.json\" '.permissions.deny == (\$f[0].permissions.deny + \$owner[0])' \"$S\" >/dev/null"
BK="$(ls -d "$HOME_T/.claude/backups"/agent-orchestration-* 2>/dev/null | head -1)"
check "SessionStart roster-freshness added with its 5 s timeout" "[ \"\$(jq -c '[.hooks.SessionStart[] | select(.matcher==\"startup\") | .hooks[] | select(.command | endswith(\"roster-freshness.sh\")) | .timeout]' \"$S\")\" = '[5]' ]"
check "settings.json backed up with its original content" "grep -q '/opt/other-hook.sh' \"$BK\"/settings.json-* && ! grep -q 'brew-guards' \"$BK\"/settings.json-*"
check "the backup is a copy: the live file was never moved away (inode)" "[ \"\$(stat -f %i \"$BK\"/settings.json-*)\" != $INO0 ]"
check "the live file was replaced by one rename, not rewritten in place (inode)" "[ \"\$(stat -f %i \"$S\")\" != $INO0 ]"
check "no temp file left" "no_tmp"
check "real verifier.md backed up" "ls \"$BK\" | grep -q '^verifier.md-'"
check "identical rule linked, its real file backed up" "[ -L \"$HOME_T/.claude/rules/00-sample-profile.md\" ] && ls \"$BK\" | grep -q '^00-sample-profile.md-'"
check "differing rule left alone (real file, local line kept)" "[ ! -L \"$HOME_T/.claude/rules/10-sample-domain.md\" ] && grep -q 'newer local line' \"$HOME_T/.claude/rules/10-sample-domain.md\""
check "machine-local rule untouched" "[ -f \"$HOME_T/.claude/rules/99-local.md\" ] && [ ! -L \"$HOME_T/.claude/rules/99-local.md\" ]"
check "linked hook runs through its link and blocks" "printf '%s' '{\"tool_input\":{\"command\":\"git add -A\"}}' | \"$HOME_T/.claude/hooks/git-staging-guard.sh\" >/dev/null 2>&1; [ \$? -eq 2 ]"

echo "-- 3. second --apply is a no-op"
capture_snapshot H1 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --agents --hooks --rules
check "exit 0" "[ $RC -eq 0 ]"
check "0 planned changes" "echo \"\$OUT\" | grep -q '== done: 0 planned/applied'"
check "settings already complete" "echo \"\$OUT\" | grep -q 'already carries every hook and deny rule'"
check "HOME tree unchanged (no new backup, no rewrite, no temp file)" "snapshot_matches \"$H1\" tree_hash \"$HOME_T\""

echo "-- 4. no jq: --hooks FAILs, settings and hooks untouched; --agents in the same run still applies"
setup c4; seed; capture_snapshot SH file_hash "$S"
run_install "$NOJQ" --apply --hooks --agents
check "exit 1" "[ $RC -eq 1 ]"
check "FAIL names jq" "echo \"\$OUT\" | grep -q 'FAIL  jq absent'"
check "settings.json byte-identical" "snapshot_matches \"$SH\" file_hash \"$S\""
check "no hooks dir" "[ ! -e \"$HOME_T/.claude/hooks\" ]"
check "agents still linked" "[ -L \"$HOME_T/.claude/agents/verifier.md\" ]"
run_install "$NOJQ" --check
check "check mode without jq: WARN, exit 0" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q 'WARN  jq absent'"

echo "-- 5. unreadable, invalid or wrongly shaped settings.json: its own FAIL, checked before any hook is linked"
setup c5
printf '{"model":"opus"}\n' > "$S"; capture_snapshot SH file_hash "$S"; chmod 000 "$S"
run_install "$JQBIN" --apply --hooks; chmod 600 "$S"
check "unreadable: exit 1, FAIL cannot read" "[ $RC -eq 1 ] && echo \"\$OUT\" | grep -q 'FAIL  cannot read '"
check "unreadable: untouched, no hook linked" "snapshot_matches \"$SH\" file_hash \"$S\" && [ ! -e \"$HOME_T/.claude/hooks\" ]"
printf '{"model": "opus",\n' > "$S"; capture_snapshot SH file_hash "$S"
run_install "$JQBIN" --apply --hooks
check "invalid: exit 1, FAIL not valid JSON" "[ $RC -eq 1 ] && echo \"\$OUT\" | grep -q 'FAIL  .*settings.json is not valid JSON'"
check "invalid: untouched, no hook linked, no temp file" "snapshot_matches \"$SH\" file_hash \"$S\" && [ ! -e \"$HOME_T/.claude/hooks\" ] && no_tmp"
printf '[1,2]\n' > "$S"; capture_snapshot SH file_hash "$S"
run_install "$JQBIN" --apply --hooks
check "not an object: exit 1, FAIL exactly one JSON object" "[ $RC -eq 1 ] && echo \"\$OUT\" | grep -q 'FAIL  .*must hold exactly one JSON object'"
check "not an object: untouched, no hook linked" "snapshot_matches \"$SH\" file_hash \"$S\" && [ ! -e \"$HOME_T/.claude/hooks\" ]"

echo "-- 6. settings.json absent: created private, nothing else"
setup c6
run_install "$JQBIN" --apply --hooks
check "exit 0" "[ $RC -eq 0 ]"
check "created as a regular file with mode 600" "[ -f \"$S\" ] && [ \"\$(stat -f %Lp \"$S\")\" = 600 ]"
check "holds exactly the fragment's entries" "[ \"\$(jq '[.permissions.deny[]] + [.hooks[][].hooks[]] | length' \"$S\")\" = $n_frag ]"
check "fresh deny block retains the fragment order" "jq -e --slurpfile f \"$FRAG\" '.permissions.deny == \$f[0].permissions.deny' \"$S\" >/dev/null"

echo "-- 7. settings.json is a symlink: refused, link untouched"
setup c7; printf '{}\n' > "$CASE/elsewhere.json"; ln -s "$CASE/elsewhere.json" "$S"
run_install "$JQBIN" --apply --hooks
check "exit 1" "[ $RC -eq 1 ]"
check "still a symlink, target unchanged" "[ -L \"$S\" ] && [ \"\$(cat \"$CASE/elsewhere.json\")\" = '{}' ]"

echo "-- 8. --all never includes --agents, --hooks or --rules"
setup c8
run_install "$JQBIN" --apply --all
check "no agents, hooks or rules dir; settings.json not created" "[ ! -e \"$HOME_T/.claude/agents\" ] && [ ! -e \"$HOME_T/.claude/hooks\" ] && [ ! -e \"$HOME_T/.claude/rules\" ] && [ ! -e \"$S\" ]"
check "--help says so" "(cd \"$P\" && ./install.sh --help) | grep -q -- '--bin (never' && (cd \"$P\" && ./install.sh --help) | grep -q -- '--agents, --hooks or --rules'"

echo "-- 8b. --all leaves both global instruction loaders alone: each needs its own explicit selection"
setup c8b; mkdir -p "$HOME_T/.codex"
printf 'synthetic private Claude instruction\n' > "$HOME_T/.claude/CLAUDE.md"
printf 'synthetic private Codex instruction\n' > "$HOME_T/.codex/AGENTS.md"
capture_snapshot LH file_hash "$HOME_T/.claude/CLAUDE.md" "$HOME_T/.codex/AGENTS.md"
run_install "$JQBIN" --apply --all
check "exit 0, and its two targets ran" "[ $RC -eq 0 ] && [ -L \"$HOME_T/.local/bin/claude-review\" ] && [ -d \"$HOME_T/.claude/skills\" ]"
check "existing loaders stay real files, byte-identical" "[ ! -L \"$HOME_T/.claude/CLAUDE.md\" ] && [ ! -L \"$HOME_T/.codex/AGENTS.md\" ] && snapshot_matches \"$LH\" file_hash \"$HOME_T/.claude/CLAUDE.md\" \"$HOME_T/.codex/AGENTS.md\""
setup c8c
run_install "$JQBIN" --apply --all
check "absent loaders stay absent, and no Codex home appears" "[ $RC -eq 0 ] && [ ! -e \"$HOME_T/.claude/CLAUDE.md\" ] && [ ! -L \"$HOME_T/.claude/CLAUDE.md\" ] && [ ! -e \"$HOME_T/.codex\" ]"
check "--help no longer lists the loaders under --all" "(cd \"$P\" && ./install.sh --help) | grep -q -- '--skills --bin (never --global-claude-md, --codex-agents-md'"

echo "-- 9. settings.json must be one JSON object: a bare BOM or two documents FAIL untouched; empty or blank counts as {}"
setup c9
for kind in BOM two-documents; do
  case $kind in
    BOM) printf '\357\273\277' > "$S";;
    two-documents) printf '{"a":1}\n{"b":2}\n' > "$S";;
  esac
  capture_snapshot SH file_hash "$S"
  run_install "$JQBIN" --apply --hooks
  check "$kind: exit 1, FAIL exactly one JSON object" "[ $RC -eq 1 ] && echo \"\$OUT\" | grep -q 'FAIL  .*must hold exactly one JSON object'"
  check "$kind: byte-identical, no hook linked" "snapshot_matches \"$SH\" file_hash \"$S\" && [ ! -e \"$HOME_T/.claude/hooks\" ]"
done
printf '\357\273\277' > "$S"
run_install "$JQBIN" --check
check "check mode WARNs on a bare BOM instead of calling it complete" "echo \"\$OUT\" | grep -q 'WARN  .*must hold exactly one JSON object' && ! echo \"\$OUT\" | grep -q 'already carries'"
setup c9b
for kind in empty whitespace; do
  case $kind in empty) : > "$S";; whitespace) printf ' \n\t\r\n' > "$S";; esac
  run_install "$JQBIN" --check
  check "$kind: --check plans the whole fragment deny block" "echo \"\$OUT\" | grep -qF 'prepend complete fragment deny block ($n_deny rules)'"
  run_install "$JQBIN" --apply --hooks
  check "$kind: exit 0, merged as {} and written" "[ $RC -eq 0 ] && [ \"\$(jq '[.permissions.deny[]] + [.hooks[][].hooks[]] | length' \"$S\")\" = $n_frag ]"
done

echo "-- 10. settings.json changes between the read and the replace: FAIL, the newer file survives"
setup c10; seed; SHIM="$CASE/tools-cp"; mkpath "$SHIM"; rm "$SHIM/cp"
{ printf '#!/bin/bash\nS=%q\nREAL=%q\n' "$S" "$(command -v cp)"; cat <<'EOF'
# Another writer: right after install.sh copies settings.json (after its one read, before its
# replace), the live file is rewritten, once.
"$REAL" "$@" || exit
for a in "$@"; do
  if [ "$a" = "$S" ] && ! grep -q concurrent "$S"; then printf '%s\n' '{"concurrent":true}' > "$S"; fi
done
EOF
} > "$SHIM/cp"; chmod +x "$SHIM/cp"
run_install "$SHIM" --apply --hooks
check "exit 1" "[ $RC -eq 1 ]"
check "FAIL: changed while merging; re-run" "echo \"\$OUT\" | grep -q 'FAIL  settings.json changed while merging; re-run'"
check "the concurrent write survives" "[ \"\$(cat \"$S\")\" = '{\"concurrent\":true}' ]"
check "no temp file left (EXIT trap)" "no_tmp"
run_install "$JQBIN" --apply --hooks
check "a re-run merges into the newer file" "[ $RC -eq 0 ] && jq -e '.concurrent == true and (.hooks.PreToolUse | length) > 0' \"$S\" >/dev/null"

echo "-- 11. a DIFFERING agent or hook is left alone with a counted WARN, as a rule is"
setup c11; mkdir -p "$HOME_T/.claude/agents" "$HOME_T/.claude/hooks"
A="$HOME_T/.claude/agents/verifier.md"; HK="$HOME_T/.claude/hooks/brew-guards.sh"
{ cat "$P/claude/agents/verifier.md"; echo "local edit"; } > "$A"; { cat "$P/claude/hooks/brew-guards.sh"; echo "# local edit"; } > "$HK"
capture_snapshot AH file_hash "$A" "$HK"
run_install "$JQBIN" --apply --agents --hooks
check "exit 0 (a WARN is not a failed target)" "[ $RC -eq 0 ]"
check "one WARN each" "echo \"\$OUT\" | grep -q 'WARN  agent verifier.md: .* DIFFERS' && echo \"\$OUT\" | grep -q 'WARN  hook brew-guards.sh: .* DIFFERS'"
check "both still real files, byte-identical" "[ ! -L \"$A\" ] && [ ! -L \"$HK\" ] && snapshot_matches \"$AH\" file_hash \"$A\" \"$HK\""
check "counted: the summary's warnings equal the WARN lines" "[ \"\$(echo \"\$OUT\" | grep -c '^  WARN')\" = \"\$(echo \"\$OUT\" | sed -n 's/.*change(s), \([0-9]*\) warning(s).*/\1/p')\" ]"
check "the rest still linked, nothing backed up" "[ -L \"$HOME_T/.claude/agents/rule-reviewer.md\" ] && [ -L \"$HOME_T/.claude/hooks/secrets-guard.sh\" ] && [ ! -e \"$HOME_T/.claude/backups\" ]"

echo "-- 12. a ~/.claude/{agents,hooks,rules} that is a symlink or a file FAILs its target; the package stays intact"
setup c12; capture_snapshot HP tree_hash "$P"; mkdir -p "$CASE/elsewhere"
ln -s "$P/claude/agents" "$HOME_T/.claude/agents"      # a link into the package itself
ln -s "$CASE/elsewhere" "$HOME_T/.claude/hooks"
printf 'not a dir\n' > "$HOME_T/.claude/rules"
run_install "$JQBIN" --apply --agents --hooks --rules
check "exit 1" "[ $RC -eq 1 ]"
check "three FAILs: not a real directory" "[ \"\$(echo \"\$OUT\" | grep -c 'FAIL  .*not a real directory')\" -eq 3 ]"
check "package copy intact (tree hash)" "snapshot_matches \"$HP\" tree_hash \"$P\""
check "nothing linked through the hooks link, settings.json not created" "[ -z \"\$(ls -A \"$CASE/elsewhere\")\" ] && [ ! -e \"$S\" ]"
check "the rules file untouched" "[ \"\$(cat \"$HOME_T/.claude/rules\")\" = 'not a dir' ]"

echo "-- 13. two runs in the same second get separate backup dirs: no backup is overwritten"
setup c13; seed; DS="$CASE/tools-date"; mkpath "$DS"; rm "$DS/date"
printf '#!/bin/bash\necho 20260101-000000\n' > "$DS/date"; chmod +x "$DS/date"
run_install "$DS" --apply --hooks; RC1=$RC
jq 'del(.hooks.PostToolUse)' "$S" > "$CASE/s.json" && cat "$CASE/s.json" > "$S"   # the next run merges again
run_install "$DS" --apply --hooks
check "both runs exit 0" "[ $RC1 -eq 0 ] && [ $RC -eq 0 ]"
check "two backup dirs for the one timestamp" "[ \"\$(ls -d \"$HOME_T/.claude/backups\"/agent-orchestration-20260101-000000.* | wc -l | tr -d ' ')\" = 2 ]"
check "the first backup still holds the original settings" "[ \"\$(grep -L brew-guards \"$HOME_T/.claude/backups\"/agent-orchestration-*/settings.json-* | wc -l | tr -d ' ')\" = 1 ]"

echo "-- 14. ordered owner policies survive partial adoption and hook-only rewrites"
setup c14
# The final specific restriction must remain after the owner exception; the package .env example
# exception must also remain before the owner .env.example restriction. Repeated owner rules and
# an already adopted fragment string are deliberate: none may be removed or reconstructed.
jq -n --arg d "$D0" '{permissions:{deny:[$d,"Read(*.txt)","Read(!public*.txt)","Read(public-secret.txt)","Read(.env.example)","Read(public-secret.txt)",$d]}}' > "$S"
jq '.permissions.deny' "$S" > "$CASE/owner-deny.json"
run_install "$JQBIN" --apply --hooks
check "exit 0" "[ $RC -eq 0 ]"
check "fragment block is complete and ordered, owner suffix keeps order and duplicates" "jq -e --slurpfile f \"$FRAG\" --slurpfile owner \"$CASE/owner-deny.json\" '.permissions.deny == (\$f[0].permissions.deny + \$owner[0])' \"$S\" >/dev/null"
capture_snapshot H1 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --hooks
check "partial-adoption repeat exits 0 and changes nothing" "[ $RC -eq 0 ] && snapshot_matches \"$H1\" tree_hash \"$HOME_T\""

setup c14b
jq -n --slurpfile f "$FRAG" '{permissions:{deny:([$f[0].permissions.deny[0],"Read(*.txt)","Read(!public*.txt)","Read(public-secret.txt)"] + $f[0].permissions.deny + ["Read(public-secret.txt)"])},hooks:$f[0].hooks} | del(.hooks.PostToolUse)' > "$S"
jq '.permissions.deny' "$S" > "$CASE/owner-deny.json"
run_install "$JQBIN" --check
check "hook-only preview does not propose a deny prepend" "[ $RC -eq 0 ] && ! echo \"\$OUT\" | grep -q 'prepend complete fragment deny block' && ! echo \"\$OUT\" | grep -q '+ permissions.deny'"
run_install "$JQBIN" --apply --hooks
check "missing hook restored" "[ $RC -eq 0 ] && jq -e '.hooks.PostToolUse | length > 0' \"$S\" >/dev/null"
check "complete deny array remains verbatim through a hook rewrite" "jq -e --slurpfile owner \"$CASE/owner-deny.json\" '.permissions.deny == \$owner[0]' \"$S\" >/dev/null"
capture_snapshot H1 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --hooks
check "hook-only repeat exits 0 and changes nothing" "[ $RC -eq 0 ] && snapshot_matches \"$H1\" tree_hash \"$HOME_T\""

echo "-- 15. --memory never swallows the next option"
setup c15; capture_snapshot H0 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --memory --hooks
check "exit 2 with the usage error" "[ $RC -eq 2 ] && echo \"\$OUT\" | grep -q -- '--memory requires a repository path'"
check "nothing changed" "snapshot_matches \"$H0\" tree_hash \"$HOME_T\""

echo "-- 16. a logged-out codex or an absent CLI is an unreachable lane for the owner, never a login or install to run"
setup c16; CX="$CASE/tools-codex"; mkpath "$CX"
printf '#!/bin/bash\n[ "$1" = --version ] && echo codex-cli-fake\nexit 1\n' > "$CX/codex"; chmod +x "$CX/codex"
run_install "$CX" --check
check "WARN names the unreachable lane and the owner" "echo \"\$OUT\" | grep -qF 'WARN  codex: not logged in — lane unreachable; the owner runs codex login'"
check "no instruction to run the login" "! echo \"\$OUT\" | grep -qF 'run: codex login'"
check "absent claude: the owner installs and signs in, no install-and-authenticate order" "echo \"\$OUT\" | grep -qF 'WARN  claude: ABSENT — lane unreachable; the owner installs and signs in' && ! echo \"\$OUT\" | grep -q 'install and authenticate'"

echo "-- 17. every suite aborts on an unusable TMPDIR without removing its cwd"
if [ -z "${AO_SANDBOX_GUARD_CHILD:-}" ]; then
  for suite in "$PKG/tests/test_install_memory.sh" "$PKG/tests/test_launchers.sh" "$PKG/claude/hooks/test_hooks.sh" "$PKG/tests/test_install_claude.sh"; do
    w="$TMP/cwd-$(basename "$suite")"; mkdir -p "$w"; printf 'keep\n' > "$w/sentinel"
    (cd "$w" && AO_SANDBOX_GUARD_CHILD=1 TMPDIR="$TMP/no-such-dir" "$suite" >/dev/null 2>&1); rc=$?
    check "$(basename "$suite"): exit 1 and cwd kept" "[ $rc -eq 1 ] && [ -f \"$w/sentinel\" ]"
  done
fi

echo "-- 18. --bin links five names to three scripts: claude-write and codex-write share the review launchers"
# The writer names are links to claude_job.sh and codex_job.sh, and each script reads the name it is
# run by (claude_job.sh for its lane; codex_job.sh for its sandbox, which its lane then follows),
# so what --bin must get right is the NAME of each link and its target. The last cases run the
# installed links themselves, far enough to see which command answered: both writer names stop on
# a usage error before any provider is looked for, and the curated PATH holds none anyway.
setup c18; LB="$HOME_T/.local/bin"
run_install "$JQBIN" --check
check "--check plans the claude-write link to claude_job.sh" "echo \"\$OUT\" | grep -qF \"PLAN  link $LB/claude-write -> $P/bin/claude_job.sh\""
check "--check plans the codex-write link to codex_job.sh"   "echo \"\$OUT\" | grep -qF \"PLAN  link $LB/codex-write -> $P/bin/codex_job.sh\""
check "--check still plans the two review links"           "[ \"\$(echo \"\$OUT\" | grep -cE \"PLAN  link $LB/(claude|codex)-review -> $P/bin/\")\" = 2 ]"
check "--check names the writer links in the target's title" "echo \"\$OUT\" | grep -q -- '\\[--bin\\].*claude-write, codex-write'"
check "--check plans the session-ledger link"                "echo \"\$OUT\" | grep -qF \"PLAN  link $LB/session-ledger -> $P/bin/session_ledger.py\""
check "--check links nothing"                                "[ ! -e \"$LB\" ]"
run_install "$JQBIN" --apply --bin
check "--apply --bin: exit 0" "[ $RC -eq 0 ]"
check "--apply reports its work as APPLY, never as a plan" "echo \"\$OUT\" | grep -qF \"APPLY link $LB/claude-write -> $P/bin/claude_job.sh\" && ! echo \"\$OUT\" | grep -q '^  PLAN'"
for pair in claude-write:claude_job.sh codex-write:codex_job.sh claude-review:claude_job.sh codex-review:codex_job.sh session-ledger:session_ledger.py; do
  check "${pair%%:*} -> bin/${pair#*:}" "[ \"\$(readlink \"$LB/${pair%%:*}\")\" = \"$P/bin/${pair#*:}\" ]"
done
check "five links and nothing else in ~/.local/bin" "[ \"\$(ls \"$LB\" | wc -l | tr -d ' ')\" = 5 ]"
check "the installed session-ledger runs: its first line names the Claude side" "[ \"\$(HOME=\"$HOME_T\" PATH=\"$JQBIN:/usr/bin:/bin\" \"$LB/session-ledger\" 2026-01-01T00:00:00 | sed -n 1p | cut -c1-18)\" = 'CLAUDE: 0 sessions' ]"
printf 'a brief\n' > "$CASE/brief.md"
WOUT="$(PATH="$JQBIN" "$LB/codex-write" "$CASE/out" codex-write-validation "$CASE/brief.md" --sandbox read-only 2>&1)"; WRC=$?
check "the installed codex-write is the writer: --sandbox read-only is refused, naming codex-review" "[ $WRC -eq 2 ] && echo \"\$WOUT\" | grep -q 'use codex-review'"
ROUT="$(PATH="$JQBIN" "$LB/codex-review" "$CASE/out" codex-review-missing "$CASE/brief.md" --sandbox read-only 2>&1)"; RRC=$?
check "the installed codex-review takes the same option and stops only for want of a codex CLI" "[ $RRC -eq 125 ] && echo \"\$ROUT\" | grep -q 'codex not on PATH'"
WOUT="$(PATH="$JQBIN" "$LB/claude-write" "$CASE/out" claude-write-validation "$CASE/brief.md" --tools 'Read,Bash' 2>&1)"; WRC=$?
check "the installed claude-write is the writer: Bash in --tools is refused, naming --bash-allow" "[ $WRC -eq 2 ] && echo \"\$WOUT\" | grep -q -- '--bash-allow'"
ROUT="$(PATH="$JQBIN" "$LB/claude-review" "$CASE/refusal-out" claude-review-missing "$CASE/brief.md" --tools 'Read,Bash' 2>&1)"; RRC=$?
check "the installed claude-review refuses Bash before receipt creation" '[ $RRC -eq 2 ] && [ ! -e "$CASE/refusal-out/claude-review-missing.lane" ] && [ ! -e "$CASE/refusal-out" ]'
run_install "$JQBIN" --apply --bin
check "a second --apply --bin plans nothing" "echo \"\$OUT\" | grep -q '== done: 0 planned/applied'"
# install.sh --help must include the entire header after any target changes.
INST_HELP_LAST="$(awk 'NR>1 && !/^#/{print prev; exit} {prev=$0}' "$P/install.sh")"
INST_HELP_GOT="$(cd "$P" && ./install.sh --help | tail -1)"
check "install.sh --help ends on the last line of its header" '[ -n "$INST_HELP_LAST" ] && [ "$INST_HELP_GOT" = "$INST_HELP_LAST" ]'

echo "-- 19. the Codex section reports how much of a repository's AGENTS.md Codex loads; ~/.codex/config.toml is only read"
# Codex loads the first project_doc_max_bytes bytes of a repository's AGENTS.md (32768 when the
# key is absent) and says nothing about the rest. Section 3b reports the limit in force, warns
# when the key is absent and for each ~/Development/*/AGENTS.md over the limit. It is inventory:
# never a planned change, never an edit of config.toml, and no other value of that file printed.
sized() { printf "%${2}s" x > "$1"; }                       # a file of exactly $2 bytes
warns_counted() { [ "$(echo "$OUT" | grep -c '^  WARN')" = "$(echo "$OUT" | sed -n 's/.*change(s), \([0-9]*\) warning(s).*/\1/p')" ]; }
setup c19a                                                   # no ~/.codex/config.toml, no ~/Development
run_install "$JQBIN" --check
check "no config.toml: WARN, the key is not set and the default 32768 applies" "echo \"\$OUT\" | grep -q 'WARN  codex loads only the first 32768 bytes .*project_doc_max_bytes is not set in ~/.codex/config.toml'"
check "no ~/Development: an OK line, nothing to size"        "echo \"\$OUT\" | grep -q 'directory: no repository contract in the selected inventory root'"
check "the summary still counts every WARN line"             "warns_counted"

setup c19b; mkdir -p "$HOME_T/.codex" "$HOME_T/Development/small" "$HOME_T/Development/no-contract"
printf '%s\n' 'model = "do-not-print-this"' 'project_doc_max_bytes = 65_536   # raised by the owner' '' '[projects."/x"]' 'trust_level = "do-not-print-that"' > "$HOME_T/.codex/config.toml"
sized "$HOME_T/Development/small/AGENTS.md" 40000
capture_snapshot H0 tree_hash "$HOME_T"
run_install "$JQBIN" --check
check "key set: an OK line with the number and where it came from" "echo \"\$OUT\" | grep -q 'OK    codex loads the first 65536 bytes .*project_doc_max_bytes, set in ~/.codex/config.toml'"
check "key set: no WARN about a missing key"                 "! echo \"\$OUT\" | grep -q 'is not set in ~/.codex/config.toml'"
check "a contract under the limit is counted, not warned"    "echo \"\$OUT\" | grep -q 'OK    1 repository contract(s) .*none over the 65536-byte limit' && ! echo \"\$OUT\" | grep -q 'over the Codex limit'"
check "no other value of config.toml is printed"             "! echo \"\$OUT\" | grep -q 'do-not-print'"
check "--check leaves HOME as it was, config.toml included"  "snapshot_matches \"$H0\" tree_hash \"$HOME_T\""

setup c19c; mkdir -p "$HOME_T/.codex" "$HOME_T/Development/big" "$HOME_T/Development/edge" "$HOME_T/Development/linked" "$CASE/elsewhere"
printf 'project_doc_max_bytes = 50000\n' > "$HOME_T/.codex/config.toml"
sized "$HOME_T/Development/big/AGENTS.md" 50001              # one byte over
sized "$HOME_T/Development/edge/AGENTS.md" 50000             # exactly the limit: loaded whole
sized "$CASE/elsewhere/contract.md" 70000; ln -s "$CASE/elsewhere/contract.md" "$HOME_T/Development/linked/AGENTS.md"
run_install "$JQBIN" --check
check "a contract over the limit: WARN with folder, size and limit" "echo \"\$OUT\" | grep -qF 'WARN  contract over the Codex limit: big/AGENTS.md is 50001 bytes, the limit is 50000'"
check "a contract of exactly the limit is not over it"       "! echo \"\$OUT\" | grep -q 'edge/AGENTS.md'"
check "a symlinked contract is sized through the link"       "echo \"\$OUT\" | grep -qF 'WARN  contract over the Codex limit: linked/AGENTS.md is 70000 bytes, the limit is 50000'"
check "no none-over line when a contract is over"            "! echo \"\$OUT\" | grep -q 'none over'"
check "the summary counts these WARNs too"                   "warns_counted && [ \"\$(echo \"\$OUT\" | grep -c 'over the Codex limit')\" = 2 ]"

setup c19d; mkdir -p "$HOME_T/.codex" "$HOME_T/Development/t"
printf '%s\n' 'model = "x"' '' '[profiles.big]' 'project_doc_max_bytes = 99999' > "$HOME_T/.codex/config.toml"
sized "$HOME_T/Development/t/AGENTS.md" 40000
run_install "$JQBIN" --check
check "a key inside a table is not the top-level key: WARN, not set" "echo \"\$OUT\" | grep -q 'WARN  codex loads only the first 32768 bytes .*is not set'"
check "and the contract is measured against the default, not the table's number" "echo \"\$OUT\" | grep -qF 't/AGENTS.md is 40000 bytes, the limit is 32768' && ! echo \"\$OUT\" | grep -q 99999"

setup c19e; mkdir -p "$HOME_T/.codex"
printf 'project_doc_max_bytes = "plenty"\n' > "$HOME_T/.codex/config.toml"
run_install "$JQBIN" --check
check "a key that is not a plain integer: its own WARN, the value not printed" "echo \"\$OUT\" | grep -q 'WARN  codex: project_doc_max_bytes is set .* but not as a plain integer' && ! echo \"\$OUT\" | grep -q plenty && ! echo \"\$OUT\" | grep -q 'is not set'"

# --apply prints the same inventory with its Codex target, and it is never a change: config.toml
# keeps its bytes, and a second run plans nothing although the WARNs are still there.
setup c19f; mkdir -p "$HOME_T/.codex" "$HOME_T/Development/big"
printf 'project_doc_max_bytes = 50000\n' > "$HOME_T/.codex/config.toml"; capture_snapshot CS file_hash "$HOME_T/.codex/config.toml"
sized "$HOME_T/Development/big/AGENTS.md" 50001
run_install "$JQBIN" --apply --codex-agents-md
check "--apply --codex-agents-md reports the limit and the contract over it" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q 'OK    codex loads the first 50000 bytes' && echo \"\$OUT\" | grep -qF 'big/AGENTS.md is 50001 bytes'"
run_install "$JQBIN" --apply --codex-agents-md
check "a second --apply plans nothing, though the WARN is still printed: inventory is never a change" "echo \"\$OUT\" | grep -q '== done: 0 planned/applied' && echo \"\$OUT\" | grep -qF 'WARN  contract over the Codex limit: big/AGENTS.md'"
check "config.toml keeps its bytes through --apply"          "snapshot_matches \"$CS\" file_hash \"$HOME_T/.codex/config.toml\""

echo "-- 20. the Codex limit is read as TOML: right for any valid file, or \"could not read\" — never a wrong number"
# ~/.codex/config.toml is TOML, and a line that looks like the key is not always the key: it can
# sit inside a multi-line string, the real key can be quoted, and a string line can begin with
# "[". The installer parses the file with tomllib when the python3 on PATH has it, and otherwise
# follows it with its own statement reader, which answers only when it followed the whole file.
# Files a to i are read both ways; j, k and p both ways with a different right answer; l by the
# parser only; m, n and q by the line reader only; o once by a python3 that has no tomllib. Each
# case sizes one 40000-byte contract, so a wrong limit shows as a wrong verdict on it. What must never appear:
# a number that is not the top-level setting (99999), any other text of the file (do-not-print),
# or "not set" for a key that is set.
NOPY="$TMP/tools-nopython"; mkpath "$NOPY"; rm "$NOPY/python3"
OLDPY="$TMP/tools-oldpython"; mkpath "$OLDPY"; REALPY="$(readlink "$OLDPY/python3")"; rm "$OLDPY/python3"
{ printf '#!/bin/bash\nREAL=%q\n' "$REALPY"; cat <<'EOF'
# A python3 older than 3.11: it runs, and it has no tomllib (what /usr/bin/python3 is on macOS).
case "$*" in *tomllib*) exit 3;; esac
exec "$REAL" "$@"
EOF
} > "$OLDPY/python3"; chmod +x "$OLDPY/python3"
if PATH="$JQBIN" python3 -I -B -c 'import tomllib' 2>/dev/null; then HAVE_PARSER=1; else HAVE_PARSER=0; fi
# toml <case> <tool dir>: config.toml from stdin, one 40000-byte contract, one --check
toml() {
  setup "$1"; mkdir -p "$HOME_T/.codex" "$HOME_T/Development/big"
  cat > "$HOME_T/.codex/config.toml"; sized "$HOME_T/Development/big/AGENTS.md" 40000
  run_install "$2" --check
}
limit_ok()  { echo "$OUT" | grep -q "OK    codex loads the first $1 bytes .*set in ~/.codex/config.toml"; }
big_over()  { echo "$OUT" | grep -qF "big/AGENTS.md is 40000 bytes, the limit is $1"; }
big_under() { echo "$OUT" | grep -q "OK    1 repository contract(s) .*none over the $1-byte limit"; }
quiet()     { ! echo "$OUT" | grep -q 'do-not-print\|99999\|is not set in'; }
unread()    { echo "$OUT" | grep -q 'WARN  codex: could not read project_doc_max_bytes from ~/.codex/config.toml' && big_over 32768 && quiet && ! echo "$OUT" | grep -q 'OK    codex loads'; }
notint()    { echo "$OUT" | grep -q 'WARN  codex: project_doc_max_bytes is set .* but not as a plain integer' && big_over 32768 && quiet && ! echo "$OUT" | grep -q 'OK    codex loads'; }

for rd in parser line-reader; do
  if [ "$rd" = parser ]; then tools="$JQBIN"; else tools="$NOPY"; fi
  if [ "$rd" = parser ] && [ "$HAVE_PARSER" -ne 1 ]; then
    printf '  SKIP  %s\n' "the 13 parser cases of this section: the python3 on this PATH has no tomllib (3.11+). The same files follow with the line reader."
    continue
  fi
  toml "c20a-$rd" "$tools" <<'EOF'
developer_instructions = """
do-not-print: the next line is text, not a setting
project_doc_max_bytes = 99999
"""
project_doc_max_bytes = 32768
EOF
  check "$rd: the key text inside a multi-line string is not the setting" "limit_ok 32768 && big_over 32768 && quiet"
  toml "c20b-$rd" "$tools" <<'EOF'
developer_instructions = '''
C:\do-not-print\ a literal string keeps its backslashes
project_doc_max_bytes = 99999
'''
project_doc_max_bytes = 32768
EOF
  check "$rd: nor inside a literal multi-line string" "limit_ok 32768 && big_over 32768 && quiet"
  toml "c20c-$rd" "$tools" <<'EOF'
developer_instructions = """
[not a table] do-not-print
"""
project_doc_max_bytes = 65536
EOF
  check "$rd: a string line that begins with [ does not end the top level" "limit_ok 65536 && big_under 65536 && quiet"
  toml "c20d-$rd" "$tools" <<'EOF'
"project_doc_max_bytes" = 65536
EOF
  check "$rd: a double-quoted key is the key" "limit_ok 65536 && big_under 65536 && quiet"
  toml "c20e-$rd" "$tools" <<'EOF'
'project_doc_max_bytes' = 65536
EOF
  check "$rd: a single-quoted key is the key" "limit_ok 65536 && big_under 65536 && quiet"
  toml "c20f-$rd" "$tools" <<'EOF'
notify = ["bash", "-lc", "echo [not a table] # do-not-print"]
project_doc_fallback_filenames = [
  "CLAUDE.md",   # a comment with a ] bracket
  "[x]",
]
mcp = { command = "x", args = ["a]", "b"] }
note = "a = \"b\" [c] # do-not-print"
project_doc_max_bytes = 65_536   # raised
[profiles.big]
project_doc_max_bytes = 99999
EOF
  check "$rd: arrays, inline tables, comments and a later table are followed" "limit_ok 65536 && big_under 65536 && quiet"
  toml "c20g-$rd" "$tools" <<'EOF'
project_doc_max_bytes = 0x10000
EOF
  check "$rd: a hexadecimal integer is an integer" "limit_ok 65536 && big_under 65536"
  toml "c20h-$rd" "$tools" <<'EOF'
model = "do-not-print"
[project_doc_max_bytes]
x = 99999
EOF
  check "$rd: a table of that name is a set key, not an integer and not absent" "notint"
  toml "c20i-$rd" "$tools" <<'EOF'
project_doc_max_bytes.sub = 99999
EOF
  check "$rd: nor is a dotted key under that name" "notint"
done

# What only a parser can read, the line reader says it could not read. Never "not set", never a
# number: the key is spelled with an escape, or sits below an array that holds a multi-line string.
ESC_KEY='"project_doc_max\u005fbytes" = 65536'
if [ "$HAVE_PARSER" -eq 1 ]; then
  toml c20j-parser "$JQBIN" <<EOF
$ESC_KEY
EOF
  check "parser: a key spelled with an escape is the key" "limit_ok 65536 && big_under 65536"
  toml c20k-parser "$JQBIN" <<'EOF'
samples = [
  """
project_doc_max_bytes = 99999
""",
]
project_doc_max_bytes = 65536
EOF
  check "parser: a multi-line string inside an array is followed" "limit_ok 65536 && big_under 65536 && quiet"
  # Not valid TOML, in a way the line reader does not see (it does not validate numbers): with a
  # parser at hand the file is refused as a whole instead of being read leniently.
  toml c20l-parser "$JQBIN" <<'EOF'
project_doc_max_bytes = 65536
count = 12abc   # do-not-print
EOF
  check "parser: a file that is not valid TOML is not read at all" "unread && echo \"\$OUT\" | grep -q 'it is not valid TOML'"
fi
toml c20j-line-reader "$NOPY" <<EOF
$ESC_KEY
EOF
check "line-reader: a key spelled with an escape is not guessed at: could not read" "unread"
toml c20k-line-reader "$NOPY" <<'EOF'
samples = [
  """
project_doc_max_bytes = 99999
""",
]
project_doc_max_bytes = 65536
EOF
check "line-reader: a multi-line string inside an array is not followed: could not read" "unread"
toml c20m-line-reader "$NOPY" <<'EOF'
project_doc_max_bytes = 65536
notes = """
never closed do-not-print
EOF
check "line-reader: a string that never closes is not valid TOML: could not read" "unread"
toml c20n-line-reader "$NOPY" <<'EOF'
project_doc_max_bytes = 65536
broken = = 1
EOF
check "line-reader: a value that is no TOML value: could not read" "unread"
check "line-reader: the WARN says why, and that a python3 with tomllib would parse the file" "echo \"\$OUT\" | grep -q 'no python3 with tomllib is on PATH'"
# A python3 that runs but has no tomllib is the common case on macOS: the line reader answers.
toml c20o-old-python "$OLDPY" <<'EOF'
developer_instructions = """
project_doc_max_bytes = 99999
"""
project_doc_max_bytes = 32768
EOF
check "python3 without tomllib: the line reader takes over and is right" "limit_ok 32768 && big_over 32768 && quiet"
# A basic multi-line string may escape its own quotes. The first line below does NOT close the
# string (the backslash escapes one quote), so the key text on the second line is still text and
# the key is absent. A reader that took the first line for a closed string would report 99999.
# The parser knows; the line reader does not decide a line that holds a backslash and a delimiter.
ESC_STRING='a = """x\"""
project_doc_max_bytes = 99999
b = """ # """'
if [ "$HAVE_PARSER" -eq 1 ]; then
  toml c20p-parser "$JQBIN" <<EOF
$ESC_STRING
EOF
  check "parser: an escaped quote does not close a string: the key is absent" "echo \"\$OUT\" | grep -q 'project_doc_max_bytes is not set in ~/.codex/config.toml' && big_over 32768 && ! echo \"\$OUT\" | grep -q 99999"
fi
toml c20p-line-reader "$NOPY" <<EOF
$ESC_STRING
EOF
check "line-reader: an escaped quote beside a delimiter is not decided: could not read" "unread"
# The most common real file: the key is not set at top level. Only the line reader's answer is
# checked here; section 19 checks the same file through whichever reader this PATH gives.
toml c20q-line-reader "$NOPY" <<'EOF'
model = "x"

[profiles.big]
project_doc_max_bytes = 99999
EOF
check "line-reader: a key only inside a table is not set: the default applies" "echo \"\$OUT\" | grep -q 'WARN  codex loads only the first 32768 bytes .*is not set' && big_over 32768 && ! echo \"\$OUT\" | grep -q 99999"

echo "-- 21. omitted marketplace installation option is not a runnable target"
setup c21; capture_snapshot H0 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --codex-plugin
check "omitted target exits 2 before any mutation" "[ $RC -eq 2 ] && snapshot_matches \"$H0\" tree_hash \"$HOME_T\""

echo "-- 22. standalone global Claude target owns its fresh parent directory"
setup c22; rm -rf "$HOME_T/.claude"
run_install "$JQBIN" --check
check "fresh-home preview creates no Claude parent" "[ $RC -eq 0 ] && [ ! -e \"$HOME_T/.claude\" ]"
run_install "$JQBIN" --apply --global-claude-md
check "standalone apply creates parent and expected loader link" "[ $RC -eq 0 ] && [ -d \"$HOME_T/.claude\" ] && [ \"\$(readlink \"$HOME_T/.claude/CLAUDE.md\")\" = \"$P/standing-orders.md\" ]"
capture_snapshot H0 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --global-claude-md
check "standalone repeated apply is idempotent" "[ $RC -eq 0 ] && snapshot_matches \"$H0\" tree_hash \"$HOME_T\""

echo "-- 23. private instruction guidance never invites copying into product source"
setup c23; mkdir -p "$HOME_T/.codex" "$HOME_T/.claude/rules"
printf 'synthetic private Claude instruction\n' > "$HOME_T/.claude/CLAUDE.md"
printf 'synthetic private Codex instruction\n' > "$HOME_T/.codex/AGENTS.md"
printf 'synthetic machine-local rule\n' > "$HOME_T/.claude/rules/99-local.md"
capture_snapshot H0 tree_hash "$HOME_T"; capture_snapshot HP tree_hash "$P"
run_install "$JQBIN" --check
check "preview keeps existing private loaders and product tree unchanged" "[ $RC -eq 0 ] && snapshot_matches \"$H0\" tree_hash \"$HOME_T\" && snapshot_matches \"$HP\" tree_hash \"$P\""
check "private composition guidance points outside the kit and permits omitting each target" "echo \"\$OUT\" | grep -q 'keep personal instructions outside this kit' && echo \"\$OUT\" | grep -q 'omit --global-claude-md to preserve this loader' && echo \"\$OUT\" | grep -q 'omit --codex-agents-md to preserve this loader'"
check "machine-local rule stays outside kit" "echo \"\$OUT\" | grep -q '99-local.md is machine-local; keep private rules outside this kit'"
check "no invitation to merge private content into tracked source" "! echo \"\$OUT\" | grep -Eq 'merge any personal|add it to claude/rules/'"
check "private loader contents are not printed" "! echo \"\$OUT\" | grep -Eq 'synthetic private|synthetic machine-local'"
run_install "$JQBIN" --apply --global-claude-md --codex-agents-md
BK="$(ls -d "$HOME_T/.claude/backups"/agent-orchestration-* 2>/dev/null | head -1)"
check "explicit apply retains loader linking semantics" "[ $RC -eq 0 ] && [ \"\$(readlink \"$HOME_T/.claude/CLAUDE.md\")\" = \"$P/standing-orders.md\" ] && [ \"\$(readlink \"$HOME_T/.codex/AGENTS.md\")\" = \"$P/standing-orders.md\" ]"
check "explicit apply backs up both original private loaders" "grep -q 'synthetic private Claude instruction' \"$BK\"/CLAUDE.md-* && grep -q 'synthetic private Codex instruction' \"$BK\"/AGENTS.md-*"
check "explicit apply never imports private instructions into product tree" "snapshot_matches \"$HP\" tree_hash \"$P\""


echo "-- 24. inventory and explicit removal previews never execute MCP"
setup c24; TOOLS="$CASE/tools"; mkpath "$TOOLS"
cat > "$TOOLS/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/provider-calls"
[ "$1" = --version ] && { echo fixture; exit 0; }
[ "$1" = mcp ] && exit 0
exit 1
EOF
chmod +x "$TOOLS/claude"
run_install "$TOOLS" --check --remove-codex-mcp
check "preview calls version only" "[ $RC -eq 0 ] && [ \"\$(cat \"$HOME_T/provider-calls\")\" = --version ]"
run_install "$TOOLS" --apply --remove-codex-mcp
check "explicit apply performs MCP lookup and removal" "[ $RC -eq 0 ] && grep -qx 'mcp get codex' \"$HOME_T/provider-calls\" && grep -qx 'mcp remove codex -s user' \"$HOME_T/provider-calls\""

echo "-- 25. skills preserve differing directories and refuse symlink parents"
setup c25; skill="$(basename "$(find "$P/claude/skills" -mindepth 1 -maxdepth 1 -type d | head -1)")"
mkdir -p "$HOME_T/.claude/skills"; cp -R "$P/claude/skills/$skill" "$HOME_T/.claude/skills/$skill"
printf 'owner edit\n' >> "$HOME_T/.claude/skills/$skill/SKILL.md"
run_install "$JQBIN" --apply --skills
check "differing skill directory is preserved" "[ $RC -eq 0 ] && [ ! -L \"$HOME_T/.claude/skills/$skill\" ] && grep -q 'owner edit' \"$HOME_T/.claude/skills/$skill/SKILL.md\" && echo \"\$OUT\" | grep -q 'DIFFERS'"
setup c25-identical; mkdir -p "$HOME_T/.claude/skills"; cp -R "$P/claude/skills/$skill" "$HOME_T/.claude/skills/$skill"
run_install "$JQBIN" --apply --skills
check "identical directory is backed up and linked" "[ $RC -eq 0 ] && [ -L \"$HOME_T/.claude/skills/$skill\" ] && [ -d \"$HOME_T/.claude/backups\" ]"
setup c25-parent; mkdir "$CASE/outside"; ln -s "$CASE/outside" "$HOME_T/.claude/skills"
run_install "$JQBIN" --apply --skills
check "symlink parent refused without outside writes" "[ $RC -eq 1 ] && [ -z \"\$(ls -A \"$CASE/outside\")\" ]"

echo "-- 26. bounded contract root inventory works without Python"
setup c26; mkdir -p "$CASE/projects/large" "$HOME_T/Development/excluded"
sized "$CASE/projects/large/AGENTS.md" 40000; sized "$HOME_T/Development/excluded/AGENTS.md" 40000
run_install "$NOPY" --check --contracts-root "$CASE/projects"
check "missing Python inventory completes" '[ $RC -eq 0 ] && echo "$OUT" | grep -q "WARN  python3: ABSENT" && echo "$OUT" | grep -q "== done:"'
check "only selected contract root inventoried" 'echo "$OUT" | grep -q "large/AGENTS.md is 40000" && ! echo "$OUT" | grep -q "excluded/AGENTS.md"'

# A selected memory target still needs Python before any other target can mutate HOME.
setup c26-memory; capture_snapshot H0 tree_hash "$HOME_T"; capture_snapshot HP tree_hash "$P"
run_install "$NOPY" --apply --bin --memory-root "$CASE/store" --memory "$CASE/project"
check "missing Python for memory refuses before mutation" '[ $RC -eq 2 ] && echo "$OUT" | grep -q -- "--memory needs python3" && snapshot_matches "$H0" tree_hash "$HOME_T" && snapshot_matches "$HP" tree_hash "$P"'

echo "-- 27. retired AGY flags refuse before providers, native install or mutation"
for flag in --agy --agy-rules --agy-allowlist; do
  for selection in --bin --codex-config; do
    setup "c27-${flag#--}-${selection#--}"; TOOLS="$CASE/tools"; mkpath "$TOOLS"
    for provider in claude codex agy python3; do
      rm -f "$TOOLS/$provider"
      cat > "$TOOLS/$provider" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/provider-calls"
exit 99
EOF
      chmod +x "$TOOLS/$provider"
    done
    capture_snapshot H0 tree_hash "$HOME_T"; capture_snapshot HP tree_hash "$P"
    run_install "$TOOLS" --apply "$selection" "$flag"
    check "$flag with $selection refuses unknown usage" '[ $RC -eq 2 ] && echo "$OUT" | grep -q "unknown arg: $flag"'
    check "$flag with $selection invokes no provider or native installer" '[ ! -e "$HOME_T/provider-calls" ]'
    check "$flag with $selection leaves home and package intact" 'snapshot_matches "$H0" tree_hash "$HOME_T" && snapshot_matches "$HP" tree_hash "$P"'
  done
done

echo "-- 28. supported installation preserves stale synthetic AGY artifacts without pruning"
setup c28
mkdir -p "$HOME_T/.local/bin" "$HOME_T/.claude/skills" "$HOME_T/.gemini/config/agents" "$HOME_T/.gemini/config/rules" "$HOME_T/.gemini/antigravity-cli"
ln -s "$CASE/old-kit/bin/agy_job.sh" "$HOME_T/.local/bin/agy-review"
ln -s "$CASE/old-kit/claude/skills/agy-reviewer" "$HOME_T/.claude/skills/agy-reviewer"
printf 'synthetic old reviewer\n' > "$HOME_T/.gemini/config/agents/read-only-reviewer.md"
printf 'synthetic old standing orders\n' > "$HOME_T/.gemini/config/rules/agent-orchestration-standing-orders.md"
printf '{"owner":"unrelated","permissions":{"allow":["command(owner)"]}}\n' > "$HOME_T/.gemini/antigravity-cli/settings.json"
printf 'unrelated owner data\n' > "$HOME_T/.gemini/keep.txt"
capture_snapshot AG0 tree_hash "$HOME_T/.gemini"
run_install "$JQBIN" --check
check "preview preserves all old and unrelated home artifacts" '[ $RC -eq 0 ] && snapshot_matches "$AG0" tree_hash "$HOME_T/.gemini" && [ "$(readlink "$HOME_T/.local/bin/agy-review")" = "$CASE/old-kit/bin/agy_job.sh" ] && [ "$(readlink "$HOME_T/.claude/skills/agy-reviewer")" = "$CASE/old-kit/claude/skills/agy-reviewer" ]'
run_install "$JQBIN" --apply --all
check "supported apply preserves old copied AGY files and unrelated data" '[ $RC -eq 0 ] && snapshot_matches "$AG0" tree_hash "$HOME_T/.gemini"'
check "supported apply preserves old AGY links even when dangling" '[ "$(readlink "$HOME_T/.local/bin/agy-review")" = "$CASE/old-kit/bin/agy_job.sh" ] && [ "$(readlink "$HOME_T/.claude/skills/agy-reviewer")" = "$CASE/old-kit/claude/skills/agy-reviewer" ]'
check "supported apply adds five links alongside the old review link" '[ "$(ls "$HOME_T/.local/bin" | wc -l | tr -d " ")" = 6 ] && [ -L "$HOME_T/.local/bin/claude-write" ] && [ -L "$HOME_T/.local/bin/codex-write" ] && [ -L "$HOME_T/.local/bin/session-ledger" ]'
capture_snapshot H0 tree_hash "$HOME_T"
run_install "$JQBIN" --apply --all
check "repeated supported apply preserves the complete installed home" '[ $RC -eq 0 ] && snapshot_matches "$H0" tree_hash "$HOME_T"'

echo "-- 29. a relative invocation under CDPATH keeps one package path"
# Only a relative path reproduces this: cd prints the directory it found through CDPATH, and the
# installer's own \$(cd ... && pwd) would capture that line too.
setup c29; skill="$(basename "$(find "$P/claude/skills" -mindepth 1 -maxdepth 1 -type d | head -1)")"
OUT="$(cd "$CASE" && HOME="$HOME_T" PATH="$JQBIN" CDPATH=. bash pkg/install.sh --apply --skills 2>&1)"; RC=$?
check "exit 0 and one package path in the banner" "[ $RC -eq 0 ] && [ \"\$(echo \"\$OUT\" | sed -n 2p)\" = '-- 1. tools' ]"
check "the skill links to the real package path" "[ \"\$(readlink \"$HOME_T/.claude/skills/$skill\")\" = \"$P/claude/skills/$skill\" ]"
if [ "$HAVE_PARSER" -eq 1 ]; then
  OUT="$(cd "$CASE" && HOME="$HOME_T" PATH="$JQBIN" CDPATH=. bash pkg/install.sh --codex-config 2>&1)"; RC=$?
  check "native targets find their helper the same way" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q '== native Codex done'"
fi

echo "-- 30. a provider home away from the default refuses that provider's selected targets"
# Hook commands hard-code \$HOME/.claude and \$HOME/.codex, so neither variable is honoured.
run_env() { # $1 = VAR=value for this run; rest = args. Output in OUT, exit code in RC.
  local setting="$1"; shift
  # OUT is consumed by assertion strings through `check`/eval.
  # shellcheck disable=SC2034
  OUT="$(cd "$P" && env "$setting" HOME="$HOME_T" PATH="$JQBIN" ./install.sh "$@" 2>&1)"; RC=$?; return $RC
}
refused() { # $1 = variable, then VAR=value and args: exit 2, the variable named, home and package intact
  local name="$1"; shift
  run_env "$@"
  check "$name with ${*:2} refuses, naming it" "[ $RC -eq 2 ] && echo \"\$OUT\" | grep -q '^$name names another directory'"
  check "$name with ${*:2} changes nothing" "snapshot_matches \"$H0\" tree_hash \"$HOME_T\" && snapshot_matches \"$HP\" tree_hash \"$P\""
}
setup c30; ELSE_HOME="$CASE/elsewhere"; mkdir "$ELSE_HOME"; capture_snapshot H0 tree_hash "$HOME_T"; capture_snapshot HP tree_hash "$P"
for target in --skills --agents --hooks --rules --global-claude-md --all; do refused CLAUDE_CONFIG_DIR "CLAUDE_CONFIG_DIR=$ELSE_HOME" --apply "$target"; done
refused CLAUDE_CONFIG_DIR "CLAUDE_CONFIG_DIR=$ELSE_HOME" --apply --memory-root "$CASE/store" --memory "$CASE"
refused CLAUDE_CONFIG_DIR "CLAUDE_CONFIG_DIR=$ELSE_HOME" --check
for target in --codex-agents-md --codex-agents --codex-hooks --codex-skills --codex-config --codex-coordinator; do refused CODEX_HOME "CODEX_HOME=$ELSE_HOME" --apply "$target"; done
refused CODEX_HOME "CODEX_HOME=$ELSE_HOME" --codex-config
refused CODEX_HOME "CODEX_HOME=$ELSE_HOME" --check
setup c30-other; ELSE_HOME="$CASE/elsewhere"; mkdir "$ELSE_HOME"
run_env "CODEX_HOME=$ELSE_HOME" --apply --skills
check "CODEX_HOME does not concern a Claude target" "[ $RC -eq 0 ] && [ -d \"$HOME_T/.claude/skills\" ]"
run_env "CLAUDE_CONFIG_DIR=$ELSE_HOME" --apply --codex-agents-md
check "CLAUDE_CONFIG_DIR does not concern a Codex target" "[ $RC -eq 0 ] && [ -L \"$HOME_T/.codex/AGENTS.md\" ]"
if [ "$HAVE_PARSER" -eq 1 ]; then
  run_env "CLAUDE_CONFIG_DIR=$ELSE_HOME" --check --codex-config
  check "nor does a native preview, although a preview selects every other target" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q '== native Codex done'"
fi
for setting in "CODEX_HOME=$ELSE_HOME" "CLAUDE_CONFIG_DIR=$ELSE_HOME"; do
  run_env "$setting" --apply --bin
  check "${setting%%=*} does not concern --bin, which links outside both homes" "[ $RC -eq 0 ] && [ -L \"$HOME_T/.local/bin/claude-review\" ]"
done
setup c30-same; ln -s "$HOME_T/.claude" "$CASE/claude-alias"; mkdir "$HOME_T/.codex"; ln -s "$HOME_T/.codex" "$CASE/codex-alias"
for setting in "CLAUDE_CONFIG_DIR=$HOME_T/.claude" "CLAUDE_CONFIG_DIR=$HOME_T/.claude/" "CLAUDE_CONFIG_DIR=$CASE/claude-alias" "CLAUDE_CONFIG_DIR=" \
               "CODEX_HOME=$HOME_T/.codex" "CODEX_HOME=$HOME_T/.codex/" "CODEX_HOME=$CASE/codex-alias" "CODEX_HOME="; do
  run_env "$setting" --check
  check "${setting##*/} naming the default home, or empty, proceeds" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q '== done:'"
done

echo "-- 31. the inventory warns about a python3 below 3.11 and carries on"
fake_python() { # $1 = tool dir, $2 = version it answers as; below 3.11 it has no tomllib either
  rm -f "$1/python3"
  { printf '#!/bin/bash\nREAL=%q\nV=%q\n' "$REALPY" "$2"; cat <<'EOF'
case "$V" in 3.[0-9].*|3.10.*) old=1;; *) old=0;; esac
[ "$1" = --version ] && { echo "Python $V"; exit 0; }
case "$*" in *version_info*) exit "$old";; *tomllib*) [ "$old" -eq 0 ] || exit 3;; esac
exec "$REAL" "$@"
EOF
  } > "$1/python3"; chmod +x "$1/python3"
}
for version in 3.9.6 3.10.14; do
  setup "c31-$version"; PYT="$CASE/tools-python"; mkpath "$PYT"; fake_python "$PYT" "$version"
  run_install "$PYT" --check
  check "$version: a WARN, not an OK, and the run still ends cleanly" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -qF 'WARN  python3: Python $version is below 3.11' && ! echo \"\$OUT\" | grep -q 'OK    python3' && echo \"\$OUT\" | grep -q '== done:'"
  check "$version: names what needs 3.11+" "echo \"\$OUT\" | grep 'WARN  python3' | grep -q 'native Codex targets .*codex-review, codex-write'"
  check "$version: the summary counts that WARN" "warns_counted"
done
for version in 3.11.0 3.14.7; do
  setup "c31-$version"; PYT="$CASE/tools-python"; mkpath "$PYT"; fake_python "$PYT" "$version"
  run_install "$PYT" --check
  check "$version: an OK line and no python3 WARN" "echo \"\$OUT\" | grep -qF 'OK    python3: Python $version' && ! echo \"\$OUT\" | grep -q 'WARN  python3'"
done

echo "-- 32. verify.sh names a missing or old python3 and exits 2 before any suite"
# Runs a COPY at a fixture root whose suites are one-line stand-ins, so it can never recurse.
if [ -f "$PKG/../verify.sh" ]; then
  setup c32; VK="$CASE/kit"; mkdir -p "$VK"; cp "$PKG/../verify.sh" "$VK/verify.sh"
  for f in $(sed -n 's#^  \(agent-orchestration/[^ ]*\.sh\).*#\1#p' "$VK/verify.sh") examples/check.py tests/check_content.py; do
    mkdir -p "$VK/$(dirname "$f")"
    case "$f" in *.sh) printf 'echo ran >> %q\n' "$CASE/suite-ran" > "$VK/$f";; *) : > "$VK/$f";; esac
  done
  run_verify() { OUT="$(cd "$CASE" && PATH="$1" bash kit/verify.sh 2>&1)"; RC=$?; return $RC; }
  run_verify "$NOPY"
  check "no python3: exit 2 and a readable line, no suite run" "[ $RC -eq 2 ] && [ \"\$OUT\" = 'Python 3.11+ is required for fixture checks; no python3 on PATH' ] && [ ! -e \"$CASE/suite-ran\" ]"
  PYT="$CASE/tools-python"; mkpath "$PYT"; fake_python "$PYT" 3.9.6
  run_verify "$PYT"
  check "python3 3.9: exit 2 naming the version found, no suite run" "[ $RC -eq 2 ] && [ \"\$OUT\" = 'Python 3.11+ is required for fixture checks; found Python 3.9.6' ] && [ ! -e \"$CASE/suite-ran\" ]"
  if [ "$HAVE_PARSER" -eq 1 ]; then
    fake_python "$PYT" 3.11.0
    run_verify "$PYT"
    check "python3 3.11: the gate opens and every suite runs" "[ $RC -eq 0 ] && [ \"\$(wc -l < \"$CASE/suite-ran\" | tr -d ' ')\" = \"\$(grep -c '^  agent-orchestration/' \"$VK/verify.sh\")\" ]"
    OUT="$(cd "$CASE" && PATH="$PYT" CDPATH=. bash kit/verify.sh 2>&1)"; RC=$?
    check "a relative verify.sh under CDPATH finds its own root" "[ $RC -eq 0 ]"
  fi
else
  printf '  SKIP  %s\n' 'verify.sh is not beside this copy of the component'
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
