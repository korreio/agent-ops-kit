# Orchestration reference

How-to, not rule text. The rules are the standing orders ([`standing-orders.md`](standing-orders.md))
and each repository's own contract. This file keeps four things a coordinator looks up: the format
of the one line per review (section 5), the launchers (section 6), the install terms (section 7)
and the plan shape (section 8). The section numbers are kept because repositories cite them. Model
names are in the [roster](roster.md) and nowhere else.

## 1. Job shapes

Now standing order 1.

## 2. The review rule, complete

Now standing orders 3 and 7.

## 3. Evidence ladder

Now standing order 7; each repository's contract says which proof a change owes.

## 4. Lanes

Now standing orders 1, 4 and 5.

## 5. The round record

One line per round, appended by the coordinator where the repository already keeps review evidence
(a plan row, a ledger, its changelog):

```text
review <package> r<N> <YYYY-MM-DD>: reviewers=<role@family, …> raised=<n> confirmed=<n> downgraded=<n> refuted=<n> minutes=<n> unproved=<tier or none> result=<CLEAN|FINDING|BLOCKED>
```

`reviewers` names roles and families, not models; the roster of the day supplies the models.

## 6. Launching the other family

The launchers are on PATH (`codex-review`, `claude-review`); each one's header says
what it caps, streams and classifies. The coordinator pins on every call the model and effort of
the roster row the lane fills. `$OUT` is a scratch directory outside the repository, and the
finding schema is
`claude/skills/cross-review/references/finding-schema.json` under the supplied toolkit directory.
From a Claude coordinator the other-family reviewer is:

```bash
codex-review "$OUT" codex "$OUT/brief.md" --cwd <repo> --schema <finding-schema.json> --model gpt-6.1-sol --effort high
```

and from a Codex coordinator:

```bash
claude-review "$OUT" claude "$OUT/brief.md" --cwd <repo> --schema <finding-schema.json> --model opus --effort high --max-turns 60 --timeout 20m
```

Where a repository forbids another provider's lane in its checkout, the coordinator points `--cwd`
at an export of the candidate in a scratch folder instead: the exact bytes under review, as a
`git archive` of the candidate's commit where it is committed, or of HEAD plus the pending patch
where it is not. The coordinator records which, and that repository's rule stays as it is. Where a
repository's contract authorises no network effect at all, the other family is not reachable there
and the coordinator records the round as same-family.

A Codex coordinator launches its own-family tiers (the roster's `reviewer-deep` and
`reviewer-wide` rows) as its platform's own subagents or as further `codex-review` calls pinned to
those rows. Claude reviewers use file-reading tools; supply materialized Git, shell and test
evidence in the brief. Codex reviewers retain a shell under their native read-only profile, whose
configuration turns command network off.

**Repository configuration.** On all four launchers a repository already trusted loads natively
and an unseen one does not run its project configuration. Lookup checks `--cwd`, its physical path
and the nearest folder holding a .git entry, walking up from the physical path without following
that entry or invoking Git. `--no-project-config` forces exclusion,
`--project-config` forces native loading, and both together is a usage error. In excluded mode the
lane reads `CLAUDE.md` or `AGENTS.md` with its tools. The launch line and the `<job>.project-config`
receipt give `on` or `off`, then a reason, and the coordinator reads that receipt.
`--project-config`, and any lane in a trusted folder, runs repository configuration with the user's
rights; no mode makes a lane safe for untrusted code. See
[potential issues](../docs/potential-issues.md).

**Time limits and cancelling.** Both launchers default to a 10m watchdog for a review and 60m for a
writer, with a 300 s floor; `--timeout` changes it. Every identity the launchers record and every
check of one is the line printed by exactly `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=`; plain
`ps` follows the caller's time zone and language. Only while `<job>.end` is absent and the live `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` equals `<job>.monitor`, on either family, send TERM to the monitor
in `<job>.pid`, which stops the provider and writes the receipts; a provider that ignores TERM runs
on until the watchdog. Codex also keeps a direct route: re-read `<job>.codex.pid` and send TERM to
its pid only if the live `LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` equals its line 2; an `unrecorded:`, missing
or short file means do not signal.

**Lost jobs.** A job whose monitor died never writes `<job>.end`. While `.end` is absent, on either
family, the job is lost only on proof: `<job>.monitor` holds a recorded identity and the live
`LC_ALL=C TZ=UTC0 ps -p <pid> -o lstart=,comm=` for the pid in `<job>.pid` prints another line, or `ps` prints
nothing (or `.monitor` is `unrecorded:`, empty or missing) and `kill -0 <pid>` says No such process, and
`.end` is still absent after that check. A refused `ps` or `kill` means cannot tell: keep waiting.
For a lost job `.end` is absent and completion is unconfirmed: an `.exit` or result.json already written is not proof, and the fresh-reviewer fallback applies. The check signals nothing.
`--wait` does it and prints `class=lost`.

**When the other family writes.** It does so when the coordinator decides it, and when the same
thing has failed twice (standing order 7), through its writer launcher:

```bash
codex-write "$OUT" <job> "$OUT/brief.md" --cwd <repo> --model <model> --effort <effort>
claude-write "$OUT" <job> "$OUT/brief.md" --cwd <repo> --model <model> --effort <effort>
```

The pins are in the roster. The lane is a worker under standing order 4: it never touches Git and
it runs a repository's test wrappers only under that repository's lease. A lane that can run code
is not isolated, so the coordinator records HEAD, the index, the branches and the stashes before
the launch, and checks after it that they are unchanged, that only files in scope were touched and
that no process was left running. A Claude writer launched by a Codex coordinator inherits that
coordinator's sandbox: it needs a writable repository, the network and the existing login from it,
and no flag of the launcher widens that. Where the parent cannot give that, or a repository
forbids another provider's lane in its checkout, the writer lane is not reachable there.

## 7. Installs

The detail behind standing order 11.

- An install is adding a tool or package that the repository's own setup does not already declare;
  running that setup as documented is not one.
- Forms, lightest first: run once (the manager fetches and runs it; nothing joins an environment);
  the task's own environment (a directory the task owns: the repository's environment or a scratch
  directory); machine-wide (anything else; the coordinator's only).
- Seven days counts for a version the role selects, not for one the owner or the repository names.
- A machine-wide install is one transaction: the coordinator names beforehand the packages it will
  add, sets `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1` and
  `HOMEBREW_NO_AUTOREMOVE=1` where the manager is Homebrew, and stops and reports if anything else changes.
- One use is a directory the task created for a run-once tool or a throwaway environment, its path
  recorded at creation. Clean-up removes that path and nothing else: no cache, no machine-wide
  tool, no package-manager clean, prune or autoremove. Where the repository's rules for discarding
  work need an approval the coordinator does not have, it leaves the directory and reports its
  path.
- This order removes the role's question; it cannot remove a prompt the platform itself raises.

## 8. Plan shape

A plan lets a fresh session carry out and check the work without redoing the exploration or
deciding what the plan should have decided. Work whose change fits one sentence needs no plan,
and text work keeps its plan in proportion. Length and layout follow the work: the outline at the
end is a suggestion, and a heading with nothing to say is left out. A repository adds only its
particulars (where plans live, header lines, its Close lines and evidence); older plans are not
retrofitted.

**Start from the brief.** Before writing, the coordinator reads what the repository's contract
routes it to, restates the brief and what done looks like in the owner's words, inventing nothing,
and asks the owner-only questions (standing order 1).

**Draft until ready.** A plan is a draft until every exploration result is in it and its review
has passed (standing order 3); until then it says draft at its top, below any frontmatter the
repository requires, and names what is missing.

**What a ready plan usually holds.** Optional guidance, not a form: use what the work needs. Readiness
is decided by the review below, not by the list. A repository's own required duties still apply.

- **Goal and done:** the brief restated in the owner's words, inventing nothing; what a user, the owner or a named check
  sees when it works; what is out of scope, including behaviour that must not change.
- **Decisions:** owner rulings and design choices with their reasons; assumptions and what
  changes if one is wrong; the questions for the owner, highest impact first, one decision per
  question in plain words, each with a recommendation and its reason (standing order 1).
- **Current state:** verified facts with where they were read (`path:line`, commit, date); what
  was not verified; for each finding, change, keep or defer, with the reason.
- **Packages,** each naming: the files, symbols, consumers and documented contracts it touches,
  and the concrete change; the existing component or helper it reuses; behaviour kept and
  behaviour deliberately changed; prerequisites and order; the tests by file, case and expected
  result, including the failure case; the documentation sections and what changes in them, or
  why none; the evidence it owes, how it runs and what stays unproved; rollback where it reaches
  production or data. Text and research work names its documents, sources and acceptance checks
  instead of code tests.
- **Unknowns:** each as a bounded investigation with a success test and the packages it blocks,
  not a guess.
- **Status:** the next action; each package's state, with failed fix batches for standing order
  7's stop; a Close list of the duties the change owes, each naming the rule that owns it.
- **Log:** dated history. What is still true moves up in the same session.

Link the rules a plan relies on instead of copying them. A discovery or scope change updates the
plan before the next package starts.

**Review.** The reviewer writes the brief for the plan's next unfinished package from the plan and
its named sources alone, and checks against source the claims that package rests on. It reports
each point where it would have to rediscover or decide something, and each documented contract or
consumer a step would break. A plan finding's trigger is the step
that, followed as written, goes wrong.

Suggested outline: Now · Goal and done · Decided · Open · Current state · Design · Packages ·
Close · Log.
