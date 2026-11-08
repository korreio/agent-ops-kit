# Verification and limits

Local validation recorded on **7 November 2026**, on macOS 27.2 arm64 with Bash 5.3.20 and /bin/bash 3.2.57, Python 3.14.7 and jq 1.7.1. Python 3.11+ is required by the standard-library TOML helpers.

## Reproduce the fixture checks

From the repository root, with Bash, Python 3.11+ and jq on PATH:

```sh
./verify.sh
```

The command reads shipped code and synthetic fixtures, creates disposable test homes and fake providers, and runs no paid model calls or installation into the real user environment. A passing process is not evidence beyond the suite's named cases.

| Owning suite | Recorded local result |
|---|---|
| `agent-orchestration/tests/test_roster.sh` | 59 passed, 0 failed |
| `agent-orchestration/tests/test_launchers.sh` | 593 passed, 0 failed |
| `agent-orchestration/tests/test_install_memory.sh` | 172 passed, 0 failed |
| `agent-orchestration/tests/test_install_claude.sh` | 290 passed, 0 failed |
| `agent-orchestration/claude/hooks/test_hooks.sh` | 739 passed, 0 failed |
| `agent-orchestration/tests/test_codex.sh` | Passed; native hooks, eight role/path cases and control-character round trips |
| `agent-orchestration/tests/test_install_codex.sh` | 133 checks passed |

All seven suites have passing results recorded above. The launcher total includes the integration regressions and five native process checks run with host process visibility. Hosted results must be assessed separately for the exact commit.

The synthetic example passed its read-only fixture check and disposable materialization. The published memory/adoption recipes were exercised with scratch homes and fake providers, including spaces in paths, note preservation, repeat application and canonical-store aliases. Content checks passed for local links, matching contributor loaders, declared executable modes, text formats and the bounded CI policy.

## Hosted fixture evidence

The [Hermetic checks workflow](https://github.com/korreio/agent-ops-kit/actions/workflows/ci.yml) runs the complete verification entry point on disposable macOS runners with Python 3.11 and 3.14. Use a successful run for the commit you are assessing; the workflow link alone is not execution evidence.

## Live observations

Recorded on 1 November 2026 with Claude Code 2.1.316 and Codex 0.166.0, using synthetic repositories whose hooks and MCP servers only touch a marker file. Each is one observation of one version, not a guarantee.

| Launch | Repository code ran | Trust written | Note |
|---|---|---|---|
| `claude-review`, unseen repository | No | Not applicable | Receipt `off` |
| `claude-review --project-config` equivalent, native loading | Yes: hook and MCP server | Not applicable | Observed before the default changed |
| `claude -p` with `--setting-sources user` | No | Not applicable | Subscription login kept working |
| `codex-write`, unseen repository | No | No | Receipt `off unseen` |
| `codex-review` after that writer | No | No | Receipt `off unseen` |
| `codex-review --project-config`, unseen repository | Yes: MCP server | No | Receipt `on flag`; the override did not persist |
| `codex exec -s workspace-write`, no kit | Yes: MCP server | Yes | Native Codex behaviour |

The Codex review lane's command network was off (`curl` failed) and the writer lane's was on. In a scratch home under `codex sandbox`, the review profile denied 11 planted files across its literal list and left `password`, `.env.test`, `.env.example` and an ordinary file readable, as configured. A repository's `"disableAllHooks": true` turned off a flag-supplied hook under native Claude loading. Negated template rules in the Claude deny list worked: `.env.example` was readable and `.env.local` denied.

A further live check on 8 November 2026 ran each review launcher once in an unseen synthetic repository, on Claude Code 2.1.319 and Codex 0.167.0: both classified success with a schema-valid verdict, recorded `project-config` `off unseen`, read the repository rules with their tools, and Codex wrote no trust entry.

## Outsider runs

On 1 November 2026, four outsider persona runs exercised an earlier commit on Claude Code: a newcomer, a security researcher, a team lead adopting and undoing the kit in a seeded home, and an open-source maintainer. They ran under an outer macOS Seatbelt boundary and with customizations off, proved with sentinels. The team lead's home returned byte-identical. One Codex run did the same kind of evaluation, but it does not count as context-clean: Codex loaded the owner's global instructions, and no supported option excludes them. Its filesystem boundary was enforced.

On 7 November 2026, a newcomer and a security researcher ran again on a fresh clone of the published history, with the isolation re-proved on Claude Code 2.1.319. The newcomer found no defect; the researcher found no code-execution or injection defect and two guard gaps. Those gaps, and an independent review's `--timeout` finding, are fixed in this tree. The outsider runs have not been repeated after those fixes.

## Evidence limits

Checked with fixture suites, independent source review and the dated live observations above. Live agent behavior beyond those observations is not proved.

Historical probes in [compatibility](compatibility.md) are dated observations. These checks establish neither native host containment, Linux/Windows support, second-Mac parity, productivity gain, general security assurance nor future model behavior.
