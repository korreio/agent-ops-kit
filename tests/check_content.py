#!/usr/bin/env python3
"""Bounded product hygiene checks; no network, private denylist or model call."""
from pathlib import Path
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import tomllib
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
# A git hook's GIT_DIR must not redirect the listing, or aim the regression's `git init` at this repository.
GIT_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def candidates(root):
    """Everything a commit could hold: tracked files plus untracked ones no ignore rule covers.

    A source archive has no .git, so its tree is scanned with a fixed skip list. In a checkout, a
    git that cannot list the files fails the check; it never falls through to fewer files.
    """
    if not (root / ".git").exists():
        return [p for p in sorted(root.rglob("*"))
                if not {".git", "__pycache__"} & set(p.relative_to(root).parts)]
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"],
                                capture_output=True, check=True, env=GIT_ENV)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"cannot list this checkout's files with git: {exc}")
    return [root / os.fsdecode(name) for name in sorted(set(listed.stdout.split(b"\0"))) if name]


def scan(root):
    errors, checked = [], 0
    for path in candidates(root):
        rel = path.relative_to(root)
        if path.is_symlink():
            errors.append(f"{rel}: unexpected symbolic link")
            continue
        if not path.is_file():
            continue
        checked += 1
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"{rel}: unexpected binary")
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        expected = 0o755 if path.suffix in {".sh"} else 0o644
        # These public CLI entry points are invoked directly by launchers/install links.
        if rel.as_posix() in {
            "agent-orchestration/bin/session_ledger.py",
        }:
            expected = 0o755
        if mode != expected:
            errors.append(f"{rel}: unexpected mode {mode:o}")
        if rel.suffix in {".log", ".jsonl", ".stderr", ".local"}:
            errors.append(f"{rel}: private-output extension")
        if any(part in {"node_modules", ".venv", "private", "scratch"} for part in rel.parts):
            errors.append(f"{rel}: private/generated directory")
        if rel.suffix == ".json":
            try:
                json.loads(text)
            except ValueError as exc:
                errors.append(f"{rel}: invalid JSON: {exc}")
        if rel.suffix == ".toml":
            try:
                tomllib.loads(text)
            except ValueError as exc:
                errors.append(f"{rel}: invalid TOML: {exc}")
        if rel.suffix == ".md":
            for target in re.findall(r"!?\[[^]\n]*\]\(([^)\n]+)\)", text):
                target = target.split(" \"", 1)[0].strip("<>")
                if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("#"):
                    continue
                local = unquote(target.split("#", 1)[0])
                if local and not (path.parent / local).exists():
                    errors.append(f"{rel}: missing local link {target}")
    return errors, checked


def regression():
    """The enumeration's own cases on a throwaway repository; `git init` stages nothing."""
    problems = []
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=GIT_ENV)
        files = {".gitignore": b".DS_Store\n*.log\n", ".DS_Store": b"\0\xff", "run.log": b"output\n",
                 "new.md": b"[gone](missing.md)\n"}
        for name, data in files.items():
            (root / name).write_bytes(data)
            (root / name).chmod(0o644)
        if scan(root)[0] != ["new.md: missing local link missing.md"]:
            problems.append("regression: an ignored file failed, or a new untracked file went unchecked")
        (root / "new.md").write_bytes(b"[here](.gitignore)\n")
        if scan(root) != ([], 2):
            problems.append("regression: a clean checkout did not pass with exactly its two text files")
        shutil.rmtree(root / ".git")
        archive = scan(root)[0]
        if "run.log: private-output extension" not in archive or ".DS_Store: unexpected binary" not in archive:
            problems.append("regression: a tree with no .git was not scanned in full")
        (root / ".git").write_bytes(b"not a repository\n")
        try:
            scan(root)
            problems.append("regression: a git that cannot list the files passed")
        except SystemExit:
            pass
    return problems


errors, checked = scan(ROOT)
if (ROOT / ".git").exists():
    errors += regression()
if (ROOT / "AGENTS.md").read_bytes() != (ROOT / "CLAUDE.md").read_bytes():
    errors.append("root contributor loaders differ")
workflow = (ROOT / ".github/workflows/ci.yml").read_text()
if "pull_request_target" in workflow or "upload-artifact" in workflow:
    errors.append("workflow: unexpected privileged trigger or artifact upload")
for action in re.findall(r"uses:\s*([^\s]+)", workflow):
    if not re.fullmatch(r"actions/(checkout|setup-python)@[0-9a-f]{40}", action):
        errors.append("workflow: unexpected dependency or unpinned action")
if "persist-credentials: false" not in workflow or "contents: read" not in workflow:
    errors.append("workflow: missing least-privilege checkout settings")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Content checks passed for {checked} text files; local links, loaders, modes and bounded CI policy checked.")
