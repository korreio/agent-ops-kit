# Two repositories, one explicit collaboration

This is an authored synthetic walkthrough. Names, records and code are invented. It demonstrates a review/recovery sequence; it is not evidence of a live agent session or a production fix.

From the kit root, using the stock macOS Python 3.9 or anything newer:

```sh
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/agent-ops-demo.XXXXXX")"
python3 examples/check.py --output "$sandbox/demo"
```

`verify.sh`, the Codex launchers and native Codex targets need Python 3.11+: on a stock Mac, run `brew install python` or use a python.org installer, then check `python3 --version`.

Reads: the shipped `fixtures/synthetic-sessions.json`. Writes: only the new explicit output directory, shared operating rules, two invented repository folders and their sample contracts, task records and tiny files. It refuses an existing output path. It never calls a provider, creates Git repositories, installs configuration or reads private memory. Omit `--output` for a read-only fixture check. Expected output is in [expected results](expected-results.md).

| Step | repo-alpha | repo-beta | Who decides? |
|---|---|---|---|
| Name authority | Local contract assigns one writer path | Different local checklist | Each repository coordinator |
| Hold resources | Coordinator owns Git, named test owner runs checks | Its own coordinator owns Git | Explicit resource record |
| Handle failed lane | Exit zero but no final verdict: incomplete | Explain the receipt and preserve partial work | Coordinator |
| Verify claim | Replacement reviewer claims dismissal starts refresh | Independent verifier checks the trigger | Verifier, not reviewer |
| Correct cause | Dismiss clears only the notice | Handover names checked and unproved work | Assigned writer then coordinator |
| Review change | Fresh reviewer checks corrected path | Local checklist remains independent | Reviewer |

A Warmboot-style task state is optional in repo-alpha; repo-beta uses a short checklist. Both can use an observable adapter. Neither requires installing Warmboot or sharing machine configuration. The generated folders are examples, not copies of either project.

Inspect the generated files, then run the tiny deterministic behavior example from its own directory:

```sh
cd "$sandbox/demo/repo-alpha"
PYTHONDONTWRITEBYTECODE=1 python3 check_banner.py
```

Expected: `repo-alpha: PASS`. It imports the invented local module, clears the notice in a new state value, starts zero refreshes and preserves the input state. It writes no application data; bytecode writing is disabled by the shown environment variable. No real UI or provider behavior is exercised.

For a useful variation, edit a copy of the sample lane receipt so `process_exit` is zero while `final_verdict` stays null: it must still be classified incomplete. A complete report with limited coverage stays bounded to that coverage. A reviewer's claim does not become a confirmed finding until a different verifier supplies evidence. Do not turn these sample labels into automatic approval policy.

Recovery: the fixture checker creates no output without explicit `--output`. If materialization fails, preserve the error, inspect the named scratch directory and retry with a new output path. Remove only the exact scratch directory you created after inspection.
