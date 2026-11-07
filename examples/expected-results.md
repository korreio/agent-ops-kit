# Expected results — authored samples

From the kit root:

```text
python3 examples/check.py
Synthetic example: PASS (2 repositories; 1 incomplete lane; 1 confirmed claim)
```

With `--output /absolute/new/scratch/demo`, a second line names that output directory. It contains:

```text
demo/
  shared-rules.md
  resource-owners.json
  lane-receipts.json
  handover.json
  repo-alpha/
    AGENTS.md
    TASK.md
    app/banner.py
    check_banner.py
  repo-beta/
    AGENTS.md
    TASK.md
    notes/outcome.md
```

The checker accepts exactly two distinct local contracts, distinct Git owners, a named test owner, an exit-zero incomplete review, a replacement finding, independent confirmation, a changed-scope clean review and handover with explicit limits. It checks fixture consistency rather than calling any agent.

From the generated `repo-alpha` directory:

```text
PYTHONDONTWRITEBYTECODE=1 python3 check_banner.py
repo-alpha: PASS
```

That check proves only the tiny synthetic state transition. The displayed lane receipts, review labels, resource ownership and handover are invented teaching records, not historical or live proof.
