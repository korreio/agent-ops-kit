# Agent tooling reference

A macOS-focused set of optional components. Start with the [root guide](../README.md), then
choose the smallest part that addresses the task. Nothing here starts background synchronization
or requires installing every adapter.

| Component | Why and how | Use, omit or adapt | Effects and recovery |
|---|---|---|---|
| [Standing orders](standing-orders.md) | Shared coordinator/worker duties | Read manually; link only if wanted across repositories | Instruction changes affect future sessions; retain stricter repository contracts |
| [Roster](roster.md) | One dated sample role/model table with checked native copies | Replace pins to match available paid models | Update matching copies and run roster checks; availability is not tested |
| [Reference](orchestration-reference.md) | Review sequence, receipts, launch examples and plan checks | Use with existing repository task records | It grants no Git or test lease |
| [Repository alignment task](repository-alignment-task.md) | Checklist for aligning one repository's instructions with shared rules | Give it only for a named disposable or owner-authorized repository; omit when its contract already suffices | Grants no installation or enrollment; proposed edits and rollback go in that repository's task record |
| `bin/` adapters | Observable provider-specific review/write lanes | Choose the provider already authorized | Outputs may be private; preserve outside Git, inspect end/exit/verdict, cancel only the recorded live process |
| `claude/hooks/`, `codex/hooks/` | Pattern checks for common accidental operations | Optional native hooks, not security proof; they catch mistakes and a [repository can switch them off](../docs/potential-issues.md#guards-catch-mistakes-not-repository-content) | Pre-tool guards fail closed when no parser is available; advisory hooks stay non-blocking; a hook that crashes, times out or cannot start lets the call proceed |
| [Memory guidance](memory/README.md) | Explicit private external note placement | Claude project-memory layout only; omit if local notes suffice | One active writer, conflict refusal, manual preservation before migration |
| `install.sh` | Preview and opt-in links/copies/config merges | Choose exact targets, scratch home first | Backup before replacement; reconcile conflicts, restore only exact affected paths |
| `bin/session_ledger.py` | Optional local session accounting | Inspect synthetic records first; omit for private logging concerns | May print private messages/briefs; keep real output outside the checkout |

## Launching and interpreting lanes

Before live use, read the [startup, trust and data issues](../docs/potential-issues.md).

The launcher headers are the command references. `claude-review` selects plan mode and makes
`Read`, `Grep` and `Glob` available and preapproved. Its `--tools` accepts only nonempty subsets
of those exact case-sensitive names. Names may be separated by commas or ASCII spaces; mixed
separators work, duplicates are canonicalized, and empty comma fields, leading/trailing
separators, control whitespace, missing values and repeated options are refused before startup.
For example, `--tools 'Read, Grep'` and `--tools 'Glob Read'` are valid. Supply materialized Git,
shell, test and resolved link-target evidence in the review brief. Inherited native settings,
startup hooks and configured MCP tools still need inspection; this built-in tool restriction
is not host containment.

`claude-write` retains acceptEdits, its explicit built-in tool list and optional Bash rules.
`codex-review` selects a native read-only profile with shell access and command network off; it
refuses writer roles and `--sandbox workspace-write`. Choose `codex-write` explicitly for
workspace editing; its profile keeps command network. The two reviewers therefore have different
tool capabilities; [results parity](../docs/design.md#results-parity) lists where the platforms
differ and why. Native role words alone do not enforce access controls. See
[upgrade effects](../docs/adoption.md#upgrading-an-earlier-linked-installation).

**Repository configuration.** On all four launchers a repository you have already trusted loads
natively and an unseen repository does not run its project configuration. Claude's trust comes
from `hasTrustDialogAccepted` in `~/.claude.json`, Codex's from the `projects` table in its
`config.toml`, following `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. Lookup checks `--cwd`, its physical
path and the nearest folder holding a .git entry, walking up from the physical path without
following that entry or invoking Git. The launchers never write either trust file, and a missing
or unreadable one counts as unseen. `--no-project-config` forces exclusion,
`--project-config` forces native loading, and both together is a usage error. The launch line and
the `<job>.project-config` receipt give `on` or `off`, then a reason: `trusted`, `unseen`,
`unreadable-trust` or `flag`, and on Codex `untrusted`. In excluded mode a lane reads `CLAUDE.md` or
`AGENTS.md` with its tools. `--project-config`, and any
lane in a trusted folder, runs repository configuration with your rights. Through the launchers no
trust entry is written, even with `--project-config`; a direct `codex exec -s workspace-write` in an
unseen repository, outside them, can trust it permanently. An interactive session is outside
the launchers altogether. Exclusion does not make a lane safe for untrusted code. See
[potential issues](../docs/potential-issues.md).

The Claude display guard intentionally matches `.env.*`, including harmless names such as
`.env.md`; template suffixes `.example`, `.sample`, `.template` and `.dist` are exempt. It is a
heuristic with false positives that catches mistakes; it is not a boundary. Pre-tool guards fall
back from jq to Python and fail closed, with an actionable message, if neither parses their input.
Advisory hooks stay non-blocking. Codex's shared-guard wrapper resolves its link in the shell, so
jq alone is enough there too, and any failure in it blocks.

From an authorized repository working directory, with an external output directory and brief:

```bash
# OUT and BRIEF are absolute paths outside the checkout; launchers must already be on PATH.
codex-review "$OUT" check "$BRIEF" --cwd "$PWD" --role reviewer --wait
```

This reads the brief and candidate through the chosen CLI and writes run receipts under OUT;
it may consume paid usage. It does not authorize account changes. A fixture-only alternative is
`bash agent-orchestration/tests/test_launchers.sh` from the kit root: it uses fake providers and
scratch homes, never a model call. Expected result is a zero-failure test summary.

Use a fresh job name or output directory for every attempt, including retries and resumed
threads. Receipt prefixes stay reserved: `review` conflicts with `review.result` and `Review`;
`review.one` and `review.two` remain separate. Previous receipts are preserved.
Use a new output directory when upgrading launchers; do not mix versions in one directory.

Both families write a normalized `<job>.result.json` that distinguishes successful schema output
from refusal, timeout, no verdict and failed authentication, with the same class names and exit
numbers. Claude also reports `partial` and `limit`; Codex produces neither, because `codex exec` has
no turn cap and no provider limit text has been observed, and it adds `thread_busy`. Codex keeps raw
events and thread identity beside it. Both have a watchdog, 10m for a review and 60m for a writer by
default, with a 300 s floor. Process exit zero alone never accepts a review. Preserve failed attempts, inspect the scoped verdict and have a non-reviewer
verify claims.

Every identity the launchers record and every check of one is the line printed by exactly
`LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=`. Plain `ps` prints the start time in the caller's
time zone and language, so after an automatic time-zone change, or from a shell with another
language, the same process would no longer match.

To cancel a lane on either family, only while `<job>.end` is absent and the live
`LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` equals `<job>.monitor`, send TERM to the monitor in `<job>.pid` and
signal nothing else that way. A pid that fails that match was recycled, and an `unrecorded:` line or an empty or missing `<job>.monitor` proves nothing: leave it alone. The monitor stops the provider and writes the normal
receipts, so `--wait` ends, normally as `reviewer_error`, exit 1, with a `cancelled` line in
`<job>.stderr`. Never KILL the monitor: that leaves the provider running with no receipts. A
provider that ignores TERM runs on until the watchdog.

Codex also keeps a direct route. Re-read `<job>.codex.pid`; an `unrecorded:`, missing or short file
means do not signal. Send TERM to its pid only if the live `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` equals its
line 2 (same start, command `codex`), then re-check liveness.

A lane whose monitor died never writes `<job>.end`. While `.end` is absent the job is lost only on
proof: `<job>.monitor` holds a recorded identity and the live `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` for the
pid in `<job>.pid` prints another line, or `ps` prints nothing (or `.monitor` is `unrecorded:`,
empty or missing) and `kill -0 <pid>` says No such process, and `.end` is still absent after that check. A
refused `ps` or `kill`, or a pid that is not a number, means cannot tell: keep waiting. For a lost job
completion is unconfirmed, and an `.exit` or result.json already written is not proof: the
fresh-reviewer fallback applies; signal nothing for it. `--wait` applies
this rule, prints `finished: class=lost` and exits 1. Codex also reports its child by the same rule
from `<job>.codex.pid`; Claude records no identity for its provider, so its state cannot be told.
`.end` is renamed into place whole; it is empty only when the completion `date` failed, and an
elapsed time that cannot be computed reads `unknown`.

## Optional installation

From the kit root, `bash agent-orchestration/install.sh --check` reports inventory without
applying targets. It reads local configuration metadata; existing content is not printed. For
fixture-only inspection, set HOME to a fresh scratch home with fake provider commands. Real
installation needs deliberate owner-selected targets and backup review; no command here activates
real global configuration as part of kit verification. See [adoption](../docs/adoption.md).

## Syncing the other Mac

This is a manual adaptation checklist, not a sync command or permission to enroll a checkout.
On the destination Mac, read the chosen kit version and the local repository contracts first.
A destination inventory records shell/Python versions, whether jq is on PATH, selected provider
CLI versions, whether `~/.codex/config.toml` sets `project_doc_max_bytes`, and what absent runtimes
prevent. Authentication, actual memories and private session output stay outside the transfer.

Run these independently useful fixture checks from the kit root:
`agent-orchestration/tests/test_launchers.sh`, `agent-orchestration/tests/test_install_memory.sh`,
`agent-orchestration/tests/test_install_claude.sh`, `agent-orchestration/tests/test_roster.sh`,
`agent-orchestration/claude/hooks/test_hooks.sh`, `agent-orchestration/tests/test_codex.sh` and
`agent-orchestration/tests/test_install_codex.sh`. Results on one Mac do not prove another Mac.

If the owner later chooses Claude hook/agent/rule installation, inspect the exact effects of
`--apply --hooks --agents --rules` first. Resolve differing local files manually; keep backups.
The migration record names the chosen paths and missing proof; installation covers only the
owner-selected targets.

## Keeping this package current

Recheck provider availability and role selections before updating the roster's check date; the
14-day freshness notice asks for that recheck, not installation or an automatic date reset.
Update the roster and native copies together. Launch examples with concrete model flags are
checked against the roster too. Session-ledger model identifiers belong to dated historical
pricing data and do not select launcher models. When standing orders change,
run the owning checks and review affected native instructions. Keep local links, installer
inventory and the other-Mac checklist aligned with actual shipped components. A linked toolkit
update can affect future sessions immediately; native copied roles require explicit reinstallation.
Do not turn historical probes or fake-provider tests into current live compatibility claims.
