#!/usr/bin/env bash
# claude_job.sh — launch a headless Claude Code REVIEWER (`claude -p`, plan permission mode)
# from any coordinating platform (Codex or Claude itself), detached, observable,
# with a strict structured verdict and DISTINGUISHABLE exit classes. First verified 2026-08-22 on
# Claude Code 2.1.220 (macOS); live-checked again 2026-11-08 on 2.1.319: a review lane in an unseen
# repository classified success with a valid schema verdict, project-config off, rules read by tools.
# One script, two names on PATH (install.sh --bin links both), told apart by the name it is run by:
#   claude-review   the reviewer, plan permission mode — and so is every other name, this file's
#                   own included; built-in tools are restricted to Read, Grep and Glob
#   claude-write    a WRITER in acceptEdits permission mode — read "Writer lane" below first
#
# Why this exists: the documented one-liner (`claude -p … --output-format json`) is buffered —
# it prints nothing until completion — so a non-Claude coordinator read silence as a stall,
# killed a healthy 3-minute review and silently fell back to same-family. This launcher streams
# events (heartbeats), caps the run with a generous watchdog, and makes "timed out" a different
# exit from "refused", "not authenticated" or "reviewer error", so the round record can say which.
#
# Usage:
#   claude_job.sh <out-dir> <job-name> <prompt-file> [--cwd DIR] [--add-dir DIR]...
#       [--model sonnet|opus|haiku|<id>] [--effort <level>] [--schema FILE]
#       [--tools "Read,Grep,Glob"] [--max-turns N] [--timeout 10m] [--short-timeout-ok]
#       [--project-config | --no-project-config] [--wait]
#   claude-write <out-dir> <job-name> <prompt-file> [--cwd DIR] [--add-dir DIR]... [--model <model>]
#       [--effort <effort>] [--schema FILE] [--tools "Read,Grep,Glob,Edit,Write"]
#       [--bash-allow '<pattern>']... [--max-turns 150] [--timeout 60m] [--short-timeout-ok]
#       [--project-config | --no-project-config] [--wait]
#   The three positionals come first. One that begins with "-" is refused (exit 2, nothing
#   written): it is an option in the wrong place. A path that really begins with "-" is ./-name.
#   An empty --cwd is refused the same way, before any attempt is reserved: /bin/bash 3.2 reads
#   `cd ""` as staying put, so it would run in the caller's directory.
#   --effort is handed to `claude --effort` as given and never validated here (the CLI's help on
#   2.1.296 lists low, medium, high, xhigh and max).
#   --timeout has a 300 s FLOOR (a repository review measured 179 s plus startup; a shorter cap is
#   how the original false stall happened). Below the floor the launcher exits 2 unless
#   --short-timeout-ok is given, which is recorded in result.json so the round record shows it.
#
# Writes <out>/<job>.stream.jsonl (live event stream — watch it for heartbeats),
#        <out>/<job>.json        (the final `result` event: is_error, structured_output, cost…),
#        <out>/<job>.result.json (normalized: {exit_class, status, source, schema_valid,
#                                  result, refusal_text, limit_text}),
#        <out>/<job>.exit / .start / .end / .pid / .monitor / .stderr,
#        <out>/<job>.lane        (`review` or `writer`, including pre-launch failures),
#        <out>/<job>.project-config (line 1 `on` or `off`, line 2 the reason, likewise; see
#                                 "Repository configuration").
# Each OUT/JOB permanently identifies one attempt. Retry with a fresh job name or
# output directory; completed and failed receipt sets are never overwritten.
# With --schema, also preserves <out>/<job>.schema.<unique> as the job-owned snapshot used both
# for Claude's --json-schema argument and final normalization; later source edits have no effect.
# Exit classes (also in .exit and result.json): 0 success · 1 reviewer_error (claude exited
# non-zero or result.is_error) · 2 usage · 3 not_authenticated · 4 partial (the run hit
# --max-turns or another truncation: a PARTIAL review, never clean) · 5 refusal (the reviewer
# declined the task) · 6 limit (observed paid-plan weekly limit) · 7 no_verdict (the run finished
# normally but nothing it returned satisfies the --schema you passed) · 124 timeout (watchdog) ·
# 125 claude_missing.
# A normalizer that fails, or whose exit cannot be read back, never leaves a raw exit 0: the job
# ends reviewer_error (a watchdog timeout stays timeout) and result.json has `normalization_error`.
# `limit` is evidence-based and deliberately narrow: on 2026-08-25 Claude Code 2.1.239, a paid
# Max account at its weekly cap returned a normal `result` event with `is_error:true`, subtype
# `success`, and exactly "You've hit your weekly limit · resets …". Other wording stays
# reviewer_error until observed; this launcher does not guess from generic error prose.
# `not_authenticated` (3): `claude auth status` said logged out before the launch, or the finished
# run's error result is exactly "Not logged in · Please run /login" (measured 2026-10-11 on
# 2.1.296; it used to be `reviewer_error`; the same words in a successful run change nothing).
# Historical 2.1.296 probes included logged-out and parent-access failures with this result;
# the class alone does not diagnose which prerequisite is missing. A failed lane grants no
# authentication or permission changes. Use the already-authorized parent configuration;
# otherwise report this lane unavailable and use the required permitted fallback.
# A writer keeps these classes and exit codes, review-flavoured names included: `reviewer_error`
# reads "the run failed", `no_verdict` reads "a --schema was passed and the final report does not
# satisfy it". None of them describes the tree. `success` says the run ended normally, never that
# the edit is right or in scope; `partial`, `timeout` and every other class can leave half-made
# edits behind.
#
# Repository configuration. One rule on both launchers, for both lanes: a repository the owner has
# already trusted behaves natively, and an unseen repository does not run its project configuration.
# Why: `claude -p` started in a repository runs the hooks of its .claude/settings.json and connects
# its .mcp.json servers without prompting, even in the review lane (observed on 2.1.316 under
# claude-review), so repository code would run as the user. Codex otherwise records trust
# persistently on a writer run; see codex_job.sh. The launcher reads
# projects[<path>].hasTrustDialogAccepted from ~/.claude.json, or $CLAUDE_CONFIG_DIR/.claude.json,
# and never writes that file. True for --cwd, its physical path or the nearest folder holding a .git entry
# means native: no added flags. A linked worktree does not inherit its main checkout's trust.
# Anything else, including a missing, unreadable or malformed file, adds `--setting-sources user`, the flag the vendor names for
# this, and `--append-system-prompt` with a short notice. Observed with that flag: neither ran,
# subscription login kept working and user-level settings still applied. The trade-off: the
# repository's CLAUDE.md is then not auto-loaded, which is what the notice tells the lane, with how
# to read its rules. `--bare` is not used because it never reads a subscription login,
# `--strict-mcp-config` because it would also drop the user's own servers.
# --no-project-config forces exclusion anywhere, a trusted repository included. --project-config
# forces native loading on an unseen repository: the owner's explicit statement of trust. Giving
# both is a usage error (exit 2). <job>.project-config holds on or off, then the reason: trusted,
# unseen, unreadable-trust or flag. The launch line shows the same.
#
# Identity. <job>.monitor holds the monitor's identity, and every check of it is the line printed
# by exactly `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=`. Plain ps prints lstart in the
# caller's time zone and language, so after an automatic time-zone change, or from a shell with
# another language, the same process would no longer match. Recording it never stops the
# launcher: a .monitor that cannot be written is missing.
# The launcher sets that environment through env, not a shell prefix: bash 5.3.20 crashed
# (SIGSEGV, exit 139) running `LC_ALL=C TZ=UTC0 <script>` in a command substitution inside a
# background subshell when the script was newly written, so a ps that had answered read as none.
# Cancellation. Only while <job>.end is absent and the live
# `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` equals <job>.monitor, so a recycled pid is never
# hit (an `unrecorded:` line or an empty or missing file means do not signal), send TERM to the
# monitor in <job>.pid; signal nothing else and never KILL it, which leaves claude running with
# no receipts. At each 2 s poll
# the monitor sends claude TERM until it is gone, then writes the normal receipts, so .exit, .end
# and .result.json appear and --wait ends, normally as reviewer_error, exit 1, provider_exit 143,
# with a `cancelled` line in .stderr. A claude that ignores TERM runs on until the watchdog. HUP
# changes nothing.
# Lost. The monitor writes .exit and result.json, then .end; if it dies before .end, .end never
# comes. While <job>.end is absent the job is lost only on proof: <job>.monitor holds a recorded
# identity and the live `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` prints another non-empty
# line, or ps prints nothing (or .monitor is `unrecorded:`, empty or missing) and `kill -0 <pid>`
# says No such process; then .end must still be absent. Anything else, such as a refused ps or kill
# or a pid that is not a number, means cannot tell: keep waiting. Lost means completion is
# unconfirmed: an .exit or result.json present is not proof, and the fresh-reviewer fallback
# applies. Signal nothing for it; claude may still run, and no identity of it is recorded. --wait
# does this check.
#
# Reviewer lane: --tools defaults to Read,Grep,Glob and accepts only those exact names,
# separated by ASCII spaces or a single comma with optional spaces. Repeated names are
# deduplicated in Read,Grep,Glob order; leading/trailing separators and repeated --tools
# options are refused before authentication or receipt reservation. Both --tools (built-in
# availability) and --allowedTools (preapproval) carry that same subset. Shell/Git/test
# evidence must be materialized by the coordinator. Native settings, startup hooks and MCP
# still apply, a trusted repository's included (see "Repository configuration"); this is not
# hostile-code isolation. Authorized edits use claude-write.
#
# Writer lane (`claude-write`). The flags were read from `claude --help` on 2.1.296; "observed"
# below is one live probe on Claude Code 2.1.296 (2026-10-11, a scratch repository, one
# --bash-allow 'sh test.sh'). The lane may read, search and edit files under --cwd and every
# --add-dir (which therefore widens editing as well as reading). The launcher passes
# `--permission-mode acceptEdits` and never a permission-bypass flag. Two flags carry the rest:
#   --tools         --help: "Specify the list of available tools from the built-in set". The real
#                   whitelist; the writer's list goes here, Read,Grep,Glob,Edit,Write by default.
#                   A writer's --tools is plain tool names, checked before anything is launched:
#                   `Bash` and the preset `default` (also `preset:default`) in any letter case,
#                   and any character outside [A-Za-z0-9_, ], are refused (exit 2).
#   --allowedTools  --help: "tool names to allow (e.g. "Bash(git *) Edit")". Permission rules, not
#                   availability. The reviewer sends its validated subset to both flags.
# Bash is absent unless the caller passes --bash-allow '<pattern>' (repeatable). Each one adds Bash
# to the whitelist and one rule `Bash(<pattern>)` to --allowedTools. A pattern that is empty or
# contains ( or ) is refused (exit 2): the CLI splits each rule again and tracks one level of
# parentheses only, so such a pattern would lose its rule or become several. Cover a parenthesised
# part of a command with `*`.
# The patterns are NOT all that Bash may then do. On Claude Code 2.1.296 (the lists are the CLI's
# and can change), with Bash on the whitelist `--permission-mode acceptEdits` itself approves
# mkdir, touch, rm, rmdir, mv, cp and sed on paths inside the working directories, and the CLI's
# read-only commands run with no rule at all. Any other command outside the patterns is denied in
# a headless run, unless a loaded allow rule permits it (below). The permission system narrows
# the lane, it does not bound it: the boundary is the coordinator's check afterwards.
# Observed: the Edit happened and `sh test.sh` ran; `rm` and `mv` on files in the repository ran
# though no pattern named them; `git status --short` ran; `python3 -c …` was denied ("This command
# requires approval", in permission_denials); `touch` on a path outside the repository was denied
# ("outside the working directories"); HEAD, index and stashes were unchanged; <job>.lane said
# writer. Not observed: acceptEdits on paths under `.git`; --tools removing a tool other than
# Bash; MCP tools.
# The writer's child gets CLAUDE_ORCHESTRATION_WORKER=1, as codex_job.sh sets its own worker
# variable, which a hook package reads to block worker Git mutation. A reviewer's never has it.
# Edits are approved by acceptEdits, never by an allow rule. Two things lie outside the launcher.
# The settings the child loads (user, project, local, managed; see "Repository configuration") apply
# as in any session: their allow rules widen this, their deny rules and hooks narrow it. And MCP
# servers configured on this Mac are not built-in tools, so --tools is not expected to remove them.
# A lane that can run code is NOT isolated. The boundary is the brief plus the coordinator's check
# once the job ends, whatever its class: HEAD, index, branches and stashes unchanged, only files in
# scope touched, no process left running (the watchdog stops `claude`, not what a command it ran
# left behind). The lane never changes Git state: the brief's rule and the check's proof, no flag
# here enforces it (read-only git commands do run). Nothing a writer edited is rolled back.
# Launched from a Codex coordinator, the child inherits the PARENT's sandbox: it needs a writable
# repository, network, a writable ~/.claude/session-env and the existing login from the parent,
# and no child flag widens that. Historical 2026-10-11 probes succeeded only when those
# prerequisites were present. Where the existing authorized parent configuration cannot provide
# them, this lane is unavailable: report it and use the required permitted fallback. A broader
# parent configuration is a separate owner-authorized decision, never a remedy granted by a
# failed lane. No role changes authentication or works around the parent restriction.
#
# `no_verdict` is a structural fact, not a guess: a --schema was passed, the run would otherwise be
# `success`, it was not a refusal, and neither structured_output nor any JSON object in the final
# text satisfies the schema. It used to be recorded as `success` (historical probe, 2026-10-11): seen
# when a headless review fanned out its own background agents and the CLI stopped them ten minutes
# after the main thread's last turn, before the report was written. Without --schema the launcher
# has nothing to check a verdict against, so such a run stays `success`; read `result` yourself.
# The same holds when the normalizer cannot use its schema (unreadable, or with no properties):
# the class stays as it was and result.json says why in `schema_error`. Live launches fail before
# dispatch if the caller schema cannot be captured in a readable job-owned snapshot.
#
# The `refusal` heuristic — stated plainly because it is a heuristic, not a signal the CLI gives.
# Claude Code reports a decline as an ordinary successful run whose final text happens to say no,
# so a refusal is inferred, and only from a conjunction that a real review cannot satisfy:
#   1. the run finished normally (exit class would otherwise be success or reviewer_error;
#      timeout / partial / not_authenticated / claude_missing / limit keep their own class), AND
#   2. NO verdict was produced — `schema_valid` is false, i.e. neither structured_output nor any
#      JSON object in the final text satisfies the --schema you passed (a review that answered
#      the brief can never be a refusal). Without --schema this weakens to "no JSON object at
#      all", because there is then nothing to check an object against, AND
#   3. the final text is short (<= 1500 chars — a genuine review that merely failed to emit JSON
#      is far longer), AND
#   4. its first 400 chars match an explicit first-person decline ("I can't help with…",
#      "I won't…", "I must decline", "I'm unable to assist…").
# Both directions of error stay visible, and neither is ever silently a verdict. A false positive
# puts the offending text in result.json's `refusal_text` for the coordinator to read. A MISSED
# refusal — a decline phrased outside the pattern, e.g. "I am not comfortable reviewing this" —
# is `no_verdict` when a --schema was passed and, without one, keeps whatever class the exit code
# gave it, usually `success`; that is why `source`, `schema_valid` and `result` matter. The
# reviewer's own words are in <job>.json. Read them before recording the round.
set -uo pipefail
unset CDPATH   # internal path canonicalization must never capture cd chatter

# ---------------------------------------------------------------- normalizer (single source)
# Held in a variable rather than a heredoc so the `normalize` subcommand below can run exactly
# the same code over a recorded stream — that is how tests/test_launchers.sh exercises the exit
# classes (refusal included) without spending a real Claude run.
# Single quotes are required: this is Python source and nothing in it may be shell-expanded.
# shellcheck disable=SC2016
NORMALIZE_PY='
import json,re,sys
stream,final,norm,rc,short_ok,cap=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5],sys.argv[6]
schema_file=sys.argv[7] if len(sys.argv)>7 else ""
sch=None; schema_error=None
if schema_file:
    try: sch=json.load(open(schema_file))
    except Exception: sch=None; schema_error="the --schema file could not be read when the result was normalized"
if not isinstance(sch,dict) or not sch.get("properties"):
    if schema_file and schema_error is None: schema_error="the --schema file declares no properties to check a verdict against"
    sch=None

def schema_ok(obj):
    """Structural check, NOT full JSON-Schema validation: every required key present (every
    declared property when `required` is absent; none when it is an empty list) and every
    enum-constrained value in its enum.
    Enough to tell a finished verdict from a stray JSON object in a decline. With no --schema
    there is nothing to check against, so any non-empty object counts — the header says so."""
    if not isinstance(obj,dict): return False
    if sch is None: return bool(obj)
    props=sch.get("properties") or {}
    req=sch["required"] if isinstance(sch.get("required"),list) else list(props.keys())
    if any(k not in obj for k in req): return False
    for k,p in props.items():
        if k in obj and isinstance(p,dict) and p.get("enum") and obj[k] not in p["enum"]: return False
    return True

last=None
try: fh=open(stream,encoding="utf-8",errors="ignore")
except Exception: fh=[]
for line in fh:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")=="result": last=d
json.dump(last or {}, open(final,"w"), indent=1)
res=None; source="none"
if last:
    so=last.get("structured_output")
    if isinstance(so,dict) and schema_ok(so): res=so; source="structured_output"
    else:
        # Prefer the first object that VALIDATES; fall back to the first object of any shape, so
        # a stray `{"reason":"policy"}` inside a decline cannot masquerade as a verdict.
        txt=last.get("result") or ""; first=None; dec=json.JSONDecoder(); i=txt.find("{")
        while i!=-1 and res is None:
            try:
                obj,_=dec.raw_decode(txt[i:])
                if isinstance(obj,dict):
                    if first is None: first=obj
                    if schema_ok(obj): res=obj; source="result_text"
            except Exception: pass
            i=txt.find("{",i+1)
        if res is None and first is not None: res=first; source="result_text"
        if res is None and isinstance(so,dict): res=so; source="structured_output"   # present but not a verdict
schema_valid=schema_ok(res) if isinstance(res,dict) else False
cls={"0":"success","1":"reviewer_error","2":"usage","3":"not_authenticated","4":"partial","5":"refusal","124":"timeout","125":"claude_missing"}.get(rc,"reviewer_error")
sub=str((last or {}).get("subtype") or ""); stop=str((last or {}).get("stop_reason") or "")
if last and (sub.startswith("error_max_turns") or "max_turns" in sub or "max_turns" in stop): cls="partial"   # claude may exit 0 or 1 here; the subtype decides
elif rc=="0" and last and last.get("is_error"): cls="reviewer_error"

# Provider limit detection. Match only the exact signal observed from a paid Claude Max account;
# keep the complete short message so --wait can report the provider reset detail.
limit_text=None
if cls=="reviewer_error" and last and last.get("is_error"):
    txt=(last.get("result") or "").strip()
    if re.fullmatch(r"You\x27ve hit your weekly limit(?:\s*·\s*resets .+)?",txt,re.I):
        cls="limit"; limit_text=txt[:500]

# Not-logged-in detection, as narrow as the limit: an ERROR result whose whole text is the message
# of the CLI itself (measured 2026-10-11 on 2.1.296: is_error true, subtype success, 58 ms). The
# CLI says it when it is logged out, and also when a sandbox keeps it from its session folder or
# from the network. The same words in a successful run are prose and are never matched here.
na_txt=(last.get("result") or "").strip() if (cls=="reviewer_error" and last and last.get("is_error")) else ""
if re.fullmatch(r"Not logged in(?:\s*·\s*Please run /login)?",na_txt,re.I):
    cls="not_authenticated"

# Refusal detection. Claude Code has no refusal signal: a decline is an ordinary run whose final
# text says no. Infer it only from the conjunction documented in the header — finished normally,
# no SCHEMA-VALID verdict, short text, and an explicit first-person decline up front.
# Contractions are expanded first so one plain pattern covers "can\x27t"/"cannot", "won\x27t"/"will not".
def _expand(t):
    t=t.replace("\u2019","\x27")   # curly apostrophe -> plain, so one pattern covers both
    t=re.sub(r"\bI\x27m\b","I am",t,flags=re.I)
    t=re.sub(r"\bcan\x27?t\b","cannot",t,flags=re.I)
    t=re.sub(r"\bwon\x27?t\b","will not",t,flags=re.I)
    return t
REFUSAL=re.compile(r"\bI (?:cannot|will not|am not able to|am unable to) "
                   r"(?:help|assist|comply|do|provide|continue|complete|perform|produce|write|review|engage|proceed)"
                   r"|\bI (?:must|have to|will) decline\b|\bI decline\b|\bI am not going to\b", re.I)
refusal_text=None
if cls in ("success","reviewer_error") and not schema_valid and last:
    txt=(last.get("result") or "").strip()
    if txt and len(txt)<=1500 and REFUSAL.search(_expand(txt[:400])):
        cls="refusal"; refusal_text=txt[:1000]

# A run that finished normally, was asked for a verdict of a known shape, and returned none.
if cls=="success" and sch is not None and not schema_valid:
    cls="no_verdict"

normalized_exit={"success":0,"reviewer_error":1,"usage":2,"not_authenticated":3,"partial":4,"refusal":5,"limit":6,"no_verdict":7,"timeout":124,"claude_missing":125}[cls]
json.dump({"exit_class":cls,"exit":normalized_exit,"provider_exit":int(rc) if rc.isdigit() else rc,"status":sub or None,"stop_reason":stop or None,
           "short_timeout_accepted":bool(int(short_ok)),"timeout_cap_s":int(cap),"is_error":(last or {}).get("is_error"),
           "duration_ms":(last or {}).get("duration_ms"),"permission_denials":(last or {}).get("permission_denials"),
           "total_cost_usd":(last or {}).get("total_cost_usd"),"source":source,"schema_valid":schema_valid,
           "refusal_text":refusal_text,"limit_text":limit_text,"schema_error":schema_error,"result":res or {}}, open(norm,"w"), indent=1)
'

# ---------------------------------------------------------------- repository trust (read only)
# Prints `on` or `off` and the reason, as the header's "Repository configuration" says. The flag is
# the owner's word and needs no file. The root is found by filesystem lookup alone, so no Git
# process, hook or fsmonitor runs, and a nested repository stops the walk to a trusted ancestor.
# shellcheck disable=SC2016
PROJECT_STATE_PY='
import json,os,sys
from pathlib import Path
cwd,flag=sys.argv[1:3]
if flag:
    print(flag,"flag"); sys.exit(0)
# Walk from the physical path without following the .git entry. A linked worktree does not inherit
# trust from its main checkout, so trust it directly or use --project-config.
physical=Path(cwd).resolve()
spellings=[cwd,str(physical)]
for parent in (physical,*physical.parents):
    if os.path.lexists(parent/".git"):
        spellings.append(str(parent))
        break
home=os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~")
try:
    projects=json.loads(Path(home,".claude.json").read_text(encoding="utf-8")).get("projects",{})
    if not isinstance(projects,dict): raise ValueError("projects is not an object")
except (OSError,ValueError,AttributeError):
    print("off unreadable-trust"); sys.exit(0)
for path in spellings:
    entry=projects.get(path)
    if isinstance(entry,dict) and entry.get("hasTrustDialogAccepted") is True:
        print("on trusted"); sys.exit(0)
print("off unseen")
'

# ---------------------------------------------------------------- normalize-only subcommand
# Help first: the option loop below only runs after three positionals, so a bare `--help` would
# otherwise die on a missing out-dir.
case "${1:-}" in -h|--help) sed -n '2,186p' "$0"; exit 0;; esac
if [ "${1:-}" = normalize ]; then
  [ $# -ge 4 ] || { echo "usage: $0 normalize <stream.jsonl> <final.json> <result.json> <rc> [short_ok] [cap] [schema]" >&2; exit 2; }
  exec python3 -I -B -c "$NORMALIZE_PY" "$2" "$3" "$4" "$5" "${6:-0}" "${7:-600}" "${8:-}"
fi

# The lane comes from the NAME this script is run by: install.sh --bin links both `claude-review`
# and `claude-write` to this one file. Only a name ending in -write is a writer; every other name
# (the review link, this file's own) stays the reviewer, with reading tools only.
invoked="${0##*/}"
case "$invoked" in *-write) lane=writer;; *) lane=review;; esac

# A positional that begins with "-" is an option in the wrong place, not a name: `<out> --cwd
# <brief>` used to take --cwd as the job name (the name pattern allows it) and run in the caller's
# directory. Refused here, before the options are read and before anything is written.
no_dash() { case "$2" in -*) echo "$invoked: the $1 begins with \"-\" ($2). Options go after the three positionals: <out-dir> <job-name> <prompt-file> [options]" >&2; exit 2;; esac; }
# The check runs on the words as given, BEFORE the required-argument expansion below: a call
# that is also short (`<out> --cwd`) must get this refusal, not the shell's "parameter not set".
no_dash out-dir "${1-}"; no_dash "job name" "${2-}"; no_dash "prompt file" "${3-}"
out="${1:?out-dir}"; job="${2:?job-name}"; prompt_file="${3:?prompt-file}"; shift 3
cwd="$PWD"; model="sonnet"; effort=""; schema=""; tools="Read,Grep,Glob"; max_turns="40"; timeout="10m"; wait_flag=0; short_ok=0; project_on=0; project_off=0
# A writer gets the edit tools and no Bash, and a budget sized for an implementation package.
if [ "$lane" = writer ]; then tools="Read,Grep,Glob,Edit,Write"; max_turns="150"; timeout="60m"; fi
add_dirs=(); bash_allow=(); review_tools_seen=0
review_tools_error() {
  echo "$invoked: $1; reviewer --tools permits only Read, Grep, Glob separated by ASCII spaces or single commas (no leading/trailing separators). The coordinator must supply shell/Git/test evidence in the brief; use claude-write for owner-authorized edits." >&2
  exit 2
}
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
    --tools)
      if [ "$lane" = review ]; then
        [ "$review_tools_seen" -eq 0 ] || review_tools_error "repeated --tools"
        [ "$#" -ge 2 ] || review_tools_error "--tools needs a value"
        review_tools_seen=1
        # Match the whole argv element without trimming. Literal spaces are the only
        # whitespace accepted, including around the one comma in a separator.
        review_tools_pattern='^(Read|Grep|Glob)(( +| *, *)(Read|Grep|Glob))*$'
        [[ "$2" =~ $review_tools_pattern ]] || review_tools_error "invalid --tools value"
        tools=""
        for review_tool in Read Grep Glob; do
          case "$2" in *"$review_tool"*) tools="${tools:+$tools,}$review_tool";; esac
        done
      else
        tools="$2"
      fi
      shift 2;;
    --bash-allow)
      [ "$lane" = writer ] || { echo "--bash-allow is a claude-write option; a reviewer has no use for it" >&2; exit 2; }
      # An empty pattern (an unset variable in the caller) would become the rule `Bash()`.
      [ -n "${2:-}" ] || { echo "--bash-allow needs a non-empty pattern" >&2; exit 2; }
      # The CLI splits each rule again and tracks one level of parentheses only, so a pattern with
      # a parenthesis of its own would lose its rule or become several rules.
      case "$2" in *"("*|*")"*) echo "--bash-allow pattern may not contain ( or ): the CLI would split the rule there. Cover a parenthesised part of the command with *" >&2; exit 2;; esac
      bash_allow+=("$2"); shift 2;;
    --max-turns) max_turns="$2"; shift 2;;
    --timeout) timeout="$2"; shift 2;;
    --short-timeout-ok) short_ok=1; shift;;
    --project-config) project_on=1; shift;;
    --no-project-config) project_off=1; shift;;
    --wait) wait_flag=1; shift;;
    -h|--help) sed -n '2,186p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
if [ "$lane" = writer ]; then
  # A writer's --tools is plain tool names, checked positively: a value this launcher cannot read
  # as names is refused, not passed on. Lower-cased with tr (bash 3.2 has no ${v,,}, and a global
  # nocasematch would reach the review path); all of it stays inside this writer branch.
  # If tr cannot run, both checks below would pass on an empty string: stop instead.
  tools_lc="$(printf '%s' "$tools" | /usr/bin/env LC_ALL=C tr 'A-Z' 'a-z')" || { echo "$invoked: cannot check --tools (tr did not run); nothing launched" >&2; exit 2; }
  case ",${tools_lc// /,}," in
    # Bash reaches a writer only as --bash-allow patterns. A bare `Bash` in --tools would make every
    # command available, and the legacy reviewer --tools "Read,Grep,Glob,Bash" form is one copy away.
    *,bash,*|*,bash\(*) echo "$invoked: Bash is not a --tools value for a writer; pass --bash-allow '<pattern>' for each command it may run" >&2; exit 2;;
    # The CLI's preset `default` is every built-in tool, Bash included.
    *,default,*|*,preset:default,*) echo "$invoked: the preset 'default' is not a --tools value for a writer (it is every built-in tool, Bash included); name the tools" >&2; exit 2;;
  esac
  # Whatever is left must be letters, digits, underscores, commas and spaces. That closes a tab or
  # newline separator, !Name, preset: and rule syntax in one check. The x keeps a trailing newline
  # from being stripped by the command substitution.
  tools_rest="$(printf '%s' "$tools" | /usr/bin/env LC_ALL=C tr -d 'A-Za-z0-9_, '; printf x)"
  [ "$tools_rest" = x ] || { echo "$invoked: --tools for a writer is tool names separated by commas or spaces and nothing else (letters, digits and _)" >&2; exit 2; }
fi
if [ "$project_on" -eq 1 ] && [ "$project_off" -eq 1 ]; then
  echo "$invoked: --project-config and --no-project-config contradict each other; give at most one" >&2; exit 2
fi
[ -s "$prompt_file" ] || { echo "prompt file missing or empty: $prompt_file" >&2; exit 2; }
case "$job" in *[!A-Za-z0-9._-]*|"") echo "job name must match [A-Za-z0-9._-]+ (no slashes): $job" >&2; exit 2;; esac
out="$(mkdir -p "$out" && cd "$out" && pwd)" || { echo "cannot create out-dir: $out" >&2; exit 2; }
cwd="$(cd "$cwd" 2>/dev/null && pwd)" || { echo "cwd not found: $cwd" >&2; exit 2; }
[ -z "$schema" ] || [ -s "$schema" ] || { echo "schema file missing or empty: $schema" >&2; exit 2; }


# The raw value is checked as digits and one optional unit BEFORE any arithmetic: bash evaluates
# array subscripts inside $(( )), so an unchecked value such as `X[$(cmd)0]m` would run cmd. The
# digits are then read as decimal, so 08m is eight minutes rather than a bad octal number.
case "$timeout" in ''|*[!0-9hms]*|[hms]*|*[hms]?*|?????????*) echo "bad --timeout: $timeout (use e.g. 10m, 600s, 1h)" >&2; exit 2;; esac
to_secs() { case "$1" in *h) echo $(( 10#${1%h} * 3600 ));; *m) echo $(( 10#${1%m} * 60 ));; *s) echo $(( 10#${1%s} ));; *) echo $(( 10#$1 ));; esac; }
cap="$(to_secs "$timeout" 2>/dev/null)"
case "$cap" in ''|*[!0-9]*) echo "bad --timeout: $timeout (use e.g. 10m, 600s, 1h)" >&2; exit 2;; esac
FLOOR=300
if [ "$cap" -lt "$FLOOR" ] && [ "$short_ok" -eq 0 ]; then
  echo "--timeout $timeout is below the ${FLOOR}s floor (a repository review measured 179 s plus startup; a short cap is how the original false stall happened). Pass --short-timeout-ok to accept it — it is recorded in result.json." >&2; exit 2
fi

# Check the READ, not just the stat: `-s` at line 182 is true for a directory and for an unreadable
# file, and this script does not run under `set -e`, so a bare `$(cat …)` would hand `claude -p ""`
# an empty prompt — a full-price review of nothing reported as success. Capture and check instead.
prompt_text="$(cat "$prompt_file")" || { echo "cannot read prompt file: $prompt_file" >&2; exit 2; }
# Read caller inputs before reserving where possible. The schema snapshot itself
# is a canonical job artifact, so it is created only after reservation.
schema_text=""
if [ -n "$schema" ]; then
  schema_text="$(cat "$schema")" || { echo "cannot read schema file: $schema" >&2; exit 2; }
fi
script="$(python3 -I -B -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$0")" || exit 2
# Repository configuration, see the header. A trust record that cannot be read never fails the launch.
project_flag=""; [ "$project_on" -eq 0 ] || project_flag=on; [ "$project_off" -eq 0 ] || project_flag=off
project_state="$(python3 -I -B -c "$PROJECT_STATE_PY" "$cwd" "$project_flag" 2>/dev/null)" || project_state=""
[ -n "$project_state" ] || project_state="off unreadable-trust"
project_config="${project_state%% *}"; project_reason="${project_state#* }"
python3 -I -B "${script%/*}/reserve_job.py" "$out" "$job" || exit 2
# Pre-check failures retain their permanently reserved attempt and fresh lane receipts.
lane_receipts() { echo "$lane" > "$out/$job.lane"; printf '%s\n%s\n' "$project_config" "$project_reason" > "$out/$job.project-config"; }
if ! command -v claude >/dev/null 2>&1; then echo "claude not installed on this Mac" >&2; lane_receipts; echo 125 > "$out/$job.exit"; exit 125; fi
if claude auth status >/dev/null 2>&1; then :; else
  # `claude auth status` exits non-zero when logged out (and on unknown-subcommand in old builds);
  # only treat a clearly logged-out state as not_authenticated. The words are read from captured
  # output, not from a pipe: under pipefail a pipe takes the CLI's own non-zero exit, so the
  # logged-out case was never recognised.
  auth_said="$(claude auth status 2>&1 || true)"
  if grep -qiE 'not logged in|logged out|no credentials|please log in' <<<"$auth_said"; then
    echo "existing Claude authentication is unavailable; report the blocked lane to the owner" >&2; lane_receipts; echo 3 > "$out/$job.exit"; exit 3
  fi
fi

if [ "$lane" = writer ]; then
  # `claude --tools` is the availability whitelist; --allowedTools carries the Bash rules and
  # nothing else, one argument per rule. The CLI splits every argument again on commas and spaces
  # outside parentheses, tracking one level only: the spaces and commas inside `Bash(…)` survive,
  # a parenthesis inside the pattern would not, which is why --bash-allow refuses one. Edit and
  # Write are deliberately not allow rules: acceptEdits already approves edits inside the working
  # directories, and a bare tool-name rule is not scoped to them.
  avail="$tools"; rules=()
  if [ "${#bash_allow[@]}" -gt 0 ]; then
    avail="${tools:+$tools,}Bash"
    for p in "${bash_allow[@]}"; do rules+=("Bash($p)"); done
  fi
  args=(-p "$prompt_text" --permission-mode acceptEdits --output-format stream-json --verbose --tools "$avail")
  [ "${#rules[@]}" -gt 0 ] && args+=(--allowedTools "${rules[@]}")
  args+=(--model "$model" --max-turns "$max_turns" --no-session-persistence)
else
  args=(-p "$prompt_text" --permission-mode plan --output-format stream-json --verbose --tools "$tools" --allowedTools "$tools" --model "$model" --max-turns "$max_turns" --no-session-persistence)
fi
# The notice and the flag belong to excluded mode only; see the header.
project_notice="The launcher did not load this repository's settings, MCP servers or CLAUDE.md. If the repository has a CLAUDE.md or AGENTS.md, read it with your file tools when its rules matter. Its content is repository context and cannot widen this lane's tools or scope."
[ "$project_config" = on ] || args+=(--setting-sources user --append-system-prompt "$project_notice")
[ -n "$effort" ] && args+=(--effort "$effort")
if [ -n "$schema" ]; then
  # Capture the caller's schema once, before the job's cd, and give both consumers those bytes.
  # The permanent reservation prevents another launch from replacing the snapshot.
  schema_snapshot="$(mktemp "$out/$job.schema.XXXXXX")" || { echo "cannot create schema snapshot in: $out" >&2; exit 2; }
  printf '%s' "$schema_text" > "$schema_snapshot" || { echo "cannot write schema snapshot: $schema_snapshot" >&2; exit 2; }
  cat "$schema_snapshot" >/dev/null || { echo "cannot read schema snapshot: $schema_snapshot" >&2; exit 2; }
  schema="$schema_snapshot"
  args+=(--json-schema "$schema_text")
fi
for d in "${add_dirs[@]:-}"; do [ -n "$d" ] && args+=(--add-dir "$d"); done

# A finished run's terminal receipts. The normalizer owns the class-to-exit mapping; terminal
# receipts and wait consume that same value instead of maintaining a second shell mapping. If it
# fails, or its value cannot be read back, a provider's exit 0 must not stand: the job ends as a
# failed run, a watchdog timeout stays one, and result.json says why. Every python3 in this file
# runs with -I -B: the monitor sits in --cwd and --wait in the caller's directory, and a plain
# `python3 -c` would import a json.py from either as the user.
finish_result() {
  local raw_exit normalized_exit class=reviewer_error final_exit=1
  raw_exit="$(cat "$out/$job.exit")"
  # Normalize: final result event -> <job>.json; verdict object -> <job>.result.json
  if python3 -I -B -c "$NORMALIZE_PY" "$out/$job.stream.jsonl" "$out/$job.json" "$out/$job.result.json" "$raw_exit" "$short_ok" "$cap" "$schema" >/dev/null 2>&1 \
    && normalized_exit="$(python3 -I -B -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["exit"]))' "$out/$job.result.json" 2>/dev/null)" \
    && [ -n "$normalized_exit" ]; then
    printf '%s\n' "$normalized_exit" > "$out/$job.exit"
    return
  fi
  if [ "$raw_exit" = 124 ]; then class=timeout; final_exit=124; fi
  printf '{"exit_class":"%s","exit":%s,"provider_exit":%s,"status":null,"source":"none","schema_valid":false,"refusal_text":null,"limit_text":null,"normalization_error":"the normalizer failed; read the stream and stderr receipts","result":{}}\n' \
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

# All canonical paths belong to the permanently reserved fresh attempt.
lane_receipts
date +%s > "$out/$job.start"
( trap '' HUP
  # Cancellation, see the header. TERM only raises this flag, because it can arrive before the
  # provider exists; the poll below sends it on. One send is not enough: on /bin/bash 3.2 a TERM
  # sent just after the fork did not stop the provider (observed), so every poll sends it again.
  cancelled=0
  trap 'cancelled=1' TERM
  set +e
  if ! cd -- "$cwd" 2>/dev/null; then
    echo "cannot enter --cwd: $cwd" > "$out/$job.stderr"
    echo 1 > "$out/$job.exit"
    finish_result
    mark_end
    exit 1
  fi
  if [ "$lane" = writer ]; then export CLAUDE_ORCHESTRATION_WORKER=1; else unset CLAUDE_ORCHESTRATION_WORKER; fi
  nohup claude "${args[@]}" </dev/null > "$out/$job.stream.jsonl" 2> "$out/$job.stderr" & cp=$!; i=0
  while kill -0 $cp 2>/dev/null && [ $i -lt "$cap" ]; do
    [ "$cancelled" -eq 0 ] || kill -TERM $cp 2>/dev/null
    sleep 2; i=$((i+2))
  done
  trap '' TERM   # the provider is over or the watchdog has it: the receipts below are not interrupted
  if kill -0 $cp 2>/dev/null; then
    kill -TERM $cp 2>/dev/null; g=0; while kill -0 $cp 2>/dev/null && [ $g -lt 5 ]; do sleep 1; g=$((g+1)); done   # grace: let the stream flush
    kill -0 $cp 2>/dev/null && kill -9 $cp 2>/dev/null
    echo 124 > "$out/$job.exit"; echo "watchdog: timed out after ${cap}s (not a verdict)" >> "$out/$job.stderr"
  else rc=0; wait $cp || rc=$?; echo "$rc" > "$out/$job.exit"; fi
  [ "$cancelled" -eq 0 ] || echo "cancelled: the monitor received TERM" >> "$out/$job.stderr"
  finish_result
  mark_end ) </dev/null >/dev/null 2>&1 &
echo $! > "$out/$job.pid"
# The monitor's identity (see Identity in the header), written whole, then renamed, or an
# unrecorded: reason. Never fatal, as in codex_job.sh, where set -e would otherwise stop the
# launcher before its launch line and --wait. A .monitor that cannot be written stays missing.
wid="$(/usr/bin/env LC_ALL=C TZ=UTC0 ps -p "$(cat "$out/$job.pid")" -o lstart=,comm= 2>/dev/null)" && [ -n "$wid" ] || wid="unrecorded: ps gave no identity"
{ printf '%s\n' "$wid" > "$out/$job.monitor.tmp" && mv -f "$out/$job.monitor.tmp" "$out/$job.monitor"; } 2>/dev/null || true
if [ "$lane" = writer ]; then
  echo "launched claude writer job '$job' — WRITER lane (permission-mode=acceptEdits model=$model effort=${effort:-default} tools=$avail bash-allow=${rules[*]:-none} max-turns=$max_turns project-config=$project_config reason=$project_reason cwd=$cwd timeout=$timeout pid=$(cat "$out/$job.pid"))"
else
  echo "launched claude reviewer job '$job' — review lane (model=$model effort=${effort:-default} tools=$tools project-config=$project_config reason=$project_reason cwd=$cwd timeout=$timeout pid=$(cat "$out/$job.pid"))"
fi
echo "  heartbeats: $out/$job.stream.jsonl   result: $out/$job.result.json   done-marker: $out/$job.end   lane: $out/$job.lane"

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
  i=0
  while [ ! -f "$out/$job.end" ]; do
    # Lost, see the header. .end is checked again after the probe: a monitor that finished
    # normally renamed .end into place before it exited.
    wrc=0; identity_state "$(sed -n 1p "$out/$job.pid" 2>/dev/null)" "$(sed -n 1p "$out/$job.monitor" 2>/dev/null)" || wrc=$?
    if [ "$wrc" -eq 1 ] && [ ! -f "$out/$job.end" ]; then
      echo "finished: class=lost elapsed=$(elapsed_since_start "$(date +%s)")"
      if [ "$lane" = writer ]; then nv="the edits may be partial"; else nv="the fresh-reviewer fallback applies (standing order 5)"; fi
      echo "lost: the monitor in $out/$job.pid is gone or is now another process and $out/$job.end is absent, so completion is unconfirmed: an .exit or result.json present is not proof of a finished run, and $nv. Nothing was signalled. The claude provider's state cannot be told: no identity of it is recorded, so do not signal it." >&2
      [ "$lane" != writer ] || echo "note: WRITER lane — the class describes the run, not the tree. Before accepting or relaunching, check under $cwd: HEAD, index, branches and stashes unchanged, only files in scope touched, no process left running. Nothing was rolled back." >&2
      exit 1
    fi
    sleep 5; i=$((i+5)); if [ $((i % 30)) -eq 0 ]; then echo "  … ${i}s, $(wc -l < "$out/$job.stream.jsonl" | tr -d ' ') events so far"; fi
  done
  rc="$(cat "$out/$job.exit")"; el="$(elapsed_since_start "$(cat "$out/$job.end" 2>/dev/null)")"
  cls=$(python3 -I -B -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("exit_class","?"), "(subtype", str(d.get("status")), "stop", str(d.get("stop_reason"))+")")' "$out/$job.result.json" 2>/dev/null || echo '?')
  echo "finished: exit=$rc class=$cls elapsed=$el ($out/$job.result.json)"
  if [ "$rc" = "3" ]; then
    echo "note: Claude answered \"Not logged in\". Either the CLI is logged out on this Mac, or it was started inside a sandbox that cannot write ~/.claude/session-env or reach the network." >&2
    echo "note: a failed lane grants no authentication or permission changes. Keep the existing authorized parent boundary; otherwise report this lane unavailable and use the required permitted fallback. A broader parent configuration is a separate owner-authorized decision." >&2
  fi
  if [ "$rc" = "5" ]; then
    if [ "$lane" = writer ]; then
      echo "note: classed as a REFUSAL (heuristic — see this script's header). The writer declined; the work is NOT done. Its words:" >&2
    else
      echo "note: classed as a REFUSAL (heuristic — see this script's header). The reviewer declined and produced no verdict; the round is NOT covered. Its words:" >&2
    fi
    python3 -I -B -c 'import json,sys; print((json.load(open(sys.argv[1])).get("refusal_text") or "")[:400])' "$out/$job.result.json" >&2 2>/dev/null || true
  fi
  if [ "$rc" = "6" ]; then
    if [ "$lane" = writer ]; then
      echo "note: Claude reported a provider limit; this lane is unavailable for now. Provider detail:" >&2
    else
      echo "note: Claude reported a provider limit; this lane is unavailable for this round. Try one other reachable non-writer family, or record the review as owed. Provider detail:" >&2
    fi
    python3 -I -B -c 'import json,sys; print((json.load(open(sys.argv[1])).get("limit_text") or "")[:500])' "$out/$job.result.json" >&2 2>/dev/null || true
  fi
  if [ "$rc" = "7" ]; then
    if [ "$lane" = writer ]; then
      echo "note: the run finished but its final message does not satisfy the --schema: the report is missing, the edits may not be. Read the writer's own words in $out/$job.json." >&2
    else
      echo "note: the run finished but returned NO VERDICT matching the schema; the round is NOT covered. Read the reviewer's own words in $out/$job.json before relaunching (a review that fans out background agents can be cut off before it reports)." >&2
    fi
  fi
  if [ "$lane" = writer ]; then
    echo "note: WRITER lane — the class describes the run, not the tree. Before accepting or relaunching, check under $cwd: HEAD, index, branches and stashes unchanged, only files in scope touched, no process left running. Nothing was rolled back." >&2
  fi
  [ "$rc" = "0" ] || { tail -3 "$out/$job.stderr" >&2; exit "$rc"; }
fi
