#!/usr/bin/env python3
"""Synthetic launcher integration checks; invoked by test_launchers.sh."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import time

PKG, ROOT = map(lambda value: Path(value).resolve(), sys.argv[1:3])
ROOT.mkdir()
RESULTS = []
CHILDREN = []
GATES = []
SCHEMA = {"type": "object", "properties": {"verdict": {"type": "string", "enum": ["CLEAN", "FINDING", "BLOCKED"]}, "notes": {"type": "string"}}, "required": ["verdict", "notes"]}
VALID = {"verdict": "CLEAN", "notes": "synthetic fixture"}


def check(name, predicate):
    RESULTS.append({"name": name, "passed": bool(predicate)})


def snapshot(out, job, active=False):
    # The first Codex monitor may still attest its child identity during startup.
    volatile = {job + ".codex.pid", job + ".codex.pid.tmp"} if active else set()
    return {p.name: (oct(stat.S_IMODE(p.stat().st_mode)), hashlib.sha256(p.read_bytes()).hexdigest()) for p in out.iterdir() if p.is_file() and p.name.startswith(job + ".") and p.name not in volatile}


def fixture(name):
    root = ROOT / name
    for part in ("bin", "home", "tmp", "work", "out"):
        (root / part).mkdir(parents=True, exist_ok=True)
    (root / "brief.md").write_text("Review only invented fixture content.\n")
    (root / "schema.json").write_text(json.dumps(SCHEMA) + "\n\n")
    provider = '''#!/usr/bin/env python3
from pathlib import Path
import json, os, sys, time
name=Path(sys.argv[0]).name; args=sys.argv[1:]; root=Path(os.environ['FIXTURE_ROOT'])
if (name=='claude' and args[:1]==['auth']) or (name=='codex' and args[:1]==['login']):
    with (root/'auth.calls').open('a') as calls: calls.write('auth\\n')
    move=os.environ.get('MOVE_CWD')
    if move:
        path=Path(move); assert path.resolve().is_relative_to(root.resolve())
        if path.exists(): path.rename(path.with_name(path.name+'-moved'))
    sys.exit(0)
tag=os.environ['FIXTURE_TAG']; info={'argv':args,'cwd':os.getcwd(),'pid':os.getpid()}
if '--json-schema' in args:
    value=args[args.index('--json-schema')+1]
    info['schema_arg']=value
    if not value.lstrip().startswith('{'): info['schema_text']=Path(value).read_text()
(root/(tag+'.started')).write_text(json.dumps(info))
gate=os.environ.get('FIXTURE_GATE'); deadline=time.monotonic()+15
while gate and not Path(gate).exists() and time.monotonic()<deadline: time.sleep(.02)
if gate and not Path(gate).exists(): sys.exit(91)
body=json.loads(os.environ.get('FIXTURE_BODY','{"verdict":"CLEAN","notes":"synthetic fixture"}'))
if name=='codex':
    if '-o' in args: Path(args[args.index('-o')+1]).write_text(json.dumps({'tag':tag})+'\\n')
    print(json.dumps({'type':'thread.started','thread_id':'synthetic-thread'}))
    print(json.dumps({'type':'turn.started'}))
    print(json.dumps({'type':'item.completed','item':{'id':'i1','type':'agent_message','text':json.dumps(body)}}))
    print(json.dumps({'type':'turn.completed','usage':{'input_tokens':1,'cached_input_tokens':0,'output_tokens':1}}))
elif name=='claude':
    print(json.dumps({'type':'result','subtype':'success','is_error':os.environ.get('FIXTURE_ERROR')=='1','result':json.dumps(body)}))
'''
    for name in ("claude", "codex"):
        (root / "bin" / name).write_text(provider)
        (root / "bin" / name).chmod(0o755)
    for name in ("claude-review", "claude-write", "codex-review", "codex-write"):
        family = name.split("-")[0]
        (root / "bin" / name).symlink_to(PKG / "bin" / (family + "_job.sh"))
    return root


def launch(root, family, job, tag, *, gate=None, schema=None, body=None, relative=False, writer=False, move=False, extra=(), command=None):
    command = command or root / "bin" / (family + ("-write" if writer else "-review"))
    out = "out" if relative else str(root / "out")
    args = [str(command)]
    args += [out, job, str(root / "brief.md"), "--cwd", "work" if relative else str(root / "work")]
    if family == "claude":
        args += ["--model", "synthetic-model", "--timeout", "300s"]
    if schema is not None:
        args += ["--schema", schema]
    args += list(extra) + ["--wait"]
    env = {"PATH": str(root / "bin") + os.pathsep + str(Path(sys.executable).parent) + ":/opt/homebrew/bin:/usr/bin:/bin", "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "FIXTURE_ROOT": str(root), "FIXTURE_TAG": tag}
    if gate:
        env["FIXTURE_GATE"] = str(gate)
        GATES.append(gate)
    if body is not None:
        env["FIXTURE_BODY"] = json.dumps(body)
    if relative:
        env["CDPATH"] = str(root)
    if move:
        env["MOVE_CWD"] = str(root / "work")
    if tag == "generic-error":
        env["FIXTURE_ERROR"] = "1"
    stdout = (root / (tag + ".stdout")).open("w")
    stderr = (root / (tag + ".stderr")).open("w")
    child = subprocess.Popen(args, cwd=root, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
    stdout.close(); stderr.close()
    CHILDREN.append(child)
    return child


def wait_started(root, tag):
    deadline = time.monotonic() + 10
    while not (root / (tag + ".started")).exists() and time.monotonic() < deadline:
        time.sleep(.02)
    return (root / (tag + ".started")).exists()


def wait(child):
    try:
        return child.wait(timeout=20)
    except subprocess.TimeoutExpired:
        if child.poll() is None and os.getpgid(child.pid) == child.pid:
            os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=5)
        return 92


def reserve(out, job):
    return subprocess.run([sys.executable, "-I", "-B", str(PKG / "bin/reserve_job.py"), str(out), job], capture_output=True, text=True).returncode


def output_snapshot(root):
    # Include reservation directories and every receipt, including modes; an absent receipt is
    # never accepted as proof that a previous real launch's receipts survived.
    out = root / "out"
    return {str(p.relative_to(out)): (oct(stat.S_IMODE(p.stat().st_mode)),
            hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "directory")
            for p in out.rglob("*")}


def refuse_before_start(root, command, job, tag, extra):
    before = output_snapshot(root)
    auth = (root / "auth.calls").read_bytes() if (root / "auth.calls").exists() else None
    env = {"PATH": str(root / "bin") + os.pathsep + str(Path(sys.executable).parent) + ":/opt/homebrew/bin:/usr/bin:/bin",
           "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "FIXTURE_ROOT": str(root), "FIXTURE_TAG": tag}
    args = [str(command), str(root / "out"), job, str(root / "brief.md"), "--cwd", str(root / "work")]
    # The final --tools really has no argv element after it in the missing-value case.
    result = subprocess.run(args + list(extra), cwd=root, env=env, capture_output=True, text=True, timeout=10)
    after_auth = (root / "auth.calls").read_bytes() if (root / "auth.calls").exists() else None
    return (result.returncode == 2 and bool(result.stderr.strip()) and auth == after_auth
            and not (root / (tag + ".started")).exists() and output_snapshot(root) == before)


try:
    for first, second in [("same", "same"), ("a", "a.result"), ("a.result", "a"), ("a", "a.codex"), ("a.schema.strict", "a"), ("Review", "review")]:
        out = ROOT / ("claims-" + str(len(RESULTS))); out.mkdir()
        rc1 = reserve(out, first)
        sentinel = out / (first + ".end"); sentinel.write_text("first receipt\n"); sentinel.chmod(0o640)
        before = snapshot(out, first)
        rc2 = reserve(out, second)
        check("immutable namespace " + first + " / " + second, rc1 == 0 and rc2 == 2 and snapshot(out, first) == before)
    out = ROOT / "unrelated"; out.mkdir()
    check("unrelated full dotted identifiers stay independent", reserve(out, "review.one") == 0 and reserve(out, "review.two") == 0)
    out = ROOT / "schema-word-siblings"; out.mkdir()
    first = "review.schema.one"
    rc1 = reserve(out, first)
    for suffix in (".start", ".end", ".result.json", ".schema.json", ".schema.strict.json", ".schema.A1b2C3"):
        (out / (first + suffix)).write_text("synthetic receipt\n")
    before = snapshot(out, first)
    check("schema-word siblings with populated receipts stay independent", rc1 == 0 and reserve(out, "review.schema.two") == 0 and snapshot(out, first) == before)
    for job in (".", "..", "x" * 160):
        out = ROOT / ("safe-key-" + str(len(RESULTS))); out.mkdir()
        check("bounded safe claim key for " + repr(job[:12]), reserve(out, job) == 0 and len(list((out / ".launcher-jobs").glob("*.json"))) == 1)
    out = ROOT / "finder-metadata"; out.mkdir()
    first_code = reserve(out, "first")
    metadata = out / ".launcher-jobs/.DS_Store"; metadata.write_bytes(b"synthetic Finder metadata")
    second_code = reserve(out, "second")
    (out / ".launcher-jobs/unrecognized.json").write_text("not a claim\n")
    check("Finder metadata is preserved without accepting malformed registry records", first_code == 0 and second_code == 0 and metadata.read_bytes() == b"synthetic Finder metadata" and reserve(out, "third") == 2)
    for suffix in (".end", ".result.json", ".events.jsonl", ".schema.strict.json", ".schema.RANDOM", ".schema.json", ".codex.pid.tmp", ".project-config"):
        out = ROOT / ("legacy-" + str(len(RESULTS))); out.mkdir()
        path = out / ("legacy" + suffix); path.write_text("preserve\n"); path.chmod(0o640)
        check("legacy receipt preserved " + suffix, reserve(out, "legacy") == 2 and path.read_text() == "preserve\n" and stat.S_IMODE(path.stat().st_mode) == 0o640)
    for index in range(3):
        out = ROOT / ("atomic-" + str(index)); out.mkdir()
        children = [subprocess.Popen([sys.executable, "-I", "-B", str(PKG / "bin/reserve_job.py"), str(out), job], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for job in ("race", "race.result")]
        codes = sorted(child.wait(timeout=10) for child in children)
        check("atomic conflicting claim publication " + str(index), codes == [0, 2])

    for family in ("codex", "claude"):
        root = fixture("overlap-" + family); gate = root / "release"
        first = launch(root, family, "run", "first", gate=gate)
        started = wait_started(root, "first")
        before = snapshot(root / "out", "run", active=True)
        second = launch(root, family, "run", "second")
        second_code = wait(second)
        other = "claude" if family != "claude" else "codex"
        cross = launch(root, other, "run.result", "cross")
        cross_code = wait(cross)
        check(family + " active/symlink/cross-provider reuse preserves first receipts", started and second_code == 2 and cross_code == 2 and not (root / "second.started").exists() and not (root / "cross.started").exists() and first.poll() is None and snapshot(root / "out", "run", active=True) == before)
        gate.write_text("release\n")
        check(family + " first waiter completes its own run", wait(first) == 0 and (root / "out/run.end").exists())
        before = snapshot(root / "out", "run")
        again = launch(root, family, "run", "again")
        check(family + " completed namespace stays preserved", wait(again) == 2 and not (root / "again.started").exists() and snapshot(root / "out", "run") == before)
        fresh = launch(root, family, "follow-up", "fresh", extra=("--resume", "synthetic-thread") if family == "codex" else ())
        check(family + " fresh follow-up namespace succeeds", wait(fresh) == 0 and (root / "fresh.started").exists() and snapshot(root / "out", "run") == before)

    root = fixture("claimed-dotted-siblings"); gate = root / "release"
    first = launch(root, "codex", "round.codex", "first", gate=gate)
    started = wait_started(root, "first")
    before = snapshot(root / "out", "round.codex", active=True)
    second = launch(root, "claude", "round.claude", "second")
    check("claimed dotted siblings launch independently with real receipts", started and wait(second) == 0 and (root / "second.started").exists() and first.poll() is None and snapshot(root / "out", "round.codex", active=True) == before)
    gate.write_text("release\n")
    check("claimed dotted sibling waiter keeps its own completion", wait(first) == 0 and (root / "out/round.codex.end").exists() and (root / "out/round.claude.end").exists())

    for family in ("codex", "claude"):
        root = fixture("cdpath-" + family)
        child = launch(root, family, "relative", "relative", relative=True)
        code = wait(child)
        info = json.loads((root / "relative.started").read_text())
        check(family + " relative output/cwd ignores CDPATH", code == 0 and (root / "out/relative.end").exists() and not any("\n" in p.name for p in root.iterdir()) and info["cwd"] == str(root / "work"))
    root = fixture("claude-error")
    child = launch(root, "claude", "generic", "generic-error")
    code = wait(child); result = json.loads((root / "out/generic.result.json").read_text())
    check("Claude generic error uses one normalized exit", code == 1 and result["exit_class"] == "reviewer_error" and result["exit"] == 1 and result["provider_exit"] == 0 and (root / "out/generic.exit").read_text().strip() == "1")
    root = fixture("claude-missing-cwd")
    child = launch(root, "claude", "vanished", "vanished", move=True)
    code = wait(child)
    check("Claude post-preflight cwd failure terminalizes", code == 1 and (root / "out/vanished.end").exists() and (root / "out/vanished.exit").read_text().strip() == "1" and not (root / "vanished.started").exists())
    # That failure path normalizes from the caller's directory, the one place --cwd cannot cover.
    for family in ("claude", "codex"):
        root = fixture(family + "-missing-cwd-module")
        (root / "json.py").write_text("from pathlib import Path\nPath(__file__).with_name('module.ran').write_text('ran')\n")
        child = launch(root, family, "vanished", "vanished", move=True)
        code = wait(child)
        check(family + " post-preflight cwd failure terminalizes and imports nothing from the caller's directory", code == 1 and not (root / "module.ran").exists() and (root / "out/vanished.end").exists() and (root / "out/vanished.exit").read_text().strip() == "1" and json.loads((root / "out/vanished.result.json").read_text())["exit_class"] == "reviewer_error")


    # Concrete accepted values exercise spaces, commas, mixed separators, duplicate removal,
    # every singleton and schema-bearing launches through the actual reviewer executable.
    valid_tools = [(None, "Read,Grep,Glob"), ("Read", "Read"), ("Grep", "Grep"), ("Glob", "Glob"),
                   ("Read  Grep", "Read,Grep"), ("Grep, Glob", "Grep,Glob"),
                   ("Glob ,Read Glob", "Read,Glob"), ("Glob,Read,Grep,Read", "Read,Grep,Glob")]
    for index, (value, canonical) in enumerate(valid_tools):
        root = fixture("claude-tools-valid-" + str(index))
        extra = () if value is None else ("--tools", value)
        schema = str(root / "schema.json") if index % 2 else None
        child = launch(root, "claude", "review", "accepted", extra=extra, schema=schema)
        code = wait(child)
        info = json.loads((root / "accepted.started").read_text())
        args = info["argv"]
        tool_args = (args.count("--tools") == 1 and args.count("--allowedTools") == 1
                     and args[args.index("--tools") + 1] == canonical
                     and args[args.index("--allowedTools") + 1] == canonical)
        check("Claude reviewer canonical reading tools " + repr(value), code == 0 and tool_args
              and (root / "out/review.lane").read_text().strip() == "review")

    invalid_tools = ["", " ", "read,Grep", "Read,,Grep", ",Read", "Read,", "Read, ,Grep",
                     " Read", "Read ", "Read\tGrep", "Read\rGrep", "Read\nGrep", "Read\x01Grep",
                     "Read\x7fGrep", "Read,Grép", "default", "preset:default", "Read(*)", "Bash(git:*)",
                     "Bash", "Edit", "Write", "Agent", "Read,Grep,Glob,Bash", "Read,WebFetch", "Read_Grep"]
    invalid_options = [(repr(value), ("--tools", value)) for value in invalid_tools]
    invalid_options += [("missing value", ("--tools",)),
                        ("missing before option", ("--tools", "--wait")),
                        ("repeated value", ("--tools", "Read", "--tools", "Grep"))]
    root = fixture("claude-tools-refusal")
    seed = launch(root, "claude", "preserved", "seed", extra=("--tools", "Read"))
    check("Claude refusal receipt seed is a real completed review", wait(seed) == 0
          and (root / "seed.started").exists() and (root / "out/preserved.end").exists())
    for index, (label, extra) in enumerate(invalid_options):
        for job in ("available", "preserved"):
            check("Claude reviewer refuses " + label + " before auth/provider/reservation; " + job,
                  refuse_before_start(root, root / "bin/claude-review", job, "rejected-" + str(index) + job, extra))

    # Current PATH name, direct script, old shim, a linked skill directory and the pre-move
    # bin link all remain reviewer-only. The legacy readonly spelling remains usable.
    root = fixture("codex-review-routes")
    shim = PKG / "claude/skills/cross-review/scripts/codex_job.sh"
    (root / "skill").symlink_to(PKG / "claude/skills/cross-review", target_is_directory=True)
    (root / "bin/old-codex-review").symlink_to(shim)
    routes = [root / "bin/codex-review", PKG / "bin/codex_job.sh", shim,
              root / "skill/scripts/codex_job.sh", root / "bin/old-codex-review"]
    seed = launch(root, "codex", "preserved", "writer-seed", writer=True)
    check("Codex review-route refusal seed is an explicit writer", wait(seed) == 0
          and (root / "writer-seed.started").exists() and (root / "out/preserved.lane").read_text().strip() == "writer")
    for index, command in enumerate(routes):
        child = launch(root, "codex", "readonly-" + str(index), "readonly-" + str(index),
                       command=command, extra=("--sandbox", "read-only"))
        check("Codex retained review route accepts readonly " + str(index), wait(child) == 0
              and (root / ("readonly-" + str(index) + ".started")).exists()
              and (root / ("out/readonly-" + str(index) + ".lane")).read_text().strip() == "review")
        for option in [("--sandbox", "workspace-write"), ("--role", "writer-bounded"), ("--role", "writer-takeover")]:
            for job in ("available", "preserved"):
                check("Codex review route " + str(index) + " refuses " + " ".join(option) + "; " + job,
                      refuse_before_start(root, command, job, "rejected-" + str(index) + job, option))

    broken = ROOT / "broken-package"
    shutil.copytree(PKG, broken)
    (broken / "bin/reserve_job.py").unlink()
    for family in ("codex", "claude"):
        root = fixture("missing-helper-" + family)
        link = root / "bin" / (family + "-review"); link.unlink(); link.symlink_to(broken / "bin" / (family + "_job.sh"))
        child = launch(root, family, "missing", "missing")
        check(family + " missing real helper writes no canonical receipt", wait(child) == 2 and not any((root / "out").glob("missing.*")) and not (root / "missing.started").exists())
except Exception as error:
    RESULTS.append({"name": "integration harness completed", "passed": False, "detail": type(error).__name__ + ": " + str(error)})
finally:
    for gate in GATES:
        gate.touch(exist_ok=True)
    for child in CHILDREN:
        if child.poll() is None:
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                if child.poll() is None and os.getpgid(child.pid) == child.pid:
                    os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
print(json.dumps(RESULTS))
sys.exit(any(not result["passed"] for result in RESULTS))
