#!/usr/bin/env bash
# SessionStart hook (matcher: startup). Prints ONE line on stdout, which Claude Code adds to the
# session's context, and only when the roster (../../roster.md from this script's real location)
# looks stale. Nothing is printed otherwise. It makes no model call, uses no network and changes
# nothing. Three checks, each on its own, so one that cannot run does not silence the others:
#   1. the roster's "Last checked: YYYY-MM-DD" line is more than 14 days old;
#   2. a model the roster's Codex table names is absent from the installed catalog
#      (~/.codex/models_cache.json), hidden there, or carries an `upgrade` notice. A catalog that
#      is missing, unreadable, over 8 MB, of another shape or EMPTY counts as unavailable and the
#      check is skipped: an empty list is far more likely a broken cache than every model retired;
#   3. a Claude Code alias ran as a different concrete model than the roster's "Claude Code
#      aliases" table records. Read from lane transcripts
#      (~/.claude/projects/*/*/subagents/agent-*.jsonl): the 20 with the newest modification time
#      are opened, the last 256 KB of each is parsed as JSON lines, and the last record of type
#      "assistant" gives the model and the time. Lanes older than 7 days by that record's own
#      timestamp are ignored, the newest lane of a family decides, the family is the alias name
#      found in the model id (opus, sonnet, haiku), and a trailing -YYYYMMDD is ignored.
# Check 3 is a heuristic, not a signal the CLI gives. Known limits: a lane launched with an
# explicit older or newer model id trips it; a family with no lane in the window is not checked;
# only 20 transcripts are opened; a lane whose last 256 KB holds no complete assistant record is
# skipped; an alias that resolves differently on another Mac or provider trips it there.
# Only identifiers that match a short model-name grammar are ever echoed, and the line is capped
# at 400 characters, so catalog or transcript text cannot carry prose into a session.
# Fail open: a missing or unreadable roster, catalog or transcript, a roster without the expected
# lines, no python3, HOME unset or relative, or any error exits 0 with no output. Every file is
# opened without blocking, judged by fstat on the opened descriptor, read only if regular and
# never past its limit. The check itself ends silently after 3 seconds (SIGALRM, unblocked first);
# what that alarm cannot cover, a stalled interpreter start, is bounded by the 5-second `timeout`
# the settings fragment declares for this hook, which Claude Code enforces. The one step with no
# size bound is the directory listing and one stat per lane transcript.
# It also runs at the start of headless sessions (the review launchers), which is harmless.
# The Codex hook runs this file too. --runtime-model adds a fourth check, on the hook input (kept on
# fd 3): the session's `model` must be one the roster's Codex table names.
# Tests override the date with ROSTER_FRESHNESS_TODAY=YYYY-MM-DD.
set -u
here="${BASH_SOURCE[0]}"
if [ -L "$here" ]; then
  t="$(readlink "$here" 2>/dev/null)" || exit 0
  case "$here" in */*) d="${here%/*}" ;; *) d=. ;; esac
  case "$t" in /*) here="$t" ;; *) here="$d/$t" ;; esac
fi
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
roster="$here/../../roster.md"
[ -f "$roster" ] && [ -r "$roster" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
[ "${1:-}" = --runtime-model ] && exec 3<&0
python3 -I -B - "$roster" "${1:-}" 2>/dev/null <<'PY' || true
import datetime, glob, json, os, re, signal, stat, sys, time

def bail(*_):
    os._exit(0)

signal.signal(signal.SIGALRM, bail)
try:
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})   # a launcher may have left it blocked
except Exception:
    pass
signal.alarm(3)

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
reasons = []

def read_regular(path, limit, tail=False):
    # Open first, then judge the opened file: no window between a check and the read. O_NONBLOCK so
    # a FIFO put there cannot block the open; only a regular file is read, and never past the limit.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        if tail:
            os.lseek(fd, max(0, st.st_size - limit), os.SEEK_SET)
        chunks, left = [], limit + 1
        while left > 0:
            b = os.read(fd, min(left, 1 << 20))
            if not b:
                break
            chunks.append(b)
            left -= len(b)
        data = b"".join(chunks)
        if tail:
            return data[-limit:]
        return data if len(data) <= limit else None
    finally:
        os.close(fd)

def rows(text, heading):
    out, on, header = [], False, True
    for line in text.split("\n"):
        if line.strip() == "## " + heading:
            on, header = True, True
            continue
        if line.startswith("## "):
            on = False
        if not on:
            continue
        if not line.startswith("|"):
            header = True          # a new table under the same heading starts with its own header
            continue
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if all(re.match(r"^:?-+:?$", c) for c in cells):
            continue
        if header:
            header = False
            continue
        out.append(cells)
    return out

def check_age(text):
    m = re.search(r"^Last checked: ([0-9]{4}-[0-9]{2}-[0-9]{2})", text, re.M)
    if not m:
        return
    today = os.environ.get("ROSTER_FRESHNESS_TODAY")
    now = datetime.date.fromisoformat(today) if today else datetime.date.today()
    age = (now - datetime.date.fromisoformat(m.group(1))).days
    if age > 14:
        reasons.append("last checked %s, %d days ago" % (m.group(1), age))

def check_codex(text, home):
    raw = read_regular(os.path.join(home, ".codex", "models_cache.json"), 8 * 1024 * 1024)
    if raw is None:
        return
    cat = json.loads(raw.decode("utf-8"))
    listed = cat.get("models")
    if not isinstance(listed, list) or not listed:
        return
    models = {e["slug"]: e for e in listed if isinstance(e, dict) and isinstance(e.get("slug"), str)}
    if not models:
        return
    names = sorted({r[1] for r in rows(text, "Codex") if len(r) > 1 and NAME.match(r[1])})
    for name in names:
        e = models.get(name)
        if e is None:
            reasons.append("Codex model %s is not in the installed catalog" % name)
        elif e.get("upgrade"):
            up = e["upgrade"].get("model") if isinstance(e["upgrade"], dict) else None
            ok = isinstance(up, str) and NAME.match(up)
            reasons.append("Codex model %s is being replaced%s" % (name, " by %s" % up if ok else ""))
        elif e.get("visibility") not in (None, "list"):
            reasons.append("Codex model %s is no longer listed" % name)

def last_assistant(path):
    tail = read_regular(path, 262144, tail=True)
    if tail is None:
        return None
    for raw in reversed(tail.split(b"\n")):
        try:
            rec = json.loads(raw)
        except Exception:
            continue
        if not isinstance(rec, dict) or rec.get("type") != "assistant":
            continue
        msg = rec.get("message")
        model = msg.get("model") if isinstance(msg, dict) else None
        stamp = rec.get("timestamp")
        if not (isinstance(model, str) and NAME.match(model) and isinstance(stamp, str)):
            continue
        when = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if when.tzinfo is None:
            when = when.replace(tzinfo=datetime.timezone.utc)
        return when.timestamp(), model
    return None

def check_aliases(text, home):
    recorded = {r[0]: r[1] for r in rows(text, "Claude Code aliases")
                if len(r) > 1 and NAME.match(r[0]) and NAME.match(r[1])}
    if not recorded:
        return
    files = []
    for f in glob.glob(os.path.join(home, ".claude", "projects", "*", "*", "subagents", "agent-*.jsonl")):
        try:
            files.append((os.path.getmtime(f), f))
        except OSError:
            continue
    cutoff = time.time() - 7 * 86400
    newest = {}
    for _, f in sorted(files, reverse=True)[:20]:
        try:
            got = last_assistant(f)
        except Exception:
            continue
        if not got or got[0] < cutoff:
            continue
        for alias in recorded:
            if alias in got[1] and (alias not in newest or got[0] > newest[alias][0]):
                newest[alias] = got
    strip = lambda s: re.sub(r"-[0-9]{8}$", "", s)
    for alias in sorted(newest):
        ran = newest[alias][1]
        if strip(ran) != strip(recorded[alias]):
            reasons.append("alias %s ran as %s, the roster records %s" % (alias, ran, recorded[alias]))

def check_runtime(text):
    with os.fdopen(3) as hook_input:
        model = json.load(hook_input).get("model")
    names = {r[1] for r in rows(text, "Codex") if len(r) > 1 and NAME.match(r[1])}
    if isinstance(model, str) and NAME.match(model) and names and model not in names:
        reasons.append("runtime model %s is not in the Codex roster" % model)

def main():
    path = sys.argv[1]
    raw = read_regular(path, 1024 * 1024)
    if raw is None:
        return
    text = raw.decode("utf-8")
    home = os.environ.get("HOME", "")
    checks = [lambda: check_age(text)]
    if os.path.isabs(home):
        checks += [lambda: check_codex(text, home), lambda: check_aliases(text, home)]
    if sys.argv[2:3] == ["--runtime-model"]:
        checks.append(lambda: check_runtime(text))
    for check in checks:
        try:
            check()
        except Exception:
            pass
    if not reasons:
        return
    where = os.path.realpath(path)
    if os.path.isabs(home) and where.startswith(home.rstrip("/") + "/"):
        where = "~" + where[len(home.rstrip("/")):]
    if not re.match(r"^[A-Za-z0-9~/._ -]{1,200}$", where):
        where = "the roster"
    tail = ". See %s and tell the owner; change nothing without their approval. To clear it, recheck and update Last checked in the roster, or omit the hook." % where
    body = "Roster check: " + "; ".join(reasons)
    line = " ".join((body[: max(0, 400 - len(tail))] + tail).split())
    sys.stdout.write(line + "\n")

try:
    main()
except Exception:
    pass
PY
exit 0
