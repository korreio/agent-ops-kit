---
name: cross-review
description: >-
  Get an adversarial, read-only review of a code change, plan, commit, or working tree from a
  DIFFERENT model family than the package writer — Codex (via the installed review launcher) —
  launched non-blocking, with a shared brief and JSON finding schema, then VERIFIED before
  anything is relayed or fixed. Use at the review stage of every code change, sized to the job
  (one reviewer for a small change, a three-reviewer panel for a big one), for a plan or prose
  package its repository sends to review, after a fix batch (resume where supported), or
  when the user asks for a second opinion / "ask codex".
argument-hint: "[plan <path> | diff [<base>] | commit <sha> | tree] [focus…]"
---

# Cross-provider adversarial review

**Roles.** The delegate is a §-style *worker*: read-only, no git writes, no test wrappers, no
singleton artifacts, no conversation context beyond the brief. The coordinator (you) owns the
brief, verification, fixes, Git and the record. Repository rules win over this skill:
Codex reads `AGENTS.md` from the repository. Supply the repository contract and materialized
context paths in the brief; the delegate does not inherit the coordinator's conversation.

**When (standing order 3).** Every code change is reviewed, sized to the job: small, one
reviewer; ordinary, one fresh own-family reviewer plus another family when one is reachable; big
(substantial, lifecycle or cross-owner), the panel below. Standing order 3
sizes the review of a plan or other prose. In plan mode, a fresh reader runs orchestration reference
§8's readiness check, and the coordinator budgets the verification of every gap before anyone acts
on it.
Where no real proof is possible the review gets tougher (standing order 7): name what went
unproved in the brief.
The rule is standing orders 3 and 7; models and efforts are in
`roster.md` in the supplied toolkit directory and nowhere else.

**The panel (big packages, a trial).** One round is three reviewers launched in parallel on one
candidate: the `reviewer-deep` and `reviewer-wide` agents (the two own-family tiers) and the
other-family reviewer of section 3. Then the `verifier` agent, which was none of them, tries to
refute every claim and checks the proposed fix before anything is fixed. On an ordinary change
the own-family reviewer is `reviewer-wide`.

## 1. Materialize the target (always — the reviewer never runs `git diff`)

```bash
# COORDINATOR-ONLY commands. You own Git; the reviewer is a bounded worker and no
# `git diff` form is available to it (it rewrites the index stat cache).
OUT=<scratchpad>/xreview-<name>; mkdir -p "$OUT"
git diff <base>...HEAD > "$OUT/target.patch"      # or: git show <sha> > …, or copy the plan path
```
Collect the context paths the reviewer must read: repo contract, the invariant/standards
sections the package touches, the plan, the relevant BUGFIXES/ledger entries.

## 2. Write the brief from `~/.claude/skills/cross-review/references/brief-template.md`

Fill `TARGET`, `MATERIALIZED_PATH`, `CONTEXT_PATHS`, `LOOK_FOR` (package-specific hazards first),
and `TOOL_NOTE` ("you may run `git --no-optional-locks status --short` / `git log` / `git show <rev>:<path>` /
`git blame`, never any `git diff` form" for Codex). Save as `$OUT/brief.md`. The JSON contract is
`references/finding-schema.json` (strict; `verdict` CLEAN/FINDING/BLOCKED, findings with
`file:line`, failure scenario, smallest fix, confidence and a `trigger` (what the user or the
system does to hit it, and how often; never `n/a`); `checked_clean`; `blocked`).

## 3. Launch — non-blocking, read-only

**Codex (the other-family reviewer):** use the installed `codex-review` launcher, which selects
an independent native read-only profile rather than relying on role prose. It loads the dated
roster role copy and existing unrelated user configuration. Resolve the toolkit from the supplied
location or fully resolved loader symlink; do not assume a home-directory checkout.

```bash
codex-review "$OUT" codex-r1 "$OUT/brief.md" --cwd <repo> --schema <finding-schema.json> --role reviewer --wait
```

The header of `bin/codex_job.sh` documents current behavior. Do not replace this with a legacy
sandbox command or restore a deprecated MCP-server review path. Wait for `.end`, then inspect exit,
complete events and the actual verdict. Launcher success is not review acceptance.

Keep working while the reviewer runs; poll `$OUT/*.end` and read the actual verdict in
`$OUT/codex-r1.json`. A job with no `.end` whose monitor in `.pid` is gone or no longer matches
`.monitor` (compare the line printed by exactly `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=`,
which plain `ps` in another time zone or language would not reproduce) is lost: completion is unconfirmed, any result already written is not proof, so use the fresh-reviewer fallback. `--wait` reports it
as `class=lost`; the launcher header gives the exact rule.
Every attempt permanently owns its job name in that output directory, including failed
attempts. Use a fresh name for each retry or round and inspect that attempt's matching paths.

## 4. Collect → verify → converge

1. A failed, partial or no-verdict run earns no completed-review credit; use standing order 5's
   required permitted fallback. Read the actual exit, complete events and scoped final result.
   A failed lane grants no authentication or permission changes; existing parent restrictions apply.
2. `git status --porcelain` must be unchanged by review jobs (a coordinator-only check — the
   reviewer runs no git command of its own beyond the read-only allowlist in the brief template).
   For reviewer status reads use `git --no-optional-locks status`: plain status can refresh and
   write the index. See [Git status background refresh](https://git-scm.com/docs/git-status#_background_refresh).
3. For every finding: the verifier (on a panel, the `verifier` agent; otherwise you, if you were
   not a reviewer) opens the cited lines and decides **CONFIRMED / REFUTED / DOWNGRADED** with one
   line of evidence, and checks the proposed fix. Different families find different defects and each misses some —
   unanimity and silence are both weak signals; only verification counts.
4. Dedupe across reviewers; present confirmed findings in the repo's vocabulary
   (`CLEAN` / `FINDING` / `BLOCKED`) and list refuted ones briefly so the cost is visible.
5. One fix batch goes to a writer (you or a lane), then the test tiers, then a review of what
   changed (standing order 7). Resume the earlier other-family reviewer **on the
   same thread** (`codex-review "$OUT" codex-r2 … --resume <thread>`) with fresh job names only,
   while it is still the other family for that batch and its launcher supports resume; otherwise
   launch a fresh reviewer that carries the previous brief, confirmed findings and fix scope, and
   record it as fresh. There is no round count; standing order 7 says what follows when the same
   thing has failed twice. A repository's own stop rule holds where the two differ. Never let the
   reviewer patch its own finding.

## 5. Record

One line per round where the repo keeps review evidence (plan row, ledger, changelog), in the
format of the orchestration reference, section 5:

```text
review <package> r<N> <YYYY-MM-DD>: reviewers=<role@family, …> raised=<n> confirmed=<n> downgraded=<n> refuted=<n> minutes=<n> unproved=<tier or none> result=<CLEAN|FINDING|BLOCKED>
```

Thread ids go beside it when a re-review will resume them. Roles and families, not model names.

## Roles and models

The roster decides the model and effort of every role; this skill names roles only, and its one
pinned launcher example is a copy that `tests/test_roster.sh` checks. Choose a reviewer family
other than the package writer's when one is reachable. If none is, an own-family fresh-context
reviewer that is not the writer closes the round and the record says same-family.

## Failure policy (owner rule)

A delegate failing — timeout, quota, denied permission, schema error, plugin not ready — never
stops the work. Continue with the remaining other-family reviewer, or fall back to an eligible
fresh-context reviewer that is not the package's writer (a Claude subagent in a new context
qualifies; your own re-read of a package you wrote does not count as the required independent
review); say in the report exactly which lane failed and what was therefore not covered, and
tell the owner.
Never silently skip, never halt the job waiting for a fix.

## Don'ts

No bypass flags for reviews; no delegate git/test/singleton mutation; no Stop-hook auto-review
loops (drains quota); no relaying unverified findings; no MCP tool for long runs; no secrets in
briefs.
