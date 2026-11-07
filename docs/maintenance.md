# Maintenance and local records

A useful component stays small, explainable and removable. Read [contribution guidance](../.github/CONTRIBUTING.md) before changing the kit; consumers can adopt individual components independently.

## Change one owner

1. Name the failing user action and the component that owns the cause.
2. Check the installed interface when a vendor CLI, SDK or operating-system behavior may be responsible. Use official release notes/issues and record the bounded result.
3. Change the owner and its meaningful regression cases. Preserve other workers' files, Git and resource leases.
4. Run the owning checks with scratch homes and fake providers. Record the exact candidate, environment, pass/fail/skip counts and limits in [verification](verification.md).
5. Obtain the repository's risk-sized fresh review, independently verify every claim before fixing it, and record the dispositions with the change. Review only changed scope after corrections.
6. Inspect content, links, modes and the exact staged bytes before a scoped commit. Private output and provenance remain outside the checkout/history.

If the same piece fails twice, rethink the design from before the patches with a different writer/design direction. Do not keep layering guards. Failed tooling is recorded and replaced by a permitted fallback where possible; missing evidence is never clean.

## Checks

From the kit root, the verification entry point documented in [verification](verification.md) runs the seven owning suites plus focused content/example checks. Requirements and exact results belong there. Individual suites live under `agent-orchestration/tests/`, with Claude hook cases in `agent-orchestration/claude/hooks/test_hooks.sh`. They use synthetic data and fake providers; no paid model call or real-home installation is a prerequisite. `tests/check_content.py` checks tracked files and untracked files no ignore rule covers, so an ignored `.DS_Store` or log passes and a new text file does not escape. A source archive with no `.git` is scanned as a tree instead, and a checkout whose files git cannot list fails.

Changing roster selections requires updating the native copies and running `test_roster.sh`. Changing a linked target can affect future installed sessions immediately; copied native files instead require explicit reconciliation. Test exact permission behavior on supported native versions before advertising it as current live evidence.

## Optional local ledger

`agent-orchestration/bin/session_ledger.py` is an optional read-only local report over Claude session records and Codex rollouts. It may print project names, brief excerpts, roles, usage and dated cost estimates. Run it only when this private access is appropriate, and keep output outside the kit and public repositories.

It uses standard-library Python, reads native local session locations and writes no report file itself. Inspect its header and parsing before use. With an empty synthetic home it has no real sessions to summarize; absence of rows does not mean no work happened. Headless launcher transcripts may be missing from one provider's native records, and formats can change. Codex tokens are priced in credits at dated rates, never added to dollars. Historical list prices and credit rates are proxies, not billing or quota accounting. The public [synthetic sessions](../examples/fixtures/synthetic-sessions.json) explain the distinction between activity and accepted evidence; they are not a real usage ledger.

Omit the ledger when the privacy cost or incomplete accounting outweighs its value. A parser update should be checked on synthetic records first. Never copy real transcripts into a bug report; describe the failing shape with a minimal invented fixture.

## Recovery and boundaries

Keep reviewed toolkit versions, configuration backups and external private stores separately recoverable. An installer backup is not a backup of all subsequent work. Stop writers and compare before restoring. For memory conflicts, follow [manual preservation](memory.md#manual-migration-and-undo).

The kit adds no background copying, account management or automatic release process. A separate manual clone/workflow remains the owner's choice. Report vulnerabilities through [the security policy](../.github/SECURITY.md), and ordinary bugs/questions through the issue forms without sensitive content.
