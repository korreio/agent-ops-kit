#!/usr/bin/env bash
# Regression tests for explicit external Claude memory placement.
# Hermetic: the package and an independent private store live in a fresh temp directory,
# $HOME is a temp dir (so ~/.claude/projects/<slug>/memory and ~/.claude/backups live there),
# and PATH excludes claude/codex (inventory reports ABSENT; the memory target is unaffected).
# Nothing outside the temp dir is touched. Run: agent-orchestration/tests/test_install_memory.sh
set -uo pipefail
unset CODEX_HOME CLAUDE_CONFIG_DIR   # a provider home of the caller's would refuse every target below
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Sandbox guard: never arm the rm -rf trap unless mktemp made a fresh directory under the temp root
# (a failed mktemp used to leave TMP empty, `cd ""` made it the cwd, and the trap removed the cwd).
# TMP is normalized with cd+pwd -P: the installer canonicalizes paths that way, so the slugs must match.
TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || TMP_ROOT=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-orch-test.XXXXXX" 2>/dev/null)" || TMP=""
{ [ -n "$TMP_ROOT" ] && [ -n "$TMP" ] && [ -d "$TMP" ] && TMP="$(cd "$TMP" && pwd -P)" && case "$TMP" in "$TMP_ROOT"/?*) true;; *) false;; esac; } \
  || { echo "cannot create a sandbox under ${TMPDIR:-/tmp}; aborting, nothing removed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — expected: $2"; fi; }

# fresh sandbox per case: returns PKGCOPY, HOME, REPO (a fake project path), SLUG, SRC, DST
setup() {
  CASE="$TMP/$1"; mkdir -p "$CASE"
  mkdir -p "$CASE/kit/agent-orchestration"; PKGCOPY="$(cd "$CASE/kit/agent-orchestration" && pwd -P)"; cp -R "$PKG/." "$PKGCOPY/"
  STORE="$(cd "$CASE" && pwd -P)/private store"
  mkdir -p "$CASE/home"; HOME="$(cd "$CASE/home" && pwd)"; export HOME
  mkdir -p "$CASE/Development/my_repo"; REPO="$(cd "$CASE/Development/my_repo" && pwd)"
  SLUG="$(printf '%s' "$REPO" | sed -E 's#[^A-Za-z0-9-]#-#g')"
  SRC="$HOME/.claude/projects/$SLUG/memory"; DST="$STORE/$SLUG"
}
run_install() { # $@ = extra args; returns the installer's exit code; output captured in $OUT
  # OUT is consumed by the caller's assertion strings through `check`/eval.
  # shellcheck disable=SC2034
  OUT="$(cd "$PKGCOPY" && PATH=/usr/bin:/bin ./install.sh --memory-root "$STORE" "$@" 2>&1)"; RC=$?; return $RC
}
populate() { mkdir -p "$1"; printf 'a\n' > "$1/MEMORY.md"; printf 'b\n' > "$1/note.md"; }

echo "== install.sh --memory regression matrix (sandbox: $TMP)"

echo "-- 1. src absent, dst absent -> FAIL, nothing created"
setup c1; run_install --apply --memory "$REPO"; check "exit 1" "[ $RC -eq 1 ]"; check "reports failed target" "echo \"\$OUT\" | grep -q 'nothing to relocate'"; check "no src created" "[ ! -e \"$SRC\" ] && [ ! -L \"$SRC\" ]"; check "no dst created" "[ ! -e \"$DST\" ]"

echo "-- 2. src populated, dst absent -> relocate (copy, backup, link)"
setup c2; populate "$SRC"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "src is symlink -> dst" "[ -L \"$SRC\" ] && [ \"\$(readlink \"$SRC\")\" = \"$DST\" ]"; check "dst has the files" "[ -f \"$DST/MEMORY.md\" ] && [ -f \"$DST/note.md\" ]"; BK=$(find "$HOME/.claude/projects/$SLUG" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1); check "backup kept with same content" "[ -n \"$BK\" ] && diff -rq \"$BK\" \"$DST\" >/dev/null"; check "write-through works" "printf x > \"$SRC/new.md\" && [ -f \"$DST/new.md\" ]"

echo "-- 3. src EMPTY dir, dst absent -> first-time project: create dst, back up empty src, link"
setup c3; mkdir -p "$SRC"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "dst created" "[ -d \"$DST\" ]"; check "src linked" "[ -L \"$SRC\" ] && [ \"\$(readlink \"$SRC\")\" = \"$DST\" ]"

echo "-- 4. src absent, dst populated (previous private store) -> link"
setup c4; populate "$DST"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "src linked to external dst" "[ -L \"$SRC\" ] && [ -f \"$SRC/MEMORY.md\" ]"

echo "-- 5. src populated, dst populated -> FAIL, nothing moved"
setup c5; populate "$SRC"; populate "$DST"; printf 'c\n' > "$DST/other.md"; run_install --apply --memory "$REPO"; check "exit 1" "[ $RC -eq 1 ]"; check "both have content message" "echo \"\$OUT\" | grep -q 'both .* have content'"; check "src still a real dir with its files" "[ -d \"$SRC\" ] && [ ! -L \"$SRC\" ] && [ -f \"$SRC/note.md\" ]"; check "dst untouched" "[ -f \"$DST/other.md\" ] && [ ! -f \"$DST/new.md\" ]"

echo "-- 6. src EMPTY dir, dst populated -> link (empty local side is no memory)"
setup c6; mkdir -p "$SRC"; populate "$DST"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "src linked" "[ -L \"$SRC\" ] && [ -f \"$SRC/MEMORY.md\" ]"

echo "-- 7. src is a symlink elsewhere, dst populated -> back up the symlink, link to dst"
setup c7; populate "$DST"; ELSE="$CASE/elsewhere"; mkdir -p "$ELSE"; mkdir -p "$(dirname "$SRC")"; ln -s "$ELSE" "$SRC"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "src now points to dst" "[ \"\$(readlink \"$SRC\")\" = \"$DST\" ]"; check "old symlink backed up" "ls \"$HOME/.claude/backups\"/agent-orchestration-*/ 2>/dev/null | grep -q memory"; check "elsewhere dir untouched" "[ -d \"$ELSE\" ]"

echo "-- 8. dst is a symlink -> FAIL, refuse to copy into it"
setup c8; populate "$SRC"; ELSE="$CASE/elsewhere2"; mkdir -p "$ELSE"; mkdir -p "$STORE"; ln -s "$ELSE" "$DST"; run_install --apply --memory "$REPO"; check "exit 1" "[ $RC -eq 1 ]"; check "refusal message" "echo \"\$OUT\" | grep -q 'symlink or not a directory'"; check "src not moved" "[ -d \"$SRC\" ] && [ ! -L \"$SRC\" ]"; check "elsewhere stays empty" "[ -z \"\$(ls -A \"$ELSE\")\" ]"

echo "-- 9. already linked -> OK, idempotent"
setup c9; populate "$DST"; mkdir -p "$(dirname "$SRC")"; ln -s "$DST" "$SRC"; run_install --apply --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "reports already linked" "echo \"\$OUT\" | grep -q 'already linked'"; check "no backup created" "[ ! -d \"$HOME/.claude/backups\" ]"

echo "-- 10. --check (dry run) on case-2 shape mutates nothing"
setup c10; populate "$SRC"; run_install --check --memory "$REPO"; check "exit 0" "[ $RC -eq 0 ]"; check "plan printed" "echo \"\$OUT\" | grep -q 'PLAN  copy'"; check "src still a real dir" "[ -d \"$SRC\" ] && [ ! -L \"$SRC\" ]"; check "dst not created" "[ ! -e \"$DST\" ]"; check "no backups dir" "[ ! -d \"$HOME/.claude/backups\" ]"

echo "-- 11. missing and relative roots refuse before mutation"
setup c11; populate "$SRC"
OUT="$(cd "$PKGCOPY" && PATH=/usr/bin:/bin ./install.sh --apply --memory "$REPO" 2>&1)"; RC=$?
check "missing root exits 2" "[ $RC -eq 2 ]"
check "missing root preserves source and creates no backup/store" "[ ! -L \"$SRC\" ] && [ -f \"$SRC/note.md\" ] && [ ! -e \"$STORE\" ] && [ ! -d \"$HOME/.claude/backups\" ]"
OUT="$(cd "$PKGCOPY" && PATH=/usr/bin:/bin ./install.sh --apply --memory-root relative --memory "$REPO" 2>&1)"; RC=$?
check "relative root exits 2" "[ $RC -eq 2 ]"
check "relative root creates nothing" "[ ! -e \"$PKGCOPY/relative\" ] && [ ! -L \"$SRC\" ]"

echo "-- 12. inside-checkout and symlink-resolved-inside roots refuse"
setup c12; populate "$SRC"; ORIGINAL_STORE="$STORE"; STORE="$PKGCOPY/memory/private"; run_install --apply --memory "$REPO"
check "inside root exits 2" "[ $RC -eq 2 ]"
check "inside root does not create a store or change notes" "[ ! -e \"$STORE\" ] && [ ! -L \"$SRC\" ] && [ -f \"$SRC/note.md\" ]"
ln -s "$PKGCOPY" "$CASE/store-alias"; STORE="$CASE/store-alias/notes"; run_install --apply --memory "$REPO"
check "resolved-inside root exits 2" "[ $RC -eq 2 ]"
check "resolved-inside root does not create destination" "[ ! -e \"$PKGCOPY/notes\" ] && [ ! -L \"$SRC\" ]"

echo "-- 13. populated symlink refuses different empty or populated stores"
for dest_shape in absent empty populated; do
  setup "c13-$dest_shape"; OLD="$CASE/old store"; populate "$OLD"; mkdir -p "$(dirname "$SRC")"; ln -s "$OLD" "$SRC"
  case "$dest_shape" in empty) mkdir -p "$DST";; populated) populate "$DST"; printf 'destination only\n' > "$DST/unique.md";; esac
  run_install --apply --memory "$REPO"
  check "$dest_shape destination retarget exits 1" "[ $RC -eq 1 ]"
  check "$dest_shape source link and old notes preserved" "[ \"\$(readlink \"$SRC\")\" = \"$OLD\" ] && [ -f \"$OLD/note.md\" ]"
  check "$dest_shape no backup made" "[ ! -d \"$HOME/.claude/backups\" ]"
  case "$dest_shape" in absent) check "absent destination stays absent" "[ ! -e \"$DST\" ]";; empty) check "empty destination stays empty" "[ -z \"\$(ls -A \"$DST\")\" ]";; populated) check "populated destination unique note preserved" "[ -f \"$DST/unique.md\" ]";; esac
done

echo "-- 14. canonical store aliases are idempotent, including relative source links"
setup c14; populate "$DST"; mkdir -p "$(dirname "$SRC")"; ln -s "$DST" "$SRC"; ln -s "$STORE" "$CASE/store-alias"; STORE="$CASE/store-alias/../store-alias"; run_install --apply --memory "$REPO"
check "alternate canonical spelling exits 0 and reports idempotent" "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q 'already linked'"
check "alternate spelling makes no backups" "[ ! -d \"$HOME/.claude/backups\" ]"
setup c14-relative; populate "$DST"; mkdir -p "$(dirname "$SRC")"
RELATIVE="$(python3 - "$DST" "$(dirname "$SRC")" <<'EOF'
import os,sys
print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))
EOF
)"; ln -s "$RELATIVE" "$SRC"
check "relative link fixture reaches notes before installation" "[ -f \"$SRC/note.md\" ]"
run_install --apply --memory "$REPO"
check "relative link target canonical identity exits 0" "[ $RC -eq 0 ]"
check "relative link spelling preserved and notes present" "[ \"\$(readlink \"$SRC\")\" = \"$RELATIVE\" ] && [ -f \"$SRC/note.md\" ] && [ ! -d \"$HOME/.claude/backups\" ]"

echo "-- 15. manual undo restores original notes and preserves external notes"
setup c15; populate "$SRC"; run_install --apply --memory "$REPO"; printf 'external only\n' > "$DST/unique.md"
BK="$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1)"
if [ -n "$BK" ] && [ -L "$SRC" ]; then rm "$SRC"; mv "$BK" "$SRC"; fi
check "undo restores regular local directory with original notes" "[ -d \"$SRC\" ] && [ ! -L \"$SRC\" ] && [ -f \"$SRC/note.md\" ]"
check "undo retains external-only note" "[ -f \"$DST/unique.md\" ]"


echo "-- 16. failed partial copy leaves absent and existing empty destinations intact"
for dest_shape in absent empty; do
  setup "c16-$dest_shape"; populate "$SRC"
  [ "$dest_shape" != empty ] || mkdir -p "$DST"
  # Fault only the populated-memory copy; setup already completed with the real cp.
  TOOLS="$CASE/tools"; mkdir "$TOOLS"
  cat > "$TOOLS/cp" <<'EOF'
#!/bin/bash
for last; do :; done
printf 'partial\n' > "$last/partial-note"
exit 1
EOF
  chmod +x "$TOOLS/cp"
  OUT="$(cd "$PKGCOPY" && PATH="$TOOLS:/usr/bin:/bin" ./install.sh --apply --memory-root "$STORE" --memory "$REPO" 2>&1)"; RC=$?
  check "$dest_shape partial copy fails without moving source" '[ $RC -eq 1 ] && [ ! -L "$SRC" ] && [ -f "$SRC/MEMORY.md" ] && [ -f "$SRC/note.md" ]'
  check "$dest_shape temporary copy removed" '[ -z "$(find "$STORE" -name ".memory-stage.*" -print)" ]'
  if [ "$dest_shape" = empty ]; then
    check "existing empty destination remains empty" '[ -d "$DST" ] && [ -z "$(ls -A "$DST")" ]'
  else
    check "absent destination stays absent" '[ ! -e "$DST" ]'
  fi
done

echo "-- 17. populated copy atomically replaces an existing empty destination"
setup c17; populate "$SRC"; mkdir -p "$DST"
run_install --apply --memory "$REPO"
check "empty destination receives complete notes and source links" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ -f "$DST/MEMORY.md" ] && [ -f "$DST/note.md" ]'
BK="$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1)"
check "successful copy reports the actual unique backup path" '[ -n "$BK" ] && [ -d "$BK" ] && echo "$OUT" | grep -Fxq "  BACKUP $SRC -> $BK"'
check "apply run describes a unique sibling backup" 'echo "$OUT" | grep -Fq "move original to a unique sibling backup ($SRC.local-backup-"'
check "apply run reports the step as APPLY, never as a plan" 'echo "$OUT" | grep -q "^  APPLY copy " && ! echo "$OUT" | grep -q "^  PLAN"'

echo "-- 18. documented standalone component copy accepts a sibling store"
setup c18; populate "$SRC"
mv "$PKGCOPY" "$CASE/toolkit"; PKGCOPY="$CASE/toolkit"
run_install --check --memory "$REPO"
check "standalone sibling preview exits 0" '[ $RC -eq 0 ]'
check "standalone preview preserves notes without creating store or backup" '[ ! -L "$SRC" ] && [ "$(cat "$SRC/note.md")" = b ] && [ ! -e "$STORE" ] && [ -z "$(find "$(dirname "$SRC")" -name "memory.local-backup-*" -print)" ]'
run_install --apply --memory "$REPO"
check "standalone sibling apply links preserved notes" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && [ "$(cat "$DST/MEMORY.md")" = a ] && [ "$(cat "$DST/note.md")" = b ]'
BK="$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1)"
check "standalone relocation keeps matching original backup" '[ -n "$BK" ] && diff -rq "$BK" "$DST" >/dev/null'
ln -s "$PKGCOPY" "$CASE/component-alias"; PKGCOPY="$CASE/component-alias"
run_install --apply --memory "$REPO"
check "standalone directory-alias repeat is idempotent" '[ $RC -eq 0 ] && echo "$OUT" | grep -q "already linked" && [ "$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name "memory.local-backup-*" | wc -l | tr -d " ")" = 1 ] && diff -rq "$BK" "$DST" >/dev/null'

echo "-- 19. unrelated parent README and different component do not widen the boundary"
setup c19; populate "$SRC"
mv "$PKGCOPY" "$CASE/toolkit"; PKGCOPY="$CASE/toolkit"
printf '# Unrelated project\n' > "$CASE/README.md"; mkdir "$CASE/agent-orchestration"
run_install --apply --memory "$REPO"
check "unrelated layout accepts its sibling store" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ]'
check "unrelated-layout relocation preserves both notes" '[ "$(cat "$DST/MEMORY.md")" = a ] && [ "$(cat "$DST/note.md")" = b ]'

echo "-- 20. full-kit markers protect the whole root, not only its component"
setup c20; populate "$SRC"; EXTERNAL_STORE="$STORE"
printf '# Fixture kit\n' > "$CASE/kit/README.md"
STORE="$CASE/kit/private-store"
for mode in --check --apply; do
  run_install "$mode" --memory "$REPO"
  check "$mode rejects a sibling inside the full kit" '[ $RC -eq 2 ]'
  check "$mode refusal preserves source and creates no store or backup" '[ ! -L "$SRC" ] && [ "$(cat "$SRC/note.md")" = b ] && [ ! -e "$STORE" ] && [ ! -d "$HOME/.claude/backups" ] && [ -z "$(find "$(dirname "$SRC")" -name "memory.local-backup-*" -print)" ]'
done
ln -s "$CASE/kit" "$CASE/full-kit-alias"; STORE="$CASE/full-kit-alias/private-store"
run_install --apply --memory "$REPO"
check "full-kit store alias is also refused" '[ $RC -eq 2 ]'
check "full-kit alias refusal leaves notes and destination unchanged" '[ ! -L "$SRC" ] && [ "$(cat "$SRC/note.md")" = b ] && [ ! -e "$CASE/kit/private-store" ]'
STORE="$EXTERNAL_STORE"; run_install --apply --memory "$REPO"
check "full kit accepts a genuinely external sibling store" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ]'
BK="$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1)"
check "full-kit external relocation preserves original notes and backup" '[ -n "$BK" ] && [ "$(cat "$DST/note.md")" = b ] && diff -rq "$BK" "$DST" >/dev/null'

echo "-- 21. invocation through a component alias retains the canonical full-kit boundary"
setup c21; populate "$SRC"; EXTERNAL_STORE="$STORE"
printf '# Fixture kit\n' > "$CASE/kit/README.md"; mkdir "$CASE/kit/docs"
ln -s "$PKGCOPY" "$CASE/component-alias"; PKGCOPY="$CASE/component-alias"
STORE="$CASE/kit/docs/private-store"; run_install --apply --memory "$REPO"
check "component alias cannot place memory elsewhere in the full kit" '[ $RC -eq 2 ]'
check "component-alias refusal preserves notes and creates nothing" '[ ! -L "$SRC" ] && [ "$(cat "$SRC/note.md")" = b ] && [ ! -e "$STORE" ] && [ ! -d "$HOME/.claude/backups" ]'
STORE="$EXTERNAL_STORE"; run_install --apply --memory "$REPO"
check "component alias still permits an external store" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && [ "$(cat "$DST/note.md")" = b ]'

echo "-- 22. immediate-parent Git directory and worktree-file markers retain refusal"
for kind in directory file; do
  setup "c22-$kind"; populate "$SRC"
  mv "$PKGCOPY" "$CASE/toolkit"; PKGCOPY="$CASE/toolkit"
  if [ "$kind" = directory ]; then mkdir "$CASE/.git"; else printf 'gitdir: fixture-git-dir\n' > "$CASE/.git"; fi
  run_install --apply --memory "$REPO"
  check "$kind Git marker rejects a store in that immediate parent" '[ $RC -eq 2 ]'
  check "$kind Git-marker refusal preserves source and creates no store or backup" '[ ! -L "$SRC" ] && [ "$(cat "$SRC/note.md")" = b ] && [ ! -e "$STORE" ] && [ ! -d "$HOME/.claude/backups" ] && [ -z "$(find "$(dirname "$SRC")" -name "memory.local-backup-*" -print)" ]'
done


# New fault cases use a provider-free PATH selected from installed host tools.
TOOLS_BASE="$TMP/tools"; mkdir -p "$TOOLS_BASE"
for t in bash env date mkdir mktemp basename dirname readlink cmp ln mv cp chmod rm rmdir wc tr sed cat head ls grep python3 stat diff; do
  p="$(command -v "$t")" || { echo "missing tool $t" >&2; exit 1; }
  ln -s "$p" "$TOOLS_BASE/$t"
done
# Snapshot both sides independently of shell existence predicates. Following a source
# link records its target notes too; destination inode catches empty-dir replacement.
memory_snapshot() {
  python3 -I -B - "$1" "$CASE/preserved.json" "$SRC" "$DST" <<'EOF'
import json, os, pathlib, stat, sys
operation, record, source, destination = sys.argv[1:]
def tree(path, follow=False):
    try:
        meta = os.lstat(path)
    except FileNotFoundError:
        return None
    item = {'mode': stat.S_IMODE(meta.st_mode)}
    if stat.S_ISLNK(meta.st_mode):
        item['link'] = os.readlink(path)
        if follow:
            item['target'] = tree(os.path.realpath(path))
    elif stat.S_ISDIR(meta.st_mode):
        item['children'] = {name: tree(os.path.join(path, name)) for name in sorted(os.listdir(path))}
    else:
        item['bytes'] = pathlib.Path(path).read_bytes().hex()
    return item
snapshot = {'source': tree(source, True), 'destination': tree(destination)}
if snapshot['destination'] is not None:
    snapshot['destination']['inode'] = os.lstat(destination).st_ino
if operation == 'save':
    pathlib.Path(record).write_text(json.dumps(snapshot, sort_keys=True))
else:
    assert snapshot == json.loads(pathlib.Path(record).read_text()), snapshot
EOF
}

echo "-- 23. backup reservation and publication failures preserve both original sides"
for fault in backup-reservation publication; do
  for dest_shape in absent empty; do
    setup "c23-$fault-$dest_shape"; populate "$SRC"; cp -pR "$SRC" "$CASE/source-before"
    [ "$dest_shape" != empty ] || mkdir -p "$DST"
    chmod 750 "$SRC"; chmod 640 "$SRC/note.md"
    memory_snapshot save
    FX="$CASE/tools-failure"; mkdir "$FX"
    for f in "$TOOLS_BASE"/*; do ln -s "$(readlink "$f")" "$FX/$(basename "$f")"; done
    if [ "$fault" = backup-reservation ]; then
      REAL_MKTEMP="$(readlink "$FX/mktemp")"; rm "$FX/mktemp"
      { printf '#!/bin/bash\nREAL=%q\nSEEN=%q\n' "$REAL_MKTEMP" "$CASE/reservation-denied"; cat <<'EOF'
# Deny only source-backup reservation; staging still uses the real mktemp.
case "$*" in *memory.local-backup-*) : > "$SEEN"; exit 1;; esac
exec "$REAL" "$@"
EOF
      } > "$FX/mktemp"; chmod +x "$FX/mktemp"
    else
      REALPY="$(readlink "$FX/python3")"; rm "$FX/python3"
      cat > "$CASE/publication-denied.py" <<'EOF'
import errno, os, pathlib, sys
code = sys.stdin.read()
sys.argv = ['-'] + [a for a in sys.argv[1:] if a not in ('-I', '-B', '-')]
# Deny the actual publication call while leaving its populated scratch stage intact.
# The installer must remove that stage and its unused reservation itself.
if 'os.replace(sys.argv[1],sys.argv[2])' in code:
    stage, destination = map(pathlib.Path, sys.argv[1:3])
    case = stage.parent.parent
    source = case / 'home/.claude/projects' / destination.name / 'memory'
    def denied_replace(from_path, to_path):
        assert pathlib.Path(from_path) == stage and pathlib.Path(to_path) == destination
        reservations = list(source.parent.glob('memory.local-backup-*'))
        if not reservations or any(p.is_symlink() or not p.is_dir() or list(p.iterdir()) for p in reservations):
            raise RuntimeError('publication fixture requires an empty source-backup reservation')
        assert not stage.is_symlink() and stage.is_dir() and list(stage.iterdir())
        for name in ('MEMORY.md', 'note.md'):
            assert (stage / name).read_bytes() == (source / name).read_bytes()
        (case / 'reservation-observed').write_text('reserved and populated stage before publication denial\n')
        raise PermissionError(errno.EACCES, 'scratch publication denied', str(stage))
    os.replace = denied_replace
exec(compile(code, '<installer>', 'exec'), {'__name__': '__main__'})
EOF
      { printf '#!/bin/bash\nREAL=%q\nRUNNER=%q\n' "$REALPY" "$CASE/publication-denied.py"; cat <<'EOF'
case " $* " in *" - "*) exec "$REAL" -I -B "$RUNNER" "$@";; esac
exec "$REAL" "$@"
EOF
      } > "$FX/python3"; chmod +x "$FX/python3"
    fi
    # OUT is consumed by deferred check/eval assertions.
    # shellcheck disable=SC2034
    OUT="$(cd "$PKGCOPY" && PATH="$FX" ./install.sh --apply --memory-root "$STORE" --memory "$REPO" 2>&1)"; RC=$?
    # Assertions intentionally expand through check/eval.
    # shellcheck disable=SC2016
    check "$fault/$dest_shape fails and preserves original local notes" '[ $RC -eq 1 ] && [ ! -L "$SRC" ] && diff -rq "$CASE/source-before" "$SRC" >/dev/null'
    # shellcheck disable=SC2016
    check "$fault/$dest_shape leaves no stage or empty backup reservation" '[ -z "$(find "$STORE" -name ".memory-stage.*" -print)" ] && [ -z "$(find "$(dirname "$SRC")" -name "memory.local-backup-*" -print)" ]'
    if [ "$dest_shape" = empty ]; then
      # shellcheck disable=SC2016
      check "$fault preserves empty destination" '[ -d "$DST" ] && [ -z "$(ls -A "$DST")" ]'
    else
      # shellcheck disable=SC2016
      check "$fault preserves absent destination" '[ ! -e "$DST" ]'
    fi
    check "$fault/$dest_shape preserves bytes, modes, links and destination identity" 'memory_snapshot check'
    if [ "$fault" = publication ]; then
      # shellcheck disable=SC2016
      check "$dest_shape publication failed after reservation succeeded" 'grep -Fxq "reserved and populated stage before publication denial" "$CASE/reservation-observed" && echo "$OUT" | grep -q "could not publish staged copy"'
    else
      # shellcheck disable=SC2016
      check "$dest_shape reservation failure is reported" '[ -f "$CASE/reservation-denied" ] && echo "$OUT" | grep -q "could not reserve source backup"'
    fi
    run_install --apply --memory "$REPO"
    check "$fault/$dest_shape clean retry relocates all original notes" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && diff -rq "$CASE/source-before" "$DST" >/dev/null'
    BK="$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name 'memory.local-backup-*' -print | head -n 1)"
    check "$fault/$dest_shape retry retains exactly one matching backup and no stage" '[ -n "$BK" ] && diff -rq "$CASE/source-before" "$BK" >/dev/null && [ "$(find "$(dirname "$SRC")" -maxdepth 1 -type d -name "memory.local-backup-*" | wc -l | tr -d " ")" = 1 ] && [ -z "$(find "$STORE" -name ".memory-stage.*" -print)" ]'
  done
done

echo "-- 24. failed directory enumeration never licenses relocation"
for fault in foreign-source ordinary-source initial-destination post-copy-destination unknown-source unknown-destination post-copy-unknown; do
  setup "c24-$fault"; mkdir -p "$DST"
  # DST_INO is consumed by the deferred check/eval assertion below.
  # shellcheck disable=SC2034
  DST_INO="$(stat -f %i "$DST")"
  if [ "$fault" = foreign-source ]; then
    OLD="$CASE/foreign-store"; populate "$OLD"; mkdir -p "$(dirname "$SRC")"; ln -s "$OLD" "$SRC"
  else populate "$SRC"; fi
  mkdir "$CASE/source-before"; cp -pR "$SRC/." "$CASE/source-before/"
  chmod 750 "$SRC"; chmod 640 "$SRC/note.md"; chmod 710 "$DST"
  memory_snapshot save
  FX="$CASE/listing-tools"; mkdir "$FX"
  for f in "$TOOLS_BASE"/*; do ln -s "$(readlink "$f")" "$FX/$(basename "$f")"; done
  case "$fault" in *source) DENIED="$SRC";; *) DENIED="$DST";; esac
  REALPY="$(readlink "$FX/python3")"; rm "$FX/python3"
  cat > "$CASE/deny-enumeration.py" <<'EOF'
import errno, os, pathlib, sys
denied, fault, marker, seen = sys.argv[1:5]
code = sys.stdin.read()
sys.argv = ['-'] + [a for a in sys.argv[5:] if a not in ('-I', '-B', '-')]
if '# memory directory-state probe' in code and sys.argv[1] == denied:
    if not fault.startswith('post-copy-') or pathlib.Path(marker).is_file():
        if 'unknown' in fault:
            pathlib.Path(seen).write_text('unknown-state injected at probe\n')
            print('unrecognized-fixture-state')
            sys.exit(0)
        original = os.scandir
        def denied_scandir(path):
            if os.fspath(path) == denied:
                pathlib.Path(seen).write_text('EACCES\n')
                raise PermissionError(errno.EACCES, 'scratch enumeration denied', path)
            return original(path)
        os.scandir = denied_scandir
exec(compile(code, '<installer>', 'exec'), {'__name__': '__main__'})
EOF
  { printf '#!/bin/bash\nREAL=%q\nRUNNER=%q\nDENIED=%q\nFAULT=%q\nMARKER=%q\nSEEN=%q\n' "$REALPY" "$CASE/deny-enumeration.py" "$DENIED" "$fault" "$CASE/copy-completed" "$CASE/enumeration-denied"; cat <<'EOF'
case " $* " in *" - "*) exec "$REAL" -I -B "$RUNNER" "$DENIED" "$FAULT" "$MARKER" "$SEEN" "$@";; esac
exec "$REAL" "$@"
EOF
  } > "$FX/python3"; chmod +x "$FX/python3"
  if [[ "$fault" = post-copy-* ]]; then
    REAL_CP="$(readlink "$FX/cp")"; rm "$FX/cp"
    { printf '#!/bin/bash\nREAL=%q\nMARKER=%q\n' "$REAL_CP" "$CASE/copy-completed"; cat <<'EOF'
"$REAL" "$@" || exit $?
: > "$MARKER"
EOF
    } > "$FX/cp"; chmod +x "$FX/cp"
  fi
  # OUT is consumed by deferred check/eval assertions.
  # shellcheck disable=SC2034
  OUT="$(cd "$PKGCOPY" && PATH="$FX" ./install.sh --apply --memory-root "$STORE" --memory "$REPO" 2>&1)"; RC=$?
  # Assertions intentionally expand through check/eval.
  # shellcheck disable=SC2016
  case "$fault" in *unknown*) EXPECTED_ERROR="unexpected .*inspection state";; *) EXPECTED_ERROR="cannot inspect or enumerate";; esac
  check "$fault is rejected by the inspection owner" '[ $RC -eq 1 ] && [ -f "$CASE/enumeration-denied" ] && grep -q "$EXPECTED_ERROR" <<< "$OUT"'
  # shellcheck disable=SC2016
  check "$fault preserves source notes and original empty destination" 'diff -rq "$CASE/source-before" "$SRC" >/dev/null && [ -d "$DST" ] && [ -z "$(ls -A "$DST")" ] && [ "$(stat -f %i "$DST")" = "$DST_INO" ]'
  # shellcheck disable=SC2016
  check "$fault leaves no backup or owned stage" '[ ! -d "$HOME/.claude/backups" ] && [ -z "$(find "$(dirname "$SRC")" -name "memory.local-backup-*" -print)" ] && [ -z "$(find "$STORE" -name ".memory-stage.*" -print)" ]'
  check "$fault preserves bytes, modes, links and destination identity" 'memory_snapshot check'
  if [ "$fault" = foreign-source ]; then
    # shellcheck disable=SC2016
    check "failed foreign enumeration preserves the source link" '[ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$OLD" ]'
  else
    # shellcheck disable=SC2016
    check "$fault preserves the regular local directory" '[ -d "$SRC" ] && [ ! -L "$SRC" ]'
  fi
  if [ "$fault" != foreign-source ]; then
    run_install --apply --memory "$REPO"
    check "$fault clean retry relocates notes" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && diff -rq "$CASE/source-before" "$DST" >/dev/null'
  fi
done

echo "-- 25. actual unsearchable ancestor fails without retargeting linked memory"
setup c25; mkdir -p "$CASE/protected"; populate "$CASE/protected/foreign"; mkdir -p "$(dirname "$SRC")" "$DST"
ln -s "$CASE/protected/foreign" "$SRC"
# The Python driver restores permissions even if the assertion or subprocess fails.
python3 -I -B - "$PKGCOPY" "$HOME" "$TOOLS_BASE" "$REPO" "$SRC" "$DST" "$CASE/protected" "$STORE" <<'EOF'
import os, pathlib, subprocess, sys
pkg, home, tools, repo, source, destination, protected, store = map(pathlib.Path, sys.argv[1:])
if os.geteuid() == 0:
    print('  SKIP actual unsearchable-ancestor proof requires a non-root process')
    sys.exit(77)
old_mode = protected.stat().st_mode & 0o7777
original_link = os.readlink(source)
source_mode = source.lstat().st_mode
foreign_mode = (protected / 'foreign').stat().st_mode
destination_mode = destination.stat().st_mode
notes = {p.name: p.read_bytes() for p in (protected / 'foreign').iterdir()}
destination_inode = destination.stat().st_ino
try:
    protected.chmod(0)
    # Prove the fixture actually denies target metadata on this host.
    try:
        os.stat(source)
    except PermissionError:
        pass
    else:
        raise AssertionError('host did not enforce the unsearchable ancestor')
    environment = dict(os.environ, HOME=str(home), PATH=str(tools))
    result = subprocess.run([str(pkg / 'install.sh'), '--apply', '--memory-root', str(store), '--memory', str(repo)],
                            cwd=pkg, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 1, result.stdout
    assert 'cannot inspect or enumerate' in result.stdout, result.stdout
    assert os.readlink(source) == original_link and source.lstat().st_mode == source_mode
    assert destination.stat().st_mode == destination_mode
    assert destination.stat().st_ino == destination_inode and not list(destination.iterdir())
    assert not list(destination.parent.glob('.memory-stage.*'))
    assert not list(source.parent.glob('memory.local-backup-*'))
    assert not (home / '.claude/backups').exists()
finally:
    protected.chmod(old_mode)
assert protected.stat().st_mode & 0o7777 == old_mode
assert (protected / 'foreign').stat().st_mode == foreign_mode
assert {p.name: p.read_bytes() for p in (protected / 'foreign').iterdir()} == notes
EOF
RC=$?
if [ "$RC" -ne 77 ]; then check "real ancestor denial preserves source link, notes and destination" "[ $RC -eq 0 ]"; fi

echo "-- 26. proven-empty foreign link and genuine dangling link remain eligible"
for shape in empty dangling; do
  setup "c26-$shape"; mkdir -p "$(dirname "$SRC")"; OLD="$CASE/foreign"
  [ "$shape" != empty ] || mkdir "$OLD"
  ln -s "$OLD" "$SRC"
  run_install --apply --memory "$REPO"
  # Assertions intentionally expand through check/eval.
  # shellcheck disable=SC2016
  check "$shape source is safely linked to the external empty store" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && [ -d "$DST" ] && [ -z "$(ls -A "$DST")" ]'
  if [ "$shape" = empty ]; then
    # shellcheck disable=SC2016
    check "known-empty foreign store remains untouched" '[ -d "$OLD" ] && [ -z "$(ls -A "$OLD")" ]'
  else
    # shellcheck disable=SC2016
    check "genuinely absent foreign target remains absent" '[ ! -e "$OLD" ]'
  fi
done

echo "-- 27. a repository reached through a symlink uses the provider's physical slug"
setup c27; populate "$SRC"; ln -s "$REPO" "$CASE/repo-alias"
run_install --apply --memory "$CASE/repo-alias"
# shellcheck disable=SC2016
check "symlinked repository relocates the physical project's notes" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && [ "$(cat "$DST/note.md")" = b ]'
# shellcheck disable=SC2016
check "no second project appears under the link's spelling" '[ "$(ls "$HOME/.claude/projects" | wc -l | tr -d " ")" = 1 ] && [ "$(ls "$STORE" | wc -l | tr -d " ")" = 1 ]'

echo "-- 28. a relative invocation under CDPATH keeps one package path and one repository path"
setup c28; populate "$SRC"
# OUT is consumed by the deferred check/eval assertion.
# shellcheck disable=SC2034
OUT="$(cd "$CASE" && PATH=/usr/bin:/bin CDPATH=. bash kit/agent-orchestration/install.sh --apply --memory-root "$STORE" --memory Development/my_repo 2>&1)"; RC=$?
# shellcheck disable=SC2016
check "relative install.sh and relative repository relocate the right notes" '[ $RC -eq 0 ] && [ -L "$SRC" ] && [ "$(readlink "$SRC")" = "$DST" ] && [ "$(cat "$DST/note.md")" = b ]'

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
