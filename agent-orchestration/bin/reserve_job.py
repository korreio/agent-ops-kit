#!/usr/bin/env python3
"""Permanently reserve one provider-neutral flat launcher receipt namespace.

Usage: python3 -I -B /real/bin/reserve_job.py OUT JOB
The flock protects only the scan/publication transaction, never a provider run.
Claims are immutable evidence, including attempts that fail before launch.
Claims own the receipts written under them; only unclaimed receipts fall back to
conservative legacy inference. Same-user writers that skip the lock or edit the
registry are not defended against: this is bookkeeping, not a security boundary.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


# Fixed launcher artifact suffixes. For unclaimed receipts every interpretation
# is kept on purpose: a.result.json may belong to a or to a.result.
SUFFIXES = (
    ".json", ".events.jsonl", ".stream.jsonl", ".result.json", ".thread",
    ".start", ".end", ".end.tmp", ".exit", ".pid", ".stderr", ".lane", ".role",
    ".permissions", ".project-config", ".monitor", ".monitor.tmp", ".codex.pid", ".codex.pid.tmp",
    ".schema.json", ".schema.strict.json",
)
# Claude snapshots are JOB.schema.XXXXXX with a generated six-alphanumeric final
# component. Only that terminal form is a snapshot, so review.schema.one.start
# belongs to review.schema.one and never to review.
SCHEMA_SNAPSHOT = re.compile(r"\.schema\.[a-z0-9]{6}\Z", re.ASCII)
VALID_JOB = re.compile(r"[A-Za-z0-9._-]+", re.ASCII)


def conflicts(left, right):
    left, right = left.casefold(), right.casefold()
    return left == right or left.startswith(right + ".") or right.startswith(left + ".")


def artifact_jobs(name):
    """Yield every job whose launcher could have written receipt ``name``."""
    if not name.isascii():
        return  # jobs and suffixes are ASCII; this also keeps folded indices aligned
    folded = name.casefold()
    for suffix in SUFFIXES:
        if folded.endswith(suffix) and VALID_JOB.fullmatch(name[:-len(suffix)]):
            yield name[:-len(suffix)]
    snapshot = SCHEMA_SNAPSHOT.search(folded)
    if snapshot and VALID_JOB.fullmatch(name[:snapshot.start()]):
        yield name[:snapshot.start()]


def reserve(out, job):
    if not VALID_JOB.fullmatch(job):
        raise ValueError("job name must match [A-Za-z0-9._-]+")
    out = Path(out).resolve(strict=True)
    registry = out / ".launcher-jobs"
    try:
        registry.mkdir(mode=0o700)
    except FileExistsError:
        if registry.is_symlink() or not registry.is_dir():
            raise ValueError("reservation registry is not a real directory")
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(registry / "lock", flags, 0o600), "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        claimed = set()
        for claim in registry.iterdir():
            if claim.name in {"lock", ".DS_Store"} or claim.name.startswith("pending-"):
                continue
            if claim.is_symlink() or not claim.is_file() or not re.fullmatch(r"[0-9a-f]{64}\.json", claim.name):
                raise ValueError("unrecognized reservation registry entry")
            previous = json.loads(claim.read_text(encoding="utf-8"))["job"]
            if not isinstance(previous, str) or not VALID_JOB.fullmatch(previous):
                raise ValueError("invalid reservation claim")
            if conflicts(job, previous):
                raise ValueError(f"job {job!r} conflicts with permanently reserved job {previous!r}; use a fresh job name or output directory")
            claimed.add(previous.casefold())
        for receipt in out.iterdir():
            if receipt.name == registry.name:
                continue
            owners = list(artifact_jobs(receipt.name))
            # Every claim was checked against every receipt before publication,
            # so a receipt that parses as a claimed job was written under that
            # claim. The claim, already checked above, is its only owner; the
            # shorter aliases (round for round.codex.pid) are legacy guesses.
            if any(owner.casefold() in claimed for owner in owners):
                continue
            for previous in owners:
                if conflicts(job, previous):
                    raise ValueError(f"job {job!r} conflicts with existing receipt {receipt.name!r}; use a fresh job name or output directory")
        key = hashlib.sha256(job.casefold().encode("ascii")).hexdigest() + ".json"
        # A complete claim is atomically renamed while all participants hold the
        # same OS lock. Crashes release flock; published claims are never removed.
        fd, pending = tempfile.mkstemp(prefix="pending-", dir=registry)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump({"job": job}, stream)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(pending, registry / key)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)


def main():
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: reserve_job.py OUT JOB")
        reserve(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"reserve_job: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
