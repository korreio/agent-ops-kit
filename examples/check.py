#!/usr/bin/env python3
"""Check authored teaching records; optionally materialize them in new external scratch.

No provider call, installer, Git mutation, transcript access or live review occurs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check(data: dict) -> None:
    require(data["kind"] == "authored synthetic example; no live agent execution", "sample label missing")
    require(bool(data["shared_rules"]) and "independent verifier" in data["shared_rules"], "shared sample rules missing")
    repos = data["repositories"]
    require([r["name"] for r in repos] == ["repo-alpha", "repo-beta"], "expected the two named sample repositories")
    require(repos[0]["contract"] != repos[1]["contract"], "local contracts must remain distinct")
    owners = data["resources"]
    require(owners["git"] == {"repo-alpha": "coordinator-alpha", "repo-beta": "coordinator-beta"}, "Git owners differ from sample contracts")
    require(owners["test_runner"] == "test-owner", "test runner needs one named owner")
    sessions = {s["id"]: s for s in data["sessions"]}
    require(len(sessions) == len(data["sessions"]) == 4, "expected four distinct sample receipts")
    first = sessions["sample-incomplete"]
    require(first["process_exit"] == 0 and first["final_verdict"] is None and first["accepted"] is False, "exit zero without a verdict must remain incomplete")
    replacement = sessions["sample-replacement"]
    require(replacement["final_verdict"] == "FINDING" and replacement["accepted"] is True, "replacement review must contain the scoped finding")
    require(replacement["claims"] == ["dismiss-refresh"], "replacement claim changed")
    verifier = sessions["sample-verification"]
    require(verifier["role"] == "verifier" and verifier["reviewer_session"] is False, "reviewer must not verify its own claim")
    require(verifier["claims"] == {"dismiss-refresh": "CONFIRMED"} and bool(verifier["evidence"]), "confirmed claim requires evidence")
    final = sessions["sample-changed-review"]
    require(final["final_verdict"] == "CLEAN" and final["accepted"] is True and final["changed_scope_only"] is True, "changed scope needs its own accepted review")
    require(first["coverage"] == replacement["coverage"] == final["coverage"] == repos[0]["task"]["paths"], "declared sample coverage must match the assigned path")
    for repo in repos:
        task = repo["task"]
        require(task["owner"] == owners["git"][repo["name"]], "task and Git ownership disagree")
        require(bool(task["acceptance"]) and bool(task["paths"]), "task needs acceptance and scope")
        handover = data["handover"][repo["name"]]
        require(handover["state"] == task["state"] and bool(handover["unproved"]), "handover needs current state and proof limits")


def materialize(data: dict, output: Path) -> Path:
    # Refuse existing paths, including dangling links; never overwrite a demonstration.
    require(not output.exists() and not output.is_symlink(), "output must be a new path")
    destination = output.resolve()
    kit = HERE.parent
    require(not destination.is_relative_to(kit), "output must be outside the toolkit checkout")
    require(destination.parent.is_dir(), "output parent must already exist")
    destination.mkdir()
    (destination / "shared-rules.md").write_text("# Shared sample rules\n\n" + data["shared_rules"] + "\n", encoding="utf-8")
    for name, value in (("resource-owners.json", data["resources"]), ("lane-receipts.json", data["sessions"]), ("handover.json", data["handover"])):
        (destination / name).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    for repo in data["repositories"]:
        folder = destination / repo["name"]
        folder.mkdir()
        (folder / "AGENTS.md").write_text("# Sample local contract\n\nRead ../shared-rules.md, then this local contract.\n\n" + repo["contract"] + "\n", encoding="utf-8")
        task = repo["task"]
        text = f"# Sample task\n\nGoal: {task['goal']}\n\nOwner: {task['owner']}\n\nWriter: {task['writer']}\n\nScope: {', '.join(task['paths'])}\n\nAcceptance: {task['acceptance']}\n\nState: {task['state']}\n\n{task['optional_lifecycle']}\n"
        (folder / "TASK.md").write_text(text, encoding="utf-8")
        if repo["name"] == "repo-alpha":
            (folder / "app").mkdir()
            (folder / "app/banner.py").write_text(repo["code"], encoding="utf-8")
            (folder / "check_banner.py").write_text(repo["tests"], encoding="utf-8")
        else:
            (folder / "notes").mkdir()
            (folder / "notes/outcome.md").write_text(repo["note"], encoding="utf-8")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new directory outside the toolkit; parent must exist")
    args = parser.parse_args()
    try:
        data = json.loads((HERE / "fixtures/synthetic-sessions.json").read_text(encoding="utf-8"))
        check(data)
        destination = materialize(data, args.output) if args.output is not None else None
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Synthetic example: FAIL ({exc})", file=sys.stderr)
        return 1
    print("Synthetic example: PASS (2 repositories; 1 incomplete lane; 1 confirmed claim)")
    if destination is not None:
        print(f"Created: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
