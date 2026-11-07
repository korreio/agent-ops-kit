#!/usr/bin/env bash
# codex_job.sh — detached Codex roster lane, with native permission profiles.
# codex-review (and this file's own name) selects an independent read-only lane;
# codex-write selects a bounded workspace writer whose .git stays read-only.
# Both share a minimal literal denial list, not a boundary. Native role files alone inherit the
# parent's permissions, so use this launcher for strictly read-only roles.
#
# Usage: <out-dir> <job-name> <brief-file> [--cwd DIR] [--add-dir DIR]... [--role ROLE]
#   [--model MODEL] [--effort EFFORT] [--schema FILE] [--resume THREAD]
#   [--timeout 10m] [--short-timeout-ok] [--project-config | --no-project-config] [--wait]
#   [--sandbox read-only|workspace-write]
# Positionals come first; a leading "-" is refused before writing anything, and
# so is an empty --cwd, which /bin/bash 3.2 would read as the caller's directory, and a --resume
# that is empty or begins with "-", which codex exec resume would read as an option.
# --role selects a tested roster copy (reviewer / writer-bounded by default).
# An explicit reviewer pin still supports the existing own-family tiers.
# --sandbox read-only is a compatibility spelling for review commands; workspace-write
# requires the explicit codex-write command. It never emits -s or sandbox_mode. Full access
# remains an owner-selected session choice, never a launcher fallback.
# --timeout works as in claude_job.sh: 10m for a review and 60m for a writer by default, with a
# 300 s floor. Below the floor the launcher exits 2 unless --short-timeout-ok is given, which
# result.json records. The watchdog sends TERM, then KILL after 5 s, records 124 and writes every
# receipt.
# --add-dir DIR is repeatable. On the writer lane it goes to `codex exec --add-dir` and so widens
# writing. `codex exec resume` has no such flag (help on 0.166.0), so a writer --resume with
# --add-dir is refused (exit 2). On the review lane it is accepted and has no effect beyond a note
# in the launch line, because that profile already reads the whole disk.
#
# Repository configuration. One rule on both launchers, for both lanes: a repository the owner has
# already trusted behaves natively, and an unseen repository does not run its project configuration.
# Why: a writer run in an unseen repository otherwise makes Codex trust it persistently and run its
# MCP servers. Observed on 0.166.0 with `codex exec -s workspace-write`: it connected the servers in
# the repository's .codex/config.toml and wrote trust_level = "trusted" into ~/.codex/config.toml, so
# a later codex-review of that repository loads its project configuration too; `-s read-only` did
# neither. The launcher reads `projects` from $CODEX_HOME/config.toml, by default
# ~/.codex/config.toml, and never writes that file. trust_level "trusted" for --cwd, its physical
# path or the nearest folder holding a .git entry means native: nothing added. A linked worktree does
# not inherit its main checkout's trust, because nothing a repository controls can prove that link.
# An explicit "untrusted" is the owner's: it is preserved and nothing is added. No entry, or a file
# that is missing, unreadable or malformed, adds a per-run `projects` override marking every one of
# those paths untrusted (codex/lane_config.py), which stops Codex creating trust and persists
# nothing, plus claude_job.sh's notice in the developer instructions.
# --no-project-config forces exclusion anywhere, a trusted repository included. --project-config is
# the owner's explicit statement of trust for this run: the same override marks those paths trusted,
# so project configuration really loads, on a read-only lane and over a recorded "untrusted" too,
# and nothing is persisted. Giving both is a usage error (exit 2). <job>.project-config holds on or
# off, then the reason: trusted, unseen, unreadable-trust or flag, or untrusted for the explicit
# entry. The launch line shows the same.
#
# Native profiles use lane-only names supplied per run, so installed tables
# cannot retain stale keys through merging. These paths also work before the
# separately authorized installation. SessionFlags.default_permissions wins
# over a loaded legacy user sandbox_mode on installed Codex 0.162.0. Fresh and
# resumed runs select the same profile and start inside --cwd. The caller's
# unrelated configuration is still loaded. Model/effort/instructions come from
# codex/agents, with copies checked against roster.md.
#
# Writes <job>.events.jsonl (the live event stream), <job>.json (the final message, as
# `codex exec -o` writes it), <job>.result.json (normalized, the fields of claude_job.sh's
# result.json: exit_class, exit, provider_exit, status, source, schema_valid, refusal_text,
# limit_text, result and the rest, those Codex does not report being null), .thread,
# .start/.end/.exit/.pid, .monitor, .stderr, .codex.pid (pid=, then the child's identity, see
# Identity below, once it is codex, or an unrecorded: reason), .role and .permissions under
# <out-dir>, and .lane and .project-config (line 1 on or off, line 2 the reason), which pre-launch
# failures write too.
# Each OUT/JOB is one permanent attempt, including failures. Retry or resume a
# provider thread with a fresh job name or output directory.
# --schema makes a strict job-owned copy for the CLI's structured output.
# Every lane has approval_policy=never: a denied action is returned to the
# worker, never escalated into a writable review or a human prompt.
# A nested CLI needs existing login access at startup. If the parent's literal
# denial list blocks that, the coordinator can request an automatically reviewed
# outside-sandbox launch that retains this child's native profile. No login,
# credential read, permission bypass or switch to Full access is a fallback.
#
# Workers never mutate Git. The writer profile protects its workspace .git;
# native worker hooks block direct Git mutations. Neither is hostile-code
# isolation: the coordinator records and checks HEAD/index/branches/stashes,
# edited scope and process liveness before/after every writer, whatever exit.
# These checks describe what happened; no edits are automatically rolled back.
#
# Exit classes (in .exit, result.json and --wait's exit), with claude_job.sh's names and numbers:
# 0 success · 1 reviewer_error · 2 usage · 3 not_authenticated · 5 refusal · 7 no_verdict ·
# 124 timeout · 125 codex_missing, plus thread_busy (exit 1), the exact observed active-writer
# error on a resume. The raw provider exit stays in result.json as provider_exit.
# success needs exit 0, a completed last turn and a final message, and with --schema output that
# satisfies it. Exit 0 with no completed turn or no final message is no_verdict, never success.
# Exit 0 whose last turn failed is reviewer_error, as an is_error result is in claude_job.sh, and
# refusal is that script's heuristic, read from the final message. not_authenticated comes from the
# pre-launch `codex login status`, whose logged-out answer is "Not logged in": exit 3, and no run
# starts. A status that fails in other words does not block the launch. partial (4) and limit (6)
# are not produced: `codex exec` has no turn cap, and no provider limit text has been observed, so
# other wording stays reviewer_error until observed. A normalizer that fails, or whose exit cannot be
# read back, never leaves a raw exit 0: the job ends reviewer_error (a watchdog timeout stays
# timeout) and result.json has `normalization_error`. A writer keeps these classes: `success` says
# the run ended normally, never that the edit is right or in scope.
#
# Identity. Every identity this launcher records (.monitor, line 2 of .codex.pid) and every check
# of one is the line printed by exactly LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=
# Plain ps prints lstart in the caller's time zone and language, so after an automatic time-zone
# change, or from a shell with another language, the same process would no longer match.
# Recording it never stops the launcher: a .monitor that cannot be written is missing.
# The launcher sets that environment through env, not a shell prefix: bash 5.3.20 crashed
# (SIGSEGV, exit 139) running `LC_ALL=C TZ=UTC0 <script>` in a command substitution inside a
# background subshell when the script was newly written, so a ps that had answered read as none.
# Cancellation has two routes, both only while .end is absent. TERM the monitor in <job>.pid, only
# when the live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= equals .monitor (unrecorded:, empty
# or missing means do not signal), and signal nothing else that way, never KILL it: at each 0.5 s
# poll it sends codex TERM until it is gone, then writes every receipt, normally reviewer_error,
# exit 1, provider_exit 143, with a `cancelled` line in .stderr. A codex that ignores TERM runs on
# until the watchdog. HUP changes nothing. Or re-read .codex.pid. Its line 2 is the child's
# identity once it was codex; unrecorded:, missing or short means do not signal. TERM only if the
# live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= equals line 2 (same start, command codex),
# then re-check liveness.
# No lock files are deleted.
# Lost. The monitor writes .exit and result.json, then .end; if it dies before .end, .end never
# comes. While <job>.end is absent the job is lost only on proof: <job>.monitor holds a recorded
# identity and the live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= prints another non-empty
# line, or ps prints nothing (or .monitor is unrecorded:, empty or missing) and kill -0 <pid> says
# No such process; then .end must still be absent. Anything else, such as a refused ps or kill or a
# pid that is not a number, means cannot tell: keep waiting. Lost means completion is unconfirmed:
# an .exit or result.json present is not proof, and the fresh-reviewer fallback applies. Signal
# nothing for it; codex may still run, so read .codex.pid by the same rule. --wait does this check.
set -euo pipefail
unset CDPATH   # internal cd output must contain only pwd, never CDPATH diagnostics

# ---------------------------------------------------------------- normalizer (single source)
# Held in a variable so that the `normalize` subcommand runs the same code over recorded events,
# which is how tests/test_launchers.sh covers the classes without a real Codex run. Single quotes
# are required: this is Python source and nothing in it may be shell-expanded.
# shellcheck disable=SC2016
NORMALIZE_PY='
import json,re,sys
events,message_file,norm,rc,short_ok,cap=sys.argv[1:7]
schema_file=sys.argv[7] if len(sys.argv)>7 else ""
stderr_file=sys.argv[8] if len(sys.argv)>8 else ""
sch=None; schema_error=None
if schema_file:
    try: sch=json.load(open(schema_file))
    except Exception: sch=None; schema_error="the --schema file could not be read when the result was normalized"
if not isinstance(sch,dict) or not sch.get("properties"):
    if schema_file and schema_error is None: schema_error="the --schema file declares no properties to check a verdict against"
    sch=None

def schema_ok(obj):
    """Structural check, as in claude_job.sh: every required key present and every
    enum-constrained value in its enum. With no --schema, any non-empty object counts."""
    if not isinstance(obj,dict): return False
    if sch is None: return bool(obj)
    props=sch.get("properties") or {}
    req=sch["required"] if isinstance(sch.get("required"),list) else list(props.keys())
    if any(k not in obj for k in req): return False
    for k,p in props.items():
        if k in obj and isinstance(p,dict) and p.get("enum") and obj[k] not in p["enum"]: return False
    return True

# The final message belongs to the last turn: a turn that starts clears it. Plain `error` events
# are not a failure on their own, because a stream that reconnects goes on to complete.
turn=None; final=""; error_text=None
try: fh=open(events,encoding="utf-8",errors="ignore")
except Exception: fh=[]
for line in fh:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if not isinstance(d,dict): continue
    kind=d.get("type")
    if kind=="turn.started": turn="started"; final=""
    elif kind=="turn.completed": turn="completed"
    elif kind=="turn.failed":
        turn="failed"
        failure=d.get("error")
        error_text=str((failure.get("message") if isinstance(failure,dict) else failure) or error_text or "")[:1000] or None
    elif kind=="error": error_text=str(d.get("message") or error_text or "")[:1000] or None
    elif kind=="item.completed":
        item=d.get("item")
        if isinstance(item,dict) and item.get("type")=="agent_message" and isinstance(item.get("text"),str):
            if item["text"].strip(): final=item["text"]
if turn=="completed" and not final:
    try: final=open(message_file,encoding="utf-8",errors="ignore").read()
    except Exception: final=""
final=final.strip()

# Prefer the first object that VALIDATES; fall back to the first object of any shape.
res=None; source="none"; first=None; dec=json.JSONDecoder(); i=final.find("{")
while i!=-1 and res is None:
    try:
        obj,_=dec.raw_decode(final[i:])
        if isinstance(obj,dict):
            if first is None: first=obj
            if schema_ok(obj): res=obj; source="result_text"
    except Exception: pass
    i=final.find("{",i+1)
if res is None and first is not None: res=first; source="result_text"
schema_valid=schema_ok(res) if isinstance(res,dict) else False

cls={"0":"success","2":"usage","124":"timeout"}.get(rc,"reviewer_error")
if cls=="success":
    if turn=="failed": cls="reviewer_error"
    elif turn!="completed" or not final: cls="no_verdict"

# Only the exact observed active-writer error, as a whole line of a failed run.
if cls=="reviewer_error" and rc!="0" and stderr_file:
    try: said=open(stderr_file,encoding="utf-8",errors="ignore").read()
    except Exception: said=""
    if re.search(r"^thread/resume failed: thread \S+ already has an active writer \(code -32600\)$",said,re.M):
        cls="thread_busy"

# The refusal heuristic of claude_job.sh; see that header for what it can and cannot see.
def _expand(t):
    t=t.replace("\u2019","\x27")
    t=re.sub(r"\bI\x27m\b","I am",t,flags=re.I)
    t=re.sub(r"\bcan\x27?t\b","cannot",t,flags=re.I)
    t=re.sub(r"\bwon\x27?t\b","will not",t,flags=re.I)
    return t
REFUSAL=re.compile(r"\bI (?:cannot|will not|am not able to|am unable to) "
                   r"(?:help|assist|comply|do|provide|continue|complete|perform|produce|write|review|engage|proceed)"
                   r"|\bI (?:must|have to|will) decline\b|\bI decline\b|\bI am not going to\b", re.I)
refusal_text=None
if cls in ("success","reviewer_error") and not schema_valid and final:
    if len(final)<=1500 and REFUSAL.search(_expand(final[:400])):
        cls="refusal"; refusal_text=final[:1000]

if cls=="success" and sch is not None and not schema_valid:
    cls="no_verdict"

normalized_exit={"success":0,"reviewer_error":1,"thread_busy":1,"usage":2,"refusal":5,"no_verdict":7,"timeout":124}[cls]
json.dump({"exit_class":cls,"exit":normalized_exit,"provider_exit":int(rc) if rc.isdigit() else rc,"status":("turn."+turn) if turn else None,"stop_reason":None,
           "short_timeout_accepted":bool(int(short_ok)),"timeout_cap_s":int(cap),"is_error":{"failed":True,"completed":False}.get(turn),
           "duration_ms":None,"permission_denials":None,"total_cost_usd":None,"source":source,"schema_valid":schema_valid,
           "refusal_text":refusal_text,"limit_text":None,"schema_error":schema_error,"error_text":error_text,"result":res or {}}, open(norm,"w"), indent=1)
'

# ---------------------------------------------------------------- help and normalize subcommand
# Help before the positionals: the option loop below only runs after three of them, so a bare
# `--help` would otherwise die on a missing out-dir.
show_help() { awk 'NR==1{next} /^#/ || /^$/{print; next} {exit}' "$0"; exit 0; }
case "${1:-}" in -h|--help) show_help;; esac
if [ "${1:-}" = normalize ]; then
  [ $# -ge 5 ] || { echo "usage: $0 normalize <events.jsonl> <message-file> <result.json> <rc> [short_ok] [cap] [schema] [stderr]" >&2; exit 2; }
  exec python3 -I -B -c "$NORMALIZE_PY" "$2" "$3" "$4" "$5" "${6:-0}" "${7:-600}" "${8:-}" "${9:-}"
fi

# The NAME this script is run by picks the default sandbox: install.sh --bin links `codex-review`
# and `codex-write` to this one file. Only a name ending in -write is the writer command; every
# other name (the review link, this file's own, the old skill shim) starts read-only, as before.
invoked="${0##*/}"
case "$invoked" in *-write) writer_cmd=1;; *) writer_cmd=0;; esac

# A positional that begins with "-" is an option in the wrong place, not a name: `codex-write <out>
# --cwd <brief>` used to take --cwd as the job name (the name pattern allows it) and run in the
# caller's directory. Refused here, before the options are read and before anything is written.
no_dash() { case "$2" in -*) echo "$invoked: the $1 begins with \"-\" ($2). Options go after the three positionals: <out-dir> <job-name> <prompt-file> [options]" >&2; exit 2;; esac; }
# The check runs on the words as given, BEFORE the required-argument expansion below: a call
# that is also short (`<out> --cwd`) must get this refusal, not the shell's "parameter not set".
no_dash out-dir "${1-}"; no_dash "job name" "${2-}"; no_dash "prompt file" "${3-}"
out="${1:?out-dir}"; job="${2:?job-name}"; prompt_file="${3:?prompt-file}"; shift 3
cwd="$PWD"; model=""; effort=""; schema=""; sandbox="read-only"; resume=""; wait_flag=0; role=""; timeout="10m"; short_ok=0; project_on=0; project_off=0
add_dirs=()
[ "$writer_cmd" -eq 0 ] || { sandbox="workspace-write"; timeout="60m"; }
fresh_cmd="codex-review"; [ "$writer_cmd" -eq 0 ] || fresh_cmd="$invoked"   # what a busy thread's advice names
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      # An unset variable in the caller: /bin/bash 3.2 would stay in the caller's directory.
      [ -n "${2:-}" ] || { echo "$invoked: --cwd needs a directory; an empty value would run in the caller's directory" >&2; exit 2; }
      cwd="$2"; shift 2;;
    --add-dir) add_dirs+=("$2"); shift 2;;
    --model) model="$2"; shift 2;;
    --effort) effort="$2"; shift 2;;
    --schema) schema="$2"; shift 2;;
    --role) role="$2"; shift 2;;
    --sandbox)
      if [ "$writer_cmd" -eq 0 ] && [ "$2" = workspace-write ]; then
        echo "$invoked is a review command and refuses --sandbox workspace-write; use codex-write for owner-authorized writing" >&2; exit 2
      fi
      sandbox="$2"; shift 2;;
    --resume)
      # An empty value or one beginning with "-" would reach `codex exec resume` as an option.
      case "${2:-}" in ''|-*) echo "$invoked: --resume needs a thread id; an empty value or one beginning with \"-\" would reach codex exec resume as an option" >&2; exit 2;; esac
      resume="$2"; shift 2;;
    --timeout) timeout="$2"; shift 2;;
    --short-timeout-ok) short_ok=1; shift;;
    --project-config) project_on=1; shift;;
    --no-project-config) project_off=1; shift;;
    --wait) wait_flag=1; shift;;
    -h|--help) show_help;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$project_on" -eq 1 ] && [ "$project_off" -eq 1 ]; then
  echo "$invoked: --project-config and --no-project-config contradict each other; give at most one" >&2; exit 2
fi
if [ "$writer_cmd" -eq 0 ]; then
  case "$role" in writer-bounded|writer-takeover)
    echo "$invoked is a review command and refuses writer roles; use codex-write for owner-authorized writing" >&2; exit 2;;
  esac
fi
if [ "$writer_cmd" -eq 1 ] && [ "$sandbox" = read-only ]; then
  echo "$invoked is the writer command and does not run read-only; for a read-only job use codex-review" >&2; exit 2
fi
# The writer command has one lane; the compatibility spelling cannot widen its fence.
if [ "$writer_cmd" -eq 1 ] && [ "$sandbox" != workspace-write ]; then
  echo "$invoked runs in the workspace-write sandbox only; --sandbox $sandbox is refused" >&2; exit 2
fi
# The compatibility spelling selects a native lane profile, never the legacy sandbox.
case "$sandbox" in read-only|workspace-write) ;; *) echo "$invoked: only read-only or workspace-write lanes are supported; Full access is the owner's session choice" >&2; exit 2;; esac
# Review commands stay read-only; only the explicit writer command selects the write lane.
if [ "$sandbox" = read-only ]; then lane=review; lane_label="review lane"; else lane=writer; lane_label="WRITER lane"; fi
if [ "$lane" = writer ] && [ -n "$resume" ] && [ "${#add_dirs[@]}" -gt 0 ]; then
  echo "$invoked: codex exec resume has no --add-dir; start a fresh thread to widen what a writer can edit" >&2; exit 2
fi
[ -s "$prompt_file" ] || { echo "prompt file missing or empty: $prompt_file" >&2; exit 2; }
# The job is started from inside --cwd (see the resume note below), so the prompt path and the
# working directory are made absolute first; a --cwd that cannot be entered is a usage error.
case "$prompt_file" in /*) ;; *) prompt_file="$PWD/$prompt_file" ;; esac
cwd="$(cd -- "$cwd" 2>/dev/null && pwd)" || { echo "cannot enter --cwd: $cwd" >&2; exit 2; }
case "$job" in *[!A-Za-z0-9._-]*|"") echo "job name must match [A-Za-z0-9._-]+ (no slashes): $job" >&2; exit 2;; esac
# The raw value is checked as digits and one optional unit BEFORE any arithmetic: bash evaluates
# array subscripts inside $(( )), so an unchecked value such as `X[$(cmd)0]m` would run cmd. The
# digits are then read as decimal, so 08m is eight minutes rather than a bad octal number.
case "$timeout" in ''|*[!0-9hms]*|[hms]*|*[hms]?*|?????????*) echo "bad --timeout: $timeout (use e.g. 10m, 600s, 1h)" >&2; exit 2;; esac
to_secs() { case "$1" in *h) echo $(( 10#${1%h} * 3600 ));; *m) echo $(( 10#${1%m} * 60 ));; *s) echo $(( 10#${1%s} ));; *) echo $(( 10#$1 ));; esac; }
cap="$(to_secs "$timeout" 2>/dev/null)" || cap=""
case "$cap" in ''|*[!0-9]*) echo "bad --timeout: $timeout (use e.g. 10m, 600s, 1h)" >&2; exit 2;; esac
FLOOR=300
if [ "$cap" -lt "$FLOOR" ] && [ "$short_ok" -eq 0 ]; then
  echo "--timeout $timeout is below the ${FLOOR}s floor (a repository review measured 179 s plus startup; a short cap is how the original false stall happened). Pass --short-timeout-ok to accept it — it is recorded in result.json." >&2; exit 2
fi
# Resolve the script link, so PATH names and package copies use the same tested settings.
script="$(python3 -I -B -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$0")" || exit 2
lane_config="${script%/*}/../codex/lane_config.py"
role="$(python3 -I -B "$lane_config" --resolve-role "$role" "$lane" "$model" "$effort")" || exit 2
# Repository configuration, see the header. A trust record that cannot be read never fails the launch.
project_flag=""; [ "$project_on" -eq 0 ] || project_flag=on; [ "$project_off" -eq 0 ] || project_flag=off
project_state="$(python3 -I -B "$lane_config" --project-state "$cwd" "$project_flag" 2>/dev/null)" || project_state=""
[ -n "$project_state" ] || project_state="off unreadable-trust"
project_config="${project_state%% *}"; project_reason="${project_state#* }"
excluded=""; if [ "$project_config" = off ] && [ "$project_reason" != untrusted ]; then excluded=1; fi
settings="$(python3 -I -B "$lane_config" "$role" "$lane" "$model" "$effort" "$cwd" "$excluded")" || exit 2
override=""; if [ -n "$excluded" ]; then override=untrusted; elif [ "$project_flag" = on ]; then override=trusted; fi
if [ -n "$override" ]; then
  settings="$settings
$(python3 -I -B "$lane_config" --project-override "$cwd" "$override")" || exit 2
fi
# Validate and capture the strict schema before reserving, but publish its
# canonical artifact only after ownership is established.
strict_schema=""; strict_schema_text=""
if [ -n "$schema" ]; then
  strict_schema_text="$(python3 -I -B - "$schema" <<'EOF'
import json,sys
s=json.load(open(sys.argv[1]))
def strict(o):
    if isinstance(o,dict):
        if o.get('type')=='object':
            o['additionalProperties']=False
            o['required']=list(o.get('properties',{}).keys())
        for v in o.values(): strict(v)
    elif isinstance(o,list):
        for v in o: strict(v)
strict(s); print(json.dumps(s))
EOF
)" || { echo "cannot read --schema: $schema" >&2; exit 2; }
fi
out="$(mkdir -p "$out" && cd "$out" && pwd)" || { echo "cannot create out-dir: $out" >&2; exit 2; }
python3 -I -B "${script%/*}/reserve_job.py" "$out" "$job" || exit 2
# The reservation permanently owns these fresh receipt paths across all providers, so pre-launch
# failures keep their attempt and these two receipts, as in claude_job.sh.
echo "$lane" > "$out/$job.lane"
printf '%s\n%s\n' "$project_config" "$project_reason" > "$out/$job.project-config"
if ! command -v codex >/dev/null 2>&1; then echo "codex not on PATH" >&2; echo 125 > "$out/$job.exit"; exit 125; fi
# Read-only, and only a clearly logged-out answer stops the launch: `codex login status` says
# "Not logged in" and exits 1, and it also exits 1 when it could not tell.
if codex login status </dev/null >/dev/null 2>&1; then :; else
  auth_said="$(codex login status </dev/null 2>&1 || true)"
  if grep -qiE 'not logged in|logged out' <<<"$auth_said"; then
    echo "existing Codex authentication is unavailable; report the blocked lane to the owner" >&2; echo 3 > "$out/$job.exit"; exit 3
  fi
fi
if [ -n "$schema" ]; then
  strict_schema="$out/$job.schema.strict.json"
  printf '%s\n' "$strict_schema_text" > "$strict_schema"
fi

# `codex exec resume` accepts neither -C nor -s. A resumed reviewer used to start in the CALLER's
# directory, whatever --cwd said, while the launch line still printed cwd=<--cwd> (historical probe,
# 2026-10-11): a re-review "on the same thread" read the wrong tree whenever --cwd was an export
# or another checkout. Both branches are therefore started from inside "$cwd" (the cd below), and
# a resume selects the same native profile instead of relying on what the thread remembers.
args=()
if [ -n "$resume" ]; then
  args=(exec resume "$resume")
else
  args=(exec -C "$cwd")
fi
while IFS= read -r setting; do args+=(-c "$setting"); done <<< "$settings"
# The review profile already reads the whole disk, and a writer's --resume refused --add-dir above.
add_dir_note=""
if [ "${#add_dirs[@]}" -gt 0 ]; then
  if [ "$lane" = writer ]; then
    add_dir_note=" add-dir=${add_dirs[*]}"
    for d in "${add_dirs[@]}"; do
      if [ -n "$d" ]; then args+=(--add-dir "$d"); fi
    done
  else
    add_dir_note=" add-dir=no-effect (this profile already reads the whole disk)"
  fi
fi
[ -n "$strict_schema" ] && args+=(--output-schema "$strict_schema")
args+=(-o "$out/$job.json" --json -)

# A finished run's terminal receipts, as in claude_job.sh. The normalizer owns the class-to-exit
# mapping, and terminal receipts and --wait consume that value. If it fails, or its value cannot be
# read back, a provider's exit 0 must not stand: the job ends as a failed run, a watchdog timeout
# stays one, and result.json says why. Every python3 here runs with -I -B: the monitor sits in
# --cwd and --wait in the caller's directory, and neither may import a json.py from there.
finish_result() {
  local raw_exit normalized_exit class=reviewer_error final_exit=1
  raw_exit="$(cat "$out/$job.exit")"
  if python3 -I -B -c "$NORMALIZE_PY" "$out/$job.events.jsonl" "$out/$job.json" "$out/$job.result.json" "$raw_exit" "$short_ok" "$cap" "$strict_schema" "$out/$job.stderr" >/dev/null 2>&1 \
    && normalized_exit="$(python3 -I -B -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["exit"]))' "$out/$job.result.json" 2>/dev/null)" \
    && [ -n "$normalized_exit" ]; then
    printf '%s\n' "$normalized_exit" > "$out/$job.exit"
    return
  fi
  if [ "$raw_exit" = 124 ]; then class=timeout; final_exit=124; fi
  printf '{"exit_class":"%s","exit":%s,"provider_exit":%s,"status":null,"source":"none","schema_valid":false,"refusal_text":null,"limit_text":null,"normalization_error":"the normalizer failed; read the events and stderr receipts","result":{}}\n' \
    "$class" "$final_exit" "${raw_exit:-null}" > "$out/$job.result.json"
  printf '%s\n' "$final_exit" > "$out/$job.exit"
  echo "normalizer failed: recorded as $class, not a verdict" >> "$out/$job.stderr"
}
# .end is the done marker: written whole, then renamed, so no reader sees it half-written. Bash runs
# a subshell's last simple command in the subshell's own place, so the rename must stay inside this
# function: the monitor then remains the process in .pid and .monitor until .end exists. A date
# that fails still publishes .end, empty, because a withheld .end would read as lost; --wait then
# reports the elapsed time as unknown.
mark_end() { { date +%s || true; } > "$out/$job.end.tmp"; mv -f "$out/$job.end.tmp" "$out/$job.end"; }

echo "$role" > "$out/$job.role"
echo "lane-orchestration-${lane/writer/write}" > "$out/$job.permissions"
date +%s > "$out/$job.start"
# The subshell must outlive a failing codex and a terminal hangup: drop errexit inside it and ignore
# HUP, so .exit/.end are always written.
( trap '' HUP
  # Cancellation, see the header. TERM only raises this flag, because it can arrive before the
  # provider exists; the poll below sends it on, and again at every pass, as in claude_job.sh.
  cancelled=0
  trap 'cancelled=1' TERM
  set +e
  # A cd that fails here (the directory vanished since the check above) still writes the markers,
  # so --wait and every poller see a finished, failed job instead of waiting for ever.
  if ! cd -- "$cwd" 2>/dev/null; then
    echo "cannot enter --cwd: $cwd" > "$out/$job.stderr"
    echo 1 > "$out/$job.exit"
    finish_result
    mark_end
    exit 1
  fi
  SECONDS=0
  CODEX_ORCHESTRATION_WORKER=1 nohup codex "${args[@]}" < "$prompt_file" > "$out/$job.events.jsonl" 2> "$out/$job.stderr" & cp=$!
  # Exec keeps the pid and start time but not the command (nohup first, codex later), so the
  # identity is taken once the child IS codex; comm may be a bare name or a path. At most 5 s;
  # a ps that fails or prints nothing (child gone, or ps refused) ends the wait at once.
  id=""; why=""; n=0
  while [ "$n" -lt 50 ]; do
    [ "$cancelled" -eq 0 ] || { why="cancelled before pid $cp was identified"; break; }
    line="$(/usr/bin/env LC_ALL=C TZ=UTC0 ps -p "$cp" -o lstart=,comm= 2>/dev/null)" && [ -n "$line" ] \
      || { why="ps gave no identity for pid $cp (child gone, or ps refused)"; break; }
    name="${line%"${line##*[![:space:]]}"}"
    case "$name" in */*) name="${name##*/}";; *) name="${name##*[[:space:]]}";; esac
    [ "$name" = codex ] && { id="$line"; break; }
    why="pid $cp was still $name after 5 s, not codex"; n=$((n+1)); sleep 0.1
  done
  # Written whole, then renamed: pid=, then the ps line, or an unrecorded: reason no check matches.
  printf 'pid=%s\n%s\n' "$cp" "${id:-unrecorded: $why}" > "$out/$job.codex.pid.tmp" \
    && mv -f "$out/$job.codex.pid.tmp" "$out/$job.codex.pid"
  while kill -0 $cp 2>/dev/null && [ "$SECONDS" -lt "$cap" ]; do
    [ "$cancelled" -eq 0 ] || kill -TERM $cp 2>/dev/null
    sleep 0.5
  done
  trap '' TERM   # the provider is over or the watchdog has it: the receipts below are not interrupted
  if kill -0 $cp 2>/dev/null; then
    kill -TERM $cp 2>/dev/null; g=0; while kill -0 $cp 2>/dev/null && [ $g -lt 5 ]; do sleep 1; g=$((g+1)); done   # grace: let the stream flush
    kill -0 $cp 2>/dev/null && kill -9 $cp 2>/dev/null
    echo 124 > "$out/$job.exit"; echo "watchdog: timed out after ${cap}s (not a verdict)" >> "$out/$job.stderr"
  else rc=0; wait $cp || rc=$?; echo "$rc" > "$out/$job.exit"; fi
  [ "$cancelled" -eq 0 ] || echo "cancelled: the monitor received TERM" >> "$out/$job.stderr"
  grep -m1 -o '"thread_id":"[^"]*"' "$out/$job.events.jsonl" 2>/dev/null | cut -d'"' -f4 > "$out/$job.thread" || true
  finish_result
  mark_end ) >/dev/null 2>&1 &
echo $! > "$out/$job.pid"
# The monitor's identity (see Identity in the header), written whole, then renamed, or an
# unrecorded: reason. Never fatal under set -e: the monitor is already detached, and a launcher that
# stopped here would print no launch line and run no --wait, so a caller could read a failed
# launch and start a second writer. A .monitor that cannot be written stays missing.
wid="$(/usr/bin/env LC_ALL=C TZ=UTC0 ps -p "$(cat "$out/$job.pid")" -o lstart=,comm= 2>/dev/null)" && [ -n "$wid" ] || wid="unrecorded: ps gave no identity"
{ printf '%s\n' "$wid" > "$out/$job.monitor.tmp" && mv -f "$out/$job.monitor.tmp" "$out/$job.monitor"; } 2>/dev/null || true
echo "launched codex job '$job' — $lane_label (permissions=lane-orchestration-${lane/writer/write} role=$role project-config=$project_config reason=$project_reason$add_dir_note cwd=$cwd timeout=$timeout pid=$(cat "$out/$job.pid"))"
echo "  result: $out/$job.result.json   final message: $out/$job.json   events: $out/$job.events.jsonl   done-marker: $out/$job.end   lane: $out/$job.lane"
echo "  codex child identity: $out/$job.codex.pid (written once the child is codex, within about 5 s)"
echo "  to abort: only while $out/$job.end is absent and live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= equals $out/$job.monitor, TERM the monitor in $out/$job.pid, which stops codex and writes every receipt; or re-read .codex.pid (an unrecorded:, missing or short file means do not signal); TERM its pid only if the live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= equals its line 2 (same start, command codex), then re-check liveness"

# identity_state <pid> <recorded identity line>: 0 while that pid is still the recorded
# process (or exists, where nothing was recorded), 1 only on proof it is not: another live
# identity, or no such process. 2 means cannot tell (no usable pid, ps and kill refused). The
# signal-0 probe sends nothing.
identity_state() {
  local pid="$1" id="$2" live msg
  case "$pid" in ''|0|*[!0-9]*) return 2;; esac
  case "$id" in ''|unrecorded:*) ;; *)
    live="$(/usr/bin/env LC_ALL=C TZ=UTC0 ps -p "$pid" -o lstart=,comm= 2>/dev/null)" || live=""
    [ -z "$live" ] || { [ "$live" = "$id" ]; return; };;
  esac
  msg="$(kill -0 "$pid" 2>&1)" && return 0
  case "$msg" in *"No such process"*) return 1;; *) return 2;; esac
}
# elapsed_since_start <epoch>: "<n>s", or "unknown" when either timestamp is not a number.
elapsed_since_start() {
  local start; start="$(cat "$out/$job.start" 2>/dev/null)" || start=""
  case "$1" in ''|*[!0-9]*) echo unknown; return;; esac
  case "$start" in ''|*[!0-9]*) echo unknown; return;; esac
  echo "$(( $1 - start ))s"
}

if [ "$wait_flag" -eq 1 ]; then
  while [ ! -f "$out/$job.end" ]; do
    # Lost, see the header. .end is checked again after the probe: a monitor that finished
    # normally renamed .end into place before it exited.
    wrc=0; identity_state "$(sed -n 1p "$out/$job.pid" 2>/dev/null)" "$(sed -n 1p "$out/$job.monitor" 2>/dev/null)" || wrc=$?
    if [ "$wrc" -eq 1 ] && [ ! -f "$out/$job.end" ]; then
      thread="$(grep -m1 -o '"thread_id":"[^"]*"' "$out/$job.events.jsonl" 2>/dev/null | cut -d'"' -f4)" || thread=""
      [ -n "$thread" ] || thread="${resume:-unknown}"
      echo "finished: class=lost thread=$thread elapsed=$(elapsed_since_start "$(date +%s)")"
      crc=0; identity_state "$(sed -n '1s/^pid=//p' "$out/$job.codex.pid" 2>/dev/null)" "$(sed -n 2p "$out/$job.codex.pid" 2>/dev/null)" || crc=$?
      case "$crc" in 0) child="still running; abort it only by the .codex.pid route in this script's header";; 1) child="gone";; *) child="cannot tell from $out/$job.codex.pid, so do not signal it";; esac
      if [ "$lane" = writer ]; then nv="the edits may be partial"; else nv="the fresh-reviewer fallback applies (standing order 5)"; fi
      echo "lost: the monitor in $out/$job.pid is gone or is now another process and $out/$job.end is absent, so completion is unconfirmed: an .exit or result.json present is not proof of a finished run, and $nv. Nothing was signalled. codex child: $child." >&2
      [ "$lane" != writer ] || echo "note: WRITER lane — the class describes the run, not the tree. Before accepting or relaunching, check under $cwd: HEAD, index, branches and stashes unchanged, only files in scope touched, no process left running. Nothing was rolled back." >&2
      exit 1
    fi
    sleep 1
  done
  rc="$(cat "$out/$job.exit")"
  el="$(elapsed_since_start "$(cat "$out/$job.end" 2>/dev/null)")"
  thread="$(cat "$out/$job.thread" 2>/dev/null || true)"
  [ -n "$thread" ] || thread="${resume:-unknown}"
  cls="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1])).get("exit_class","?"))' "$out/$job.result.json" 2>/dev/null || echo '?')"
  echo "finished: exit=$rc class=$cls thread=$thread elapsed=$el ($out/$job.result.json)"
  if [ "$cls" = thread_busy ]; then
    echo "thread $thread has an active writer — wait for the earlier job's .end, or abort it only while that .end is absent and the live LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm= equals line 2 of its .codex.pid (never an unrecorded: line), then re-check liveness; a new thread is $fresh_cmd without --resume" >&2
  fi
  if [ "$rc" = "5" ]; then
    if [ "$lane" = writer ]; then
      echo "note: classed as a REFUSAL (heuristic — see claude_job.sh's header). The writer declined; the work is NOT done. Its words:" >&2
    else
      echo "note: classed as a REFUSAL (heuristic — see claude_job.sh's header). The reviewer declined and produced no verdict; the round is NOT covered. Its words:" >&2
    fi
    python3 -I -B -c 'import json,sys; print((json.load(open(sys.argv[1])).get("refusal_text") or "")[:400])' "$out/$job.result.json" >&2 2>/dev/null || true
  fi
  if [ "$rc" = "7" ]; then
    if [ "$lane" = writer ]; then
      echo "note: the run ended with no completed turn, no final message or a final message that does not satisfy the --schema: the report is missing, the edits may not be. Read $out/$job.events.jsonl." >&2
    else
      echo "note: the run ended with no completed turn, no final message or NO VERDICT matching the schema; the round is NOT covered. Read $out/$job.events.jsonl before relaunching." >&2
    fi
  fi
  if [ "$lane" = writer ]; then
    echo "note: WRITER lane — the class describes the run, not the tree. Before accepting or relaunching, check under $cwd: HEAD, index, branches and stashes unchanged, only files in scope touched, no process left running. Nothing was rolled back." >&2
  fi
  [ "$rc" = "0" ] || { tail -5 "$out/$job.stderr" >&2 || true; exit "$rc"; }
fi
