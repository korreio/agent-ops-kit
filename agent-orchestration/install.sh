#!/usr/bin/env bash
# install.sh — inventory-first installer/verifier for the agent-orchestration package.
#
#   ./install.sh                          # --check (default): report state and planned changes
#                                         # for every target; mutates nothing
#   ./install.sh --apply --skills         # link ~/.claude/skills/<name> -> this package (backup first)
#   ./install.sh --apply --agents         # link ~/.claude/agents/<name>.md -> claude/agents/ (like --rules)
#   ./install.sh --apply --hooks          # link ~/.claude/hooks/<name>.sh -> claude/hooks/ (not test_*; like
#                                         # --rules), then merge claude/settings-fragment.json with jq into
#                                         # ~/.claude/settings.json: add missing hooks; if any fragment deny
#                                         # string is absent, prepend its complete ordered deny block. Keep the
#                                         # original deny array as an unchanged suffix, including duplicates;
#                                         # if complete, leave it unchanged. Other keys kept; backup first. One
#                                         # JSON object required (empty = {}), checked before linking hooks; replace
#                                         # by one rename only if unchanged. Per-Mac regular file; jq required.
#   ./install.sh --apply --rules          # link ~/.claude/rules/<name>.md -> claude/rules/ when the real file
#                                         # is identical (backup first); a DIFFERING file is left alone
#                                         # with a WARN (merge it yourself), never overwritten. For all three,
#                                         # a ~/.claude/{agents,hooks,rules} that is a symlink or not a
#                                         # directory FAILs the target.
#   ./install.sh --apply --global-claude-md   # link ~/.claude/CLAUDE.md -> standing-orders.md
#                                         # (reports an existing file's size; never prints it)
#   ./install.sh --apply --codex-agents-md    # link ~/.codex/AGENTS.md -> standing-orders.md (Codex's
#                                         # global instructions; per Codex AGENTS.md discovery order).
#                                         # This section also REPORTS, and never changes, how much of a
#                                         # repository's AGENTS.md Codex loads: project_doc_max_bytes in
#                                         # ~/.codex/config.toml (32768 when absent), with a WARN for a
#                                         # missing key and for each ~/Development/*/AGENTS.md over it.
#   ./install.sh --apply --bin            # link ~/.local/bin/{claude-review,codex-review}
#                                         # to the two launcher scripts in bin/, so ANY coordinating
#                                         # platform calls a launcher instead of reconstructing flags;
#                                         # and ~/.local/bin/{claude-write,codex-write} to the same
#                                         # claude_job.sh and codex_job.sh. Run by a -write name each
#                                         # is the writer command: claude_job.sh takes its lane from
#                                         # the name; codex_job.sh selects its workspace-write lane.
#                                         # Also ~/.local/bin/session-ledger -> bin/session_ledger.py,
#                                         # the read-only ledger of agent sessions.
#                                         # codex_job.sh moved out of its Claude skill directory;
#                                         # re-run this target to repoint an older shim link.
#   ./install.sh --apply --remove-codex-mcp  # remove a user-scope `codex` MCP registration left over
#                                         # from an older setup (codex mcp-server is deprecated in
#                                         # Codex 0.149 and times out at ~60 s in Claude Code desktop)
#   ./install.sh --apply --memory-root /absolute/private/store --memory <repo-path>
#                                         # relocate Claude memory into external <store>/<slug>/
#                                         # behind a symlink; repeat --memory for more projects
#   ./install.sh --apply --all            # --skills --bin (never --global-claude-md, --codex-agents-md,
#                                         # --remove-codex-mcp, --memory, --agents, --hooks or --rules:
#                                         # each needs its own explicit authority)
#
# --apply without a target is an error: each target is its own explicit authority, and --all stands
# for exactly the two targets it lists above. A preview prints PLAN; --apply prints the same lines
# as APPLY, because it makes each change as it reports it. Every replaced file/dir is backed up
# first. Credentials, repositories and Git state stay untouched; only --remove-codex-mcp changes
# an MCP registration. Exit 1 when a
# selected target could not be completed (inventory warnings alone do not fail the run).
# --contracts-root DIR bounds inventory to DIR/*/AGENTS.md (default: $HOME/Development).
# Requires: bash; python3 for --memory (preflighted before any mutation); jq for --hooks;
# optional: claude, codex, node.
# Native Codex targets (explicit, never --all): --codex-agents, --codex-hooks,
# --codex-skills, --codex-config (lane profiles), --codex-coordinator (global defaults). Python 3.11+; changed files backed up beside themselves.
# The inventory WARNs about an older python3, which those targets and the Codex launchers cannot use.
# CLAUDE_CONFIG_DIR or CODEX_HOME naming another home than $HOME/.claude or $HOME/.codex refuses
# that provider's selected targets (exit 2, before any change): hook commands hard-code those homes.
set -euo pipefail
unset CDPATH   # internal cd output must contain only pwd, never CDPATH diagnostics

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="check"
T_SKILLS=0; T_GLOBAL=0; T_RMMCP=0; T_CODEXMD=0; T_BIN=0; T_AGENTS=0; T_HOOKS=0; T_RULES=0
MEM_PATHS=()
MEMORY_ROOT=""
CONTRACTS_ROOT="$HOME/Development"
CODEX_TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply"; shift;;
    --check) MODE="check"; shift;;
    --skills) T_SKILLS=1; shift;;
    --global-claude-md) T_GLOBAL=1; shift;;
    --codex-agents-md) T_CODEXMD=1; shift;;
    --codex-agents|--codex-hooks|--codex-skills|--codex-config|--codex-coordinator) CODEX_TARGETS+=("${1#--codex-}"); shift;;
    --bin) T_BIN=1; shift;;
    --agents) T_AGENTS=1; shift;;
    --hooks) T_HOOKS=1; shift;;
    --rules) T_RULES=1; shift;;
    --remove-codex-mcp) T_RMMCP=1; shift;;
    --all) T_SKILLS=1; T_BIN=1; shift;;
    --contracts-root) [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "--contracts-root requires a directory" >&2; exit 2; }; CONTRACTS_ROOT="$2"; shift 2;;
    --memory-root) [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "--memory-root requires an absolute store path" >&2; exit 2; }; MEMORY_ROOT="$2"; shift 2;;
    --memory) [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "--memory requires a repository path, not an option" >&2; exit 2; }; MEM_PATHS+=("$2"); shift 2;;
    -h|--help) awk 'NR>1 && !/^#/{exit} NR>1{print}' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ ${#CODEX_TARGETS[@]} -gt 0 ] && { [ $T_SKILLS$T_GLOBAL$T_RMMCP$T_CODEXMD$T_BIN$T_AGENTS$T_HOOKS$T_RULES != 00000000 ] || [ ${#MEM_PATHS[@]} -gt 0 ]; }; then
  echo 'run native Codex targets separately from the other installer targets' >&2; exit 2
fi
if [ "$MODE" = check ]; then T_SKILLS=1; T_GLOBAL=1; T_CODEXMD=1; T_BIN=1; T_AGENTS=1; T_HOOKS=1; T_RULES=1; fi
if [ "$MODE" = apply ] && [ $T_SKILLS$T_GLOBAL$T_RMMCP$T_CODEXMD$T_BIN$T_AGENTS$T_HOOKS$T_RULES = 00000000 ] && [ ${#MEM_PATHS[@]} -eq 0 ] && [ ${#CODEX_TARGETS[@]} -eq 0 ]; then
  echo "--apply needs at least one target: --skills --agents --hooks --rules --global-claude-md --codex-agents-md --bin --remove-codex-mcp --memory <path> (or --all); native Codex targets, run on their own: --codex-agents --codex-hooks --codex-skills --codex-config --codex-coordinator" >&2; exit 2
fi
# Hook commands hard-code $HOME/.claude and $HOME/.codex, and this installer edits those homes. A
# provider pointed elsewhere would never read what a target installs, and following the variable
# here would only part the files from the commands that name them. --bin links outside both homes,
# and --remove-codex-mcp asks the claude CLI, which follows its own variable.
require_default_home() { # $1 = variable name, $2 = its value, $3 = the home the selected targets edit
  if [ -z "$2" ] || [ "${2%/}" = "$3" ] || [ "$2" -ef "$3" ]; then return 0; fi
  echo "$1 names another directory than $3, which the selected targets edit and hook commands hard-code; unset it for this run or omit those targets; nothing changed" >&2; exit 2
}
if [ ${#CODEX_TARGETS[@]} -gt 0 ] || [ $T_CODEXMD = 1 ]; then require_default_home CODEX_HOME "${CODEX_HOME:-}" "$HOME/.codex"; fi
if [ ${#CODEX_TARGETS[@]} -eq 0 ] && { [ $T_SKILLS$T_GLOBAL$T_AGENTS$T_HOOKS$T_RULES != 00000 ] || [ ${#MEM_PATHS[@]} -gt 0 ]; }; then
  require_default_home CLAUDE_CONFIG_DIR "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"
fi
# Native targets use their own read-only inventory: avoid provider CLI inventory side effects.
if [ ${#CODEX_TARGETS[@]} -gt 0 ]; then
  command -v python3 >/dev/null 2>&1 || { echo 'native Codex targets need Python 3.11+' >&2; exit 1; }
  python3 -I -B "$HERE/codex/install.py" --mode "$MODE" --home "$HOME/.codex" "${CODEX_TARGETS[@]}"
  exit $?
fi
# Validate memory placement before inventory or any selected target can mutate a path.
# realpath resolves existing symlinks and relative link targets against their parent.
if [ ${#MEM_PATHS[@]} -gt 0 ]; then
  case "$MEMORY_ROOT" in /*) ;; *) echo "--memory requires --memory-root with an absolute external path; nothing changed" >&2; exit 2;; esac
  command -v python3 >/dev/null 2>&1 || { echo "--memory needs python3 on PATH; nothing changed" >&2; exit 2; }
  MEMORY_ROOT="$(python3 - "$MEMORY_ROOT" "$HERE" <<'EOF'
import os, sys
root, package = map(os.path.realpath, sys.argv[1:])
parent = os.path.dirname(package)
full_kit = (os.path.isfile(os.path.join(parent, "README.md")) and
            os.path.realpath(os.path.join(parent, "agent-orchestration")) == package)
git_checkout = (os.path.isdir(os.path.join(parent, ".git")) or
                os.path.isfile(os.path.join(parent, ".git")))
kit = parent if full_kit or git_checkout else package
if os.path.commonpath([root, kit]) == kit:
    sys.exit("memory root resolves inside the kit checkout; nothing changed")
if os.path.exists(root) and not os.path.isdir(root):
    sys.exit("memory root is not a directory; nothing changed")
print(root)
EOF
)" || exit 2
fi

# Job/target names never come from untrusted input here, but keep paths canonical anyway.

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP=""   # made on the first backup with mktemp -d, so two runs in the same second never share one
CLAUDE_DIR="$HOME/.claude"
changes=0; problems=0; failed=0
say()  { printf '%s\n' "$*"; }
plan() { changes=$((changes+1)); if [ "$MODE" = apply ]; then printf '  APPLY %s\n' "$*"; else printf '  PLAN  %s\n' "$*"; fi; }
ok()   { printf '  OK    %s\n' "$*"; }
warn() { problems=$((problems+1)); printf '  WARN  %s\n' "$*"; }
fail() { failed=$((failed+1)); printf '  FAIL  %s\n' "$*"; }   # a selected target could not be completed
doit() { if [ "$MODE" = apply ]; then "$@"; fi; }
refuse() { if [ "$MODE" = apply ]; then fail "$1; nothing changed"; else warn "$1 — --apply would FAIL"; fi; }
not_real_dir() { [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; }
# Invoked indirectly through `doit backup_path` in check/apply branches.
# shellcheck disable=SC2329
backup_path() { # $1 = path to back up (file, dir or symlink); $2 = copy: cp -p, leaving $1 in place
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if [ -z "$BACKUP" ]; then
    mkdir -p "$HOME/.claude/backups"; BACKUP="$(mktemp -d "$HOME/.claude/backups/agent-orchestration-$TS.XXXXXX")"
  fi
  local name; name="$(basename "$1")-$(printf '%s' "$1" | tr '/' '_')"
  # The flattened source path keeps a backup legible, but NAME_MAX is 255 bytes (APFS): a deep
  # path made mv fail under a long TMPDIR in tests/test_install_memory.sh. Elide the middle of
  # an over-long name; real paths (~90 bytes) are never touched.
  [ "${#name}" -le 200 ] || name="${name:0:80}...${name: -117}"
  if [ "${2:-}" = copy ]; then cp -p "$1" "$BACKUP/$name"; else mv "$1" "$BACKUP/$name"; fi
  say "  (backed up $1 -> $BACKUP)"
}
# Link each package file ($3 ...) into the real directory $2 ($1 labels the output). An identical real
# file, or a link to one or a dangling link, is backed up and replaced; a DIFFERING file is left alone
# with a WARN, because this Mac may hold newer edits and merging them into the package is the owner's
# call. test_* scripts stay in the package.
link_into() {
  local label="$1" dir="$2" src name dst; shift 2
  if not_real_dir "$dir"; then refuse "$dir is not a real directory (a symlink or a file)"; return 0; fi
  [ -d "$dir" ] || plan "mkdir -p $dir"
  doit mkdir -p "$dir"
  for src in "$@"; do
    name="$(basename "$src")"; dst="$dir/$name"
    case "$name" in test_*) continue;; esac
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then ok "$label $name already linked"; continue; fi
    if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
      warn "$label $name: $dst DIFFERS from the package copy; left alone, merge by hand (diff -u \"$dst\" \"$src\"), then re-run"
      continue
    fi
    if [ -L "$dst" ]; then plan "repoint $dst (currently -> $(readlink "$dst"); same content or dangling) to $src (backup first)"
    elif [ -e "$dst" ]; then plan "replace the real file $dst (identical to the package copy) with symlink -> $src (backup first)"
    else plan "link $dst -> $src"; fi
    doit backup_path "$dst"
    doit ln -s "$src" "$dst"
  done
}

say "== agent-orchestration install ($MODE) — package: $HERE"

# ---------------------------------------------------------------- 1. inventory (never mutates)
say "-- 1. tools"
re_old_python='^Python (2|3\.([0-9]|10))([^0-9]|$)'   # below 3.11: no tomllib, see section 3b
for t in claude codex node python3; do
  if command -v "$t" >/dev/null 2>&1; then
    v="$("$t" --version 2>/dev/null | head -1 || true)"
    if [ "$t" = python3 ] && [[ $v =~ $re_old_python ]]; then
      warn "python3: $v is below 3.11 — native Codex targets (--codex-agents, -hooks, -skills, -config, -coordinator) and the Codex launchers (codex-review, codex-write) need 3.11+"
    else ok "$t: ${v:-present}"; fi
  else
    warn "$t: ABSENT — lane unreachable; the owner installs and signs in"
  fi
done
if command -v codex >/dev/null 2>&1; then
  if codex login status >/dev/null 2>&1; then ok "codex: logged in"; else warn "codex: not logged in — lane unreachable; the owner runs codex login"; fi
fi
# ---------------------------------------------------------------- 2. skills -> symlinks
if [ $T_SKILLS = 1 ]; then
  say "-- 2. Claude skills (symlinks into this package) [--skills]"
  if not_real_dir "$CLAUDE_DIR" || not_real_dir "$CLAUDE_DIR/skills"; then
    refuse "$CLAUDE_DIR/skills has a non-real parent directory"
  else
    [ -d "$CLAUDE_DIR/skills" ] || plan "mkdir -p $CLAUDE_DIR/skills"
    doit mkdir -p "$CLAUDE_DIR/skills"
    for src in "$HERE"/claude/skills/*/; do
      src="${src%/}"; name="$(basename "$src")"; dst="$CLAUDE_DIR/skills/$name"
      if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then ok "skill $name already linked"; continue; fi
      if [ -e "$dst" ] && { [ ! -d "$dst" ] || ! diff -rq "$src" "$dst" >/dev/null 2>&1; }; then
        warn "skill $name: $dst DIFFERS from the package copy; left alone, merge by hand, then re-run"
        continue
      fi
      if [ -e "$dst" ] || [ -L "$dst" ]; then plan "replace $dst with symlink -> $src (identical content or dangling; backup first)"; else plan "link $dst -> $src"; fi
      doit backup_path "$dst"
      doit ln -s "$src" "$dst"
    done
    doit chmod +x "$HERE"/claude/skills/*/scripts/*.sh 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------- 2b. agents -> symlinks
if [ $T_AGENTS = 1 ]; then
  say "-- 2b. Claude agents (symlinks into this package) [--agents]"
  link_into agent "$CLAUDE_DIR/agents" "$HERE"/claude/agents/*.md
fi

# ---------------------------------------------------------------- 2c. hooks -> symlinks + settings merge
# The jq program shared by the check and the merge. A fragment item is one deny rule or one
# (event, matcher, hook) triple; an item is present when the same rule, or a hook with the same
# command under the same event and matcher, already exists. Only missing hooks are added. If any
# deny string is missing from the ORIGINAL owner array, prepend the complete ordered fragment
# block, retaining that owner array as an exact suffix (duplicates included). A `!`-negated deny
# rule carves out earlier rules: later owner restrictions must stay later, while owner exceptions
# can still relax the earlier fragment block. A complete deny array is never rewritten for hooks.
# shellcheck disable=SC2016
JQ_DEFS='
def items($f): [$f.permissions.deny[]? | {k:"deny", v:.}]
  + [($f.hooks // {}) | to_entries[] | .key as $ev | .value[] | .matcher as $m | .hooks[] | {k:"hook", ev:$ev, m:$m, h:.}];
def present($it): if $it.k == "deny" then any((.permissions.deny // [])[]; . == $it.v)
  else any((.hooks[$it.ev] // [])[]; .matcher == $it.m and any((.hooks // [])[]; .command == $it.h.command)) end;
def add_hook($it): (.hooks[$it.ev] // []) as $g
    | (first($g | to_entries[] | select(.value.matcher == $it.m) | .key) // null) as $i
    | if $i == null then .hooks[$it.ev] = $g + [{matcher: $it.m, hooks: [$it.h]}]
      else .hooks[$it.ev][$i].hooks = (($g[$i].hooks // []) + [$it.h]) end;
def missing($f): . as $s | [items($f)[] | . as $it | select(($s | present($it)) | not)];
def merged($f): missing($f) as $m
  | (if any($m[]; .k == "deny") then .permissions.deny = ($f.permissions.deny + (.permissions.deny // [])) else . end)
  | reduce ($m[] | select(.k == "hook")) as $it (.; add_hook($it));
def planned($f): missing($f) as $m
  | (if any($m[]; .k == "deny") then [{k:"deny-block", n:($f.permissions.deny | length)}] + [items($f)[] | select(.k == "deny")] else [] end)
    + [$m[] | select(.k == "hook")];
def item_label: if .k == "deny-block" then "prepend complete fragment deny block (\(.n) rules); retain original deny array as unchanged suffix, including duplicates"
  elif .k == "deny" then "permissions.deny  \(.v)" else "hooks.\(.ev)[\(.m)]  \(.h.command)" end;
'
if [ $T_HOOKS = 1 ]; then
  say "-- 2c. Claude hooks (symlinks into this package) + ~/.claude/settings.json merge [--hooks]"
  frag="$HERE/claude/settings-fragment.json"; sdst="$CLAUDE_DIR/settings.json"
  # settings.json is read ONCE, byte-exact, into cur; an absent, empty or whitespace-only file is
  # merged as {}. Everything is checked before any hook is linked, and the merged file replaces the
  # live one only if that still matches cur.
  read_settings() { had=0; cur=''; [ -e "$sdst" ] || return 0; had=1; cur="$(cat "$sdst" && printf x)" || return 1; cur="${cur%x}"; }
  json() { case "$cur" in *[!$' \t\n\r']*) printf '%s' "$cur";; *) printf '{}';; esac; }
  unchanged() { if [ "$had" = 1 ]; then printf '%s' "$cur" | cmp -s - "$sdst"; else [ ! -e "$sdst" ] && [ ! -L "$sdst" ]; fi; }
  err=""
  if ! command -v jq >/dev/null 2>&1; then err="jq absent — --hooks needs it for the settings merge"
  elif [ -L "$sdst" ] || { [ -e "$sdst" ] && [ ! -f "$sdst" ]; }; then err="$sdst is a symlink or not a regular file (it must be a per-Mac regular file)"
  elif not_real_dir "$CLAUDE_DIR/hooks"; then err="$CLAUDE_DIR/hooks is not a real directory (a symlink or a file)"
  elif ! read_settings 2>/dev/null; then err="cannot read $sdst"
  elif ! json | jq -s . >/dev/null 2>&1; then err="$sdst is not valid JSON"
  elif ! json | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null; then err="$sdst must hold exactly one JSON object (it holds several documents, a bare BOM or no object)"
  elif ! missing="$(json | jq -r -s --slurpfile f "$frag" "$JQ_DEFS"' .[0] | planned($f[0])[] | item_label' 2>&1)"; then err="cannot merge $frag into $sdst (${missing:0:160})"
  fi
  if [ -n "$err" ]; then refuse "$err"
  else
    link_into hook "$CLAUDE_DIR/hooks" "$HERE"/claude/hooks/*.sh
    doit chmod +x "$HERE"/claude/hooks/*.sh
    if [ -z "$missing" ]; then ok "$sdst already carries every hook and deny rule in the fragment"
    else
      if [ "$had" = 1 ]; then what="merge into $sdst (backup first; other keys untouched)"; else what="create $sdst"; fi
      plan "$what:"
      # shellcheck disable=SC2001
      printf '%s\n' "$missing" | sed 's/^/        + /'
      if [ "$MODE" = apply ]; then
        tmp="$sdst.tmp-$TS.$$"; trap 'rm -f "$tmp"' EXIT
        if [ "$had" = 1 ]; then cp -p "$sdst" "$tmp"; else (umask 077; : > "$tmp"); fi   # keep the file mode
        if json | jq -s --slurpfile f "$frag" "$JQ_DEFS"' .[0] | merged($f[0])' > "$tmp" \
          && jq -e -s --slurpfile f "$frag" "$JQ_DEFS"' length == 1 and (.[0] | type == "object" and (missing($f[0]) | length == 0))' "$tmp" >/dev/null; then
          backup_path "$sdst" copy
          if unchanged; then mv -f "$tmp" "$sdst"; say "  merged into $sdst"
          else fail "settings.json changed while merging; re-run — $sdst untouched"; fi
        else fail "settings merge did not validate — $sdst untouched"; fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- 2d. user-level rules -> symlinks
# ~/.claude/rules/*.md load into every session; link_into leaves a DIFFERING file alone with a WARN.
if [ $T_RULES = 1 ]; then
  say "-- 2d. Claude user-level rules (symlinks into this package) [--rules]"
  RULES="$CLAUDE_DIR/rules"
  link_into rule "$RULES" "$HERE"/claude/rules/*.md
  if [ -d "$RULES" ]; then
    for f in "$RULES"/*.md; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      [ -e "$HERE/claude/rules/$(basename "$f")" ] || say "  note  $f is machine-local; keep private rules outside this kit and manage them in owner-controlled configuration"
    done
  fi
fi

# ---------------------------------------------------------------- 3. global CLAUDE.md
if [ $T_GLOBAL = 1 ]; then
  say "-- 3. user-level CLAUDE.md [--global-claude-md] (provider-neutral standing orders)"
  gsrc="$HERE/standing-orders.md"; gdst="$CLAUDE_DIR/CLAUDE.md"
  if [ -L "$gdst" ] && [ "$(readlink "$gdst")" = "$gsrc" ]; then ok "$gdst already linked"; else
    if [ -f "$gdst" ] && [ ! -L "$gdst" ]; then
      plan "replace the existing regular file ~/.claude/CLAUDE.md ($(wc -l < "$gdst" | tr -d ' ') lines) with a symlink to $gsrc ($(wc -l < "$gsrc" | tr -d ' ') lines); backup first"
      say "        contents are not printed (private configuration); inspect yourself: diff -u \"$gdst\" \"$gsrc\""
      say "        keep personal instructions outside this kit in owner-controlled configuration; omit --global-claude-md to preserve this loader until your private composition is ready"
    elif [ -L "$gdst" ] && [ ! -e "$gdst" ]; then plan "replace ~/.claude/CLAUDE.md (currently a DANGLING symlink -> $(readlink "$gdst"); no standing orders load) with symlink -> $gsrc (backup first)"
    elif [ -e "$gdst" ] || [ -L "$gdst" ]; then plan "replace ~/.claude/CLAUDE.md (currently a symlink elsewhere) with symlink -> $gsrc (backup first)"
    else plan "link ~/.claude/CLAUDE.md -> $gsrc"; fi
    doit mkdir -p "$CLAUDE_DIR"; doit backup_path "$gdst"; doit ln -s "$gsrc" "$gdst"
  fi
fi

# ---------------------------------------------------------------- 3b. Codex global AGENTS.md
if [ $T_CODEXMD = 1 ]; then
  say "-- 3b. Codex global instructions ~/.codex/AGENTS.md [--codex-agents-md]"
  csrc="$HERE/standing-orders.md"; cdst="$HOME/.codex/AGENTS.md"
  if [ -L "$cdst" ] && [ "$(readlink "$cdst")" = "$csrc" ]; then ok "$cdst already linked"; else
    if [ -f "$cdst" ] && [ ! -L "$cdst" ] && [ -s "$cdst" ]; then
      plan "replace the existing NON-EMPTY ~/.codex/AGENTS.md ($(wc -l < "$cdst" | tr -d ' ') lines) with a symlink to $csrc; backup first (contents not printed)"
      say "        keep personal instructions outside this kit in owner-controlled configuration; omit --codex-agents-md to preserve this loader until your private composition is ready"
    elif [ -L "$cdst" ] && [ ! -e "$cdst" ]; then plan "replace ~/.codex/AGENTS.md (currently a DANGLING symlink -> $(readlink "$cdst")) with symlink -> $csrc (backup first)"
    elif [ -e "$cdst" ] || [ -L "$cdst" ]; then plan "replace ~/.codex/AGENTS.md (empty file or other symlink) with symlink -> $csrc (backup first)"
    else plan "link ~/.codex/AGENTS.md -> $csrc"; fi
    doit mkdir -p "$HOME/.codex"; doit backup_path "$cdst"; doit ln -s "$csrc" "$cdst"
  fi
  # Read-only inventory, never a planned or applied change: how much of a REPOSITORY's AGENTS.md
  # Codex loads. It reads only the first project_doc_max_bytes bytes (32768 when the key is absent)
  # and says nothing about the rest; ~/.codex/AGENTS.md above is loaded separately and whole
  # (measured on codex-cli 0.162.0). The top-level key is read from ~/.codex/config.toml; nothing
  # else of that file is printed, and it is never edited — the owner sets the key per Mac.
  # The answer is right for any valid TOML or it is "could not read", never a guessed number:
  #   1. a python3 on PATH that has tomllib (3.11+) parses the file. Exact, and it also knows a
  #      file that is not valid TOML;
  #   2. otherwise codex_limit_lines follows the file statement by statement and answers only
  #      when it followed ALL of it. It is not a validator: a malformed value on another line
  #      passes it unseen.
  # clim_from says where climit comes from: file | default (key absent) | notint | unread.
  ccfg="$HOME/.codex/config.toml"; climit=32768; clim_from=default; cwhy=""
  # Single quotes are required: this is Python source and nothing in it may be shell-expanded.
  # Prints one word: `int N`, absent, notint or invalid. Exit 3: this python3 has no tomllib.
  # shellcheck disable=SC2016
  CODEX_LIMIT_PY='
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
try:
    with open(sys.argv[1], "rb") as f:
        d = tomllib.load(f)
except ValueError:
    print("invalid"); sys.exit(0)
k = "project_doc_max_bytes"
if k not in d: print("absent")
elif type(d[k]) is int and d[k] >= 0: print("int", d[k])
else: print("notint")
'
  re_blank='^[[:space:]]*(#.*)?$'
  # ml_rest <delimiter> <text>: does a multi-line string close in <text>? Sets ml_r to open,
  # closed (and the statement ends cleanly after it) or unsure. A basic string may escape its own
  # quotes, so a line that holds both a backslash and the delimiter is not decided here.
  ml_rest() {
    local q="$1" t="$2" after
    case "$t" in *"$q"*) ;; *) ml_r=open; return 0;; esac
    if [ "${q:0:1}" = '"' ]; then case "$t" in *\\*) ml_r=unsure; return 0;; esac; fi
    after="${t#*"$q"}"; after="${after#"${q:0:1}"}"; after="${after#"${q:0:1}"}"   # up to two more quotes end the string
    if [[ $after =~ $re_blank ]]; then ml_r=closed; else ml_r=unsure; fi
    return 0
  }
  # bracket_scan <text>: one line of an array or inline table. Counts [ and { in $depth, skips
  # single-line strings, stops at a comment. br_ok=0 for what it does not follow: a multi-line
  # string inside, a string that does not end on its line, a stray bracket, text after the close.
  bracket_scan() {
    local t="$1" n=${#1} i=0 ch dq='"' sq="'"
    br_ok=1
    while [ "$i" -lt "$n" ]; do
      ch="${t:$i:1}"
      case "$ch" in
        '#') return 0;;
        '['|'{') depth=$((depth+1));;
        ']'|'}') depth=$((depth-1))
          if [ "$depth" -lt 0 ]; then br_ok=0; return 0; fi
          if [ "$depth" -eq 0 ]; then
            if ! [[ ${t:$((i+1))} =~ $re_blank ]]; then br_ok=0; fi
            return 0
          fi;;
        "$dq") if [ "${t:$i:3}" = "$dq$dq$dq" ]; then br_ok=0; return 0; fi
          i=$((i+1))
          while [ "$i" -lt "$n" ] && [ "${t:$i:1}" != "$dq" ]; do
            if [ "${t:$i:1}" = '\' ]; then i=$((i+1)); fi
            i=$((i+1))
          done
          if [ "$i" -ge "$n" ]; then br_ok=0; return 0; fi;;
        "$sq") if [ "${t:$i:3}" = "$sq$sq$sq" ]; then br_ok=0; return 0; fi
          i=$((i+1))
          while [ "$i" -lt "$n" ] && [ "${t:$i:1}" != "$sq" ]; do i=$((i+1)); done
          if [ "$i" -ge "$n" ]; then br_ok=0; return 0; fi;;
      esac
      i=$((i+1))
    done
    return 0
  }
  # codex_limit_lines <file>: prints `int N`, absent, notint or unread. It knows comments, table
  # headers (the first one ends the top level), bare and quoted keys, dotted keys, single-line
  # values, multi-line basic and literal strings, and arrays and inline tables over several lines.
  # Anything else — a key with an escape in it, a line that is no statement, a value that is no
  # TOML value, a string or array that never closes, the key defined twice — is unread: it never
  # answers from a file it lost. A dotted key under the name, or a table of that name, is notint.
  codex_limit_lines() {
    local file="$1" line key kpart val num rest state=top top=1 found="" kind dq='"' sq="'" q3b q3l
    local re_header='^[[:space:]]*\[' re_hkey re_scalar
    local re_part='([A-Za-z0-9_-]+|"[^"\\]*"|'"'[^']*'"')'
    local re_stmt="^[[:space:]]*(${re_part}([[:space:]]*\\.[[:space:]]*${re_part})*)[[:space:]]*=[[:space:]]*(.*)\$"
    local re_dec='^\+?(0|[1-9](_?[0-9])*)$' re_hex='^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$' re_oct='^0o[0-7](_?[0-7])*$' re_bin='^0b[01](_?[01])*$'
    re_hkey="^[[:space:]]*\\[\\[?[[:space:]]*${re_part}"
    # every single-line value TOML has: a basic or literal string, a boolean, a number or a date
    re_scalar="^(${dq}([^${dq}\\\\]|\\\\.)*${dq}|${sq}[^${sq}]*${sq}|true|false|[-+]?(inf|nan)|[-+]?[0-9][0-9A-Za-z_.:+-]*( [0-9][0-9:.+Zz-]*)?)[[:space:]]*(#.*)?\$"
    q3b="$dq$dq$dq"; q3l="$sq$sq$sq"; depth=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      if [ "$state" = mlb ] || [ "$state" = mll ]; then
        if [ "$state" = mlb ]; then ml_rest "$q3b" "$line"; else ml_rest "$q3l" "$line"; fi
        case "$ml_r" in open) ;; closed) state=top;; *) echo unread; return 0;; esac
        continue
      fi
      if [ "$state" = arr ]; then
        bracket_scan "$line"
        if [ "$br_ok" -ne 1 ]; then echo unread; return 0; fi
        if [ "$depth" -eq 0 ]; then state=top; fi
        continue
      fi
      if [[ $line =~ $re_blank ]]; then continue; fi
      if [[ $line =~ $re_header ]]; then
        # a table named after the key defines the key, as a table; a name this reader cannot
        # spell out (an escape in a quoted key) might be that table
        if ! [[ $line =~ $re_hkey ]]; then echo unread; return 0; fi
        case "${BASH_REMATCH[1]}" in project_doc_max_bytes|"${dq}project_doc_max_bytes${dq}"|"${sq}project_doc_max_bytes${sq}")
          if [ -n "$found" ]; then echo unread; return 0; fi
          found=notint;;
        esac
        top=0; continue
      fi
      if ! [[ $line =~ $re_stmt ]]; then echo unread; return 0; fi
      key="${BASH_REMATCH[1]}"; kpart="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[5]}"; kind=scalar
      case "$val" in
        "$q3b"*) kind=other; ml_rest "$q3b" "${val#"$q3b"}"
          case "$ml_r" in open) state=mlb;; closed) ;; *) echo unread; return 0;; esac;;
        "$q3l"*) kind=other; ml_rest "$q3l" "${val#"$q3l"}"
          case "$ml_r" in open) state=mll;; closed) ;; *) echo unread; return 0;; esac;;
        '['*|'{'*) kind=other; depth=0; bracket_scan "$val"
          if [ "$br_ok" -ne 1 ]; then echo unread; return 0; fi
          if [ "$depth" -gt 0 ]; then state=arr; fi;;
        *) if ! [[ $val =~ $re_scalar ]]; then echo unread; return 0; fi;;   # not a value TOML has
      esac
      if [ "$top" -eq 1 ]; then
        # the key itself, or a dotted key under it (which makes the key a table)
        case "$kpart" in project_doc_max_bytes|"${dq}project_doc_max_bytes${dq}"|"${sq}project_doc_max_bytes${sq}")
          if [ -n "$found" ]; then echo unread; return 0; fi        # defined twice: not valid TOML
          found=notint
          if [ "$key" = "$kpart" ] && [ "$kind" = scalar ]; then
            num="${val%%[[:space:]#]*}"; rest="${val#"$num"}"
            if [ "${#num}" -le 15 ] && [[ $rest =~ $re_blank ]]; then
              if [[ $num =~ $re_dec ]]; then num="${num#+}"; found="int ${num//_/}"
              elif [[ $num =~ $re_hex ]]; then num="${num#0x}"; found="int $((16#${num//_/}))"
              elif [[ $num =~ $re_oct ]]; then num="${num#0o}"; found="int $((8#${num//_/}))"
              elif [[ $num =~ $re_bin ]]; then num="${num#0b}"; found="int $((2#${num//_/}))"
              fi
            fi
          fi;;
        esac
      fi
    done < "$file"
    if [ "$state" != top ]; then echo unread; return 0; fi           # a string or an array never closed
    echo "${found:-absent}"
  }
  if [ -f "$ccfg" ] && [ -r "$ccfg" ]; then
    cres=""
    if command -v python3 >/dev/null 2>&1; then cres="$(python3 -I -B -c "$CODEX_LIMIT_PY" "$ccfg" 2>/dev/null)" || cres=""; fi
    case "$cres" in
      "int "*|absent|notint) ;;
      invalid) cres=unread; cwhy="it is not valid TOML";;
      *) cres="$(codex_limit_lines "$ccfg")" || cres=unread
         cwhy="no python3 with tomllib is on PATH to parse it, and this installer's own reader could not follow the file";;
    esac
    case "$cres" in
      "int "*) cnum="${cres#int }"
        case "$cnum" in ''|*[!0-9]*|????????????????*) clim_from=notint;; *) climit="$cnum"; clim_from=file;; esac;;
      absent) clim_from=default;;
      notint) clim_from=notint;;
      *) clim_from=unread;;
    esac
  fi
  case "$clim_from" in
    file) ok "codex loads the first $climit bytes of a repository's AGENTS.md (project_doc_max_bytes, set in ~/.codex/config.toml)";;
    notint) warn "codex: project_doc_max_bytes is set in ~/.codex/config.toml but not as a plain integer; the contracts below are measured against the default, $climit bytes";;
    unread) warn "codex: could not read project_doc_max_bytes from ~/.codex/config.toml ($cwhy); the contracts below are measured against the default, $climit bytes";;
    *) warn "codex loads only the first $climit bytes of a repository's AGENTS.md and says nothing about the rest: project_doc_max_bytes is not set in ~/.codex/config.toml, so the default applies. The owner sets the key per Mac; this installer never edits that file";;
  esac
  say "        coverage: $CONTRACTS_ROOT/*/AGENTS.md only (select --contracts-root DIR for another root)"
  if [ ! -d "$CONTRACTS_ROOT" ]; then ok "no $CONTRACTS_ROOT directory: no repository contract in the selected inventory root"
  else
    ncontracts=0; nover=0
    for cfile in "$CONTRACTS_ROOT"/*/AGENTS.md; do
      [ -f "$cfile" ] || continue          # no match, a dangling link or a directory: nothing to size
      crepo="${cfile%/AGENTS.md}"; crepo="${crepo##*/}"
      csize="$({ wc -c < "$cfile"; } 2>/dev/null | tr -d ' ')" || csize=""   # `<` follows a symlink
      case "$csize" in ''|*[!0-9]*) warn "contract $crepo/AGENTS.md could not be sized"; continue;; esac
      ncontracts=$((ncontracts+1))
      if [ "$csize" -gt "$climit" ]; then
        nover=$((nover+1))
        warn "contract over the Codex limit: $crepo/AGENTS.md is $csize bytes, the limit is $climit — Codex loads only its first $climit bytes"
      fi
    done
    [ "$nover" -gt 0 ] || ok "$ncontracts repository contract(s) at $CONTRACTS_ROOT/*/AGENTS.md, none over the $climit-byte limit"
  fi
fi

# ---------------------------------------------------------------- 3d. launchers on PATH
if [ $T_BIN = 1 ]; then
  say "-- 3d. launchers on PATH [--bin] (~/.local/bin/claude-review, codex-review; claude-write, codex-write; session-ledger)"
  BIN="$HOME/.local/bin"
  # Both launcher scripts live in bin/. The retained Codex skill shim supports older links.
  # Writer names select the explicit writing lane; review names select the reading lane.
  for pair in "claude-review:$HERE/bin/claude_job.sh" "codex-review:$HERE/bin/codex_job.sh" \
              "claude-write:$HERE/bin/claude_job.sh" "codex-write:$HERE/bin/codex_job.sh" \
              "session-ledger:$HERE/bin/session_ledger.py"; do
    name="${pair%%:*}"; target="${pair#*:}"; link="$BIN/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then ok "$name already linked"; continue; fi
    case "$name" in *-write|session-ledger) why="";; *) why=" — the launchers moved into bin/";; esac
    if [ -L "$link" ] && [ "$(readlink "$link")" != "$target" ]; then
      plan "repoint $link (currently -> $(readlink "$link")) to $target$why (backup first)"
    elif [ -e "$link" ]; then plan "replace $link with symlink -> $target (backup first)"
    else plan "link $link -> $target"; fi
    doit mkdir -p "$BIN"; doit backup_path "$link"; doit ln -s "$target" "$link"
  done
  doit chmod +x "$HERE"/bin/*.sh 2>/dev/null || true
  doit chmod +x "$HERE"/claude/skills/*/scripts/*.sh 2>/dev/null || true
  case ":$PATH:" in *":$BIN:"*) ok "$BIN is on PATH";; *) warn "$BIN is not on PATH in this shell — add it (e.g. in ~/.zshrc) or call the launchers by path";; esac
fi

# ---------------------------------------------------------------- 4b. remove deprecated codex MCP registration
if [ $T_RMMCP = 1 ] && [ "$MODE" = apply ]; then
  say "-- 4b. deprecated codex MCP registration [--remove-codex-mcp]"
  if command -v claude >/dev/null 2>&1; then
    if claude mcp get codex >/dev/null 2>&1; then
      plan "claude mcp remove codex -s user  (the independent codex exec adapter remains available)"
      if [ "$MODE" = apply ]; then claude mcp remove codex -s user || fail "claude mcp remove codex -s user failed — run it by hand (scope may be local/project: claude mcp get codex)"; fi
    else ok "no 'codex' MCP registration"; fi
  else
    if [ "$MODE" = apply ]; then fail "claude absent — cannot remove the MCP registration"; else warn "claude absent"; fi
  fi
fi

# ---------------------------------------------------------------- 6. memory relocation (opt-in)
if [ ${#MEM_PATHS[@]} -gt 0 ]; then
  say "-- 6. Claude memory relocation [--memory]"
  # One errno-aware probe owns metadata lookup and enumeration. Shell -e/-d tests
  # cannot distinguish an absent path from an inaccessible ancestor.
  memory_probe() {
    if ! memory_state="$(python3 -I -B - "$1" "$2" "${3:-}" <<'EOF'
# memory directory-state probe
import os, stat, sys
path, role, expected = sys.argv[1:]
linked = False
try:
    metadata = os.lstat(path)
    linked = stat.S_ISLNK(metadata.st_mode)
    if linked:
        if role != 'source':
            print('invalid')
            sys.exit(0)
        metadata = os.stat(path)
        if os.path.realpath(path) == os.path.realpath(expected):
            print('linked')
            sys.exit(0)
    if not stat.S_ISDIR(metadata.st_mode):
        print('invalid')
    elif role == 'same-store':
        print('empty')  # Existing canonical link needs no contents decision or rewrite.
    else:
        with os.scandir(path) as entries:
            state = 'populated' if next(entries, None) is not None else 'empty'
        print(('link-' if linked else '') + state)
except FileNotFoundError:
    print('link-absent' if linked else 'absent')
except OSError:
    print('failed')
EOF
)"; then memory_state=failed; fi
  }
  for repo in "${MEM_PATHS[@]}"; do
    # Physical path: the provider derives the slug from it, whatever spelling reached this repository.
    abs="$(cd "$repo" 2>/dev/null && pwd -P)" || { fail "memory: $repo is not a directory"; continue; }
    slug="$(printf '%s' "$abs" | sed -E 's#[^A-Za-z0-9-]#-#g')"
    src="$CLAUDE_DIR/projects/$slug/memory"; dst="$MEMORY_ROOT/$slug"
    memory_probe "$src" source "$dst"; src_state="$memory_state"
    case "$src_state" in
      failed) fail "memory: cannot inspect or enumerate $src; source and destination preserved"; continue;;
      invalid) fail "memory: $src is not a directory — nothing changed"; continue;;
      link-populated) fail "memory: populated linked memory targets a different store — preserve both stores and migrate manually; nothing changed"; continue;;
      absent|empty|populated|link-absent|link-empty|linked) ;;
      *) fail "memory: unexpected source inspection state for $src; source and destination preserved"; continue;;
    esac
    probe_role=destination; [ "$src_state" != linked ] || probe_role=same-store
    memory_probe "$dst" "$probe_role"; dst_state="$memory_state"
    case "$dst_state" in
      failed) fail "memory: cannot inspect or enumerate $dst; source and destination preserved"; continue;;
      invalid) fail "memory: $dst is a symlink or not a directory — refusing to copy into it"; continue;;
      absent|empty|populated) ;;
      *) fail "memory: unexpected destination inspection state for $dst; source and destination preserved"; continue;;
    esac
    if [ "$src_state" = linked ]; then ok "memory for $abs already linked"; continue; fi
    if [ "$src_state" = populated ]; then
      if [ "$dst_state" = populated ]; then
        fail "memory: both $src and $dst have content — merge by hand, then re-run"; continue
      fi
      plan "copy $src -> $dst, move original to a unique sibling backup ($src.local-backup-$TS.*), link $src -> $dst"
      if [ "$MODE" = apply ]; then
        mkdir -p "$(dirname "$dst")"
        staged="$(mktemp -d "$(dirname "$dst")/.memory-stage.XXXXXX")" || { fail "memory: could not stage copy"; continue; }
        if ! cp -pR "$src/." "$staged/" || ! diff -rq "$src" "$staged" >/dev/null 2>&1; then
          rm -rf "$staged"; fail "memory: copy or verification failed; source and destination preserved"; continue
        fi
        memory_probe "$dst" destination
        case "$memory_state" in
          failed) rm -rf "$staged"; fail "memory: cannot inspect or enumerate $dst after copying; source and destination preserved"; continue;;
          populated|invalid) rm -rf "$staged"; fail "memory: destination changed while copying; source and destination preserved"; continue;;
          absent|empty) ;;
          *) rm -rf "$staged"; fail "memory: unexpected destination inspection state after copying; source and destination preserved"; continue;;
        esac
        # Reserve every prerequisite before publishing the final destination. A failed
        # reservation must not turn the next run into a two-populated-stores conflict.
        source_backup="$(mktemp -d "$src.local-backup-$TS.XXXXXX")" || {
          rm -rf "$staged"; fail "memory: could not reserve source backup; source and destination preserved"; continue
        }
        if ! python3 -I -B - "$staged" "$dst" <<'EOF'
import os,sys
os.replace(sys.argv[1],sys.argv[2])
EOF
        then
          rm -rf "$staged"; rmdir "$source_backup"
          fail "memory: could not publish staged copy; source and destination preserved"; continue
        fi
        rmdir "$source_backup"
        mv "$src" "$source_backup"
        say "  BACKUP $src -> $source_backup"
        ln -s "$dst" "$src"
      fi
    elif [ "$dst_state" != absent ] || [ "$src_state" != absent ]; then
      # Nothing to merge — the local side holds no memories — so link it at the external
      # store, creating that project directory when explicitly selected for the first time.
      # Only --apply reaches the mkdir/ln: in check mode every doit is a no-op.
      mk=""; [ "$dst_state" != absent ] || mk=" (creating $dst)"
      case "$src_state" in
        link-absent|link-empty) plan "replace the existing symlink $src (-> $(readlink "$src")) with a link to $dst$mk (backup first)";;
        empty) plan "back up $src (no memories in it), then link $src -> $dst$mk";;
        absent) plan "link $src -> $dst$mk (no local memory yet)";;
        *) fail "memory: unexpected source inspection state before linking; source and destination preserved"; continue;;
      esac
      doit mkdir -p "$dst"; doit mkdir -p "$(dirname "$src")"; doit backup_path "$src"; doit ln -s "$dst" "$src"
    else
      fail "memory: nothing to relocate for $abs (no $src and no $dst)"
    fi
  done
fi

# ---------------------------------------------------------------- summary
say "== done: $changes planned/applied change(s), $problems warning(s), $failed failed target(s)"
[ "$MODE" = check ] && [ "$changes" -gt 0 ] && say "   re-run with --apply plus the exact targets you authorize (see --help)"
say "   global instruction changes take effect in a new session; inspect installed links before use"
[ "$failed" -eq 0 ] || exit 1
exit 0
