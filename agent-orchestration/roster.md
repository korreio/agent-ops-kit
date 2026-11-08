# Roster

The one place a model is named. Standing order 2 sends every role here; rules, skills, briefs and
memory name roles only. Claude and Codex agent definitions, the Codex coordinator config copy and pinned launcher examples are copies
of these rows, and `tests/test_roster.sh` fails when a copy differs.

Last checked: 2026-11-08. These rows and owner notes show the author's dated sample configuration, not a recommendation or provider ranking.
Native copies are checked by `tests/test_roster.sh`; a freshness notice after 14 days asks the
owner to inspect available models. Recheck the selections before changing this date; installation alone does not refresh the evidence. Trial rows have limited historical evidence and remain
replaceable. No kit fixture calls a paid model or validates provider availability.

An agent that belongs to one repository has no row here: that repository names its role and
the coordinator chooses the corresponding row.

Claude Code models are aliases (`opus`, `sonnet`, `haiku`, `fable`) that follow the vendor's
current model. Codex has no alias, so its names are concrete.

## Claude Code

| Role | Model | Effort | Agent | Status |
|---|---|---|---|---|
| coordinator | opus | xhigh | - | set by the owner in the session picker, the level below Max |
| explorer-locate | haiku | medium | explorer-locate | enumerate or locate |
| explorer-trace | sonnet | high | explorer-trace | trace with judgment |
| writer | opus | xhigh | writer | sonnet on trial for a well-specified package, passed per lane |
| writer-takeover | opus | max | - | the lane that rethinks a piece in a takeover (standing order 7): the `writer` agent with this effort set for the launch; set by the owner on 2026-10-11 |
| designer | opus | max | designer | trial |
| reviewer-deep | opus | max | reviewer-deep | trial |
| reviewer-wide | sonnet | high | reviewer-wide | |
| verifier | opus | high | verifier | |
| relay | haiku | low | relay | log extraction, mechanical relays |
| rule-reviewer | opus | high | rule-reviewer | contract and rule edits |
| reviewer-other-family | opus | high | - | launched by a Codex coordinator through `claude-review` |

`fable` is not routine: owner-requested hard design or adjudication only.

## Claude Code aliases

What each alias ran as when the roster was last checked, measured with one small call per alias.
The session-start check (`claude/hooks/roster-freshness.sh`) compares recent lanes with this table.

| Alias | Resolved |
|---|---|
| opus | `claude-opus-5-5` |
| sonnet | `claude-sonnet-5-5` |
| haiku | `claude-haiku-5-5` |

## Codex

| Role | Model | Effort | Status |
|---|---|---|---|
| coordinator | gpt-6.1-sol | high | everyday |
| reviewer | gpt-6.1-sol | high | everyday; the other-family reviewer for a Claude writer |
| reviewer-deep | gpt-6.1-sol | xhigh | demonstrably difficult review; the deep reviewer when Codex is the writer's family |
| reviewer-wide | gpt-6-luna | high | trial; the wide reviewer when Codex is the writer's family |
| writer-bounded | gpt-6.1-sol | medium | bounded implementation |
| writer-takeover | gpt-6.1-sol | xhigh | the lane that rethinks a piece in a takeover (standing order 7); set by the owner on 2026-10-11 |
| escalation | gpt-6-astra | high | one bounded escalation when a consequential claim stays contested; kept at high by the owner on 2026-10-11 although the vendor's guidance starts this model at low; unmeasured here |

A role with no Codex row (explorer, designer, verifier, relay) runs at the Codex coordinator row
until a measured run gives it its own. `writer-bounded` and `writer-takeover` are writer roles;
`escalation` is a reviewer role. The native Codex agent files and coordinator config are tested copies of these rows; see `codex/README.md`.

`~/.codex/config.toml` is a per-Mac file outside this package. The owner sets its default model
and effort to the coordinator row; a session changes that file only with explicit authorization for that exact
change.

## Across families

| From | Row | Launcher call pins |
|---|---|---|
| Claude | codex:reviewer | `--model gpt-6.1-sol --effort high` |
| Codex | claude:reviewer-other-family | `--model opus --effort high` |

A writer lane for the other family (`codex-write`, `claude-write`) is pinned at that platform's
writer row: `writer-bounded` for Codex, `writer` for Claude Code. The lane that rethinks a piece in
a takeover, writing or designing, is pinned at the `writer-takeover` row of the platform that runs
it; a writer that implements its design is at its ordinary writer row.
