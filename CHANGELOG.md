# Changelog

Experimental and macOS-focused. Versions are tags on `main`.

## 0.1.1 — 2026-11-08

- Live-checked both review launchers on Claude Code 2.1.319 and Codex 0.167.0. The launcher headers, [compatibility](docs/compatibility.md) and [verification](docs/verification.md) record what passed.
- `install.sh --apply` with no target now also lists the native Codex targets.
- Added this changelog and a direct link to the [three engineering lessons](docs/case-studies.md); clarified which outsider runs came before which fixes.

## 0.1.0 — 2026-11-07

First release: rules and templates for task sizing, roles, review and escalation; launchers for Claude Code and Codex review and writer lanes with observable receipts; optional hooks, permission profiles and installers; Claude memory relocation; a synthetic example.

### Safety hardening before release

- The launchers no longer run an unseen repository's own settings, hooks or MCP servers. A repository you already trust loads as usual. `--project-config` and `--no-project-config` override this for one run, and a `.project-config` receipt records the result.
- Trust is looked up for the nearest folder holding a `.git` entry, by filesystem alone. Asking Git let a crafted `.git` file, a `.git` symlink or `core.worktree` borrow another checkout's trust.
- Every embedded Python call runs isolated, so a `json.py` in the repository or the caller's directory cannot run or forge a receipt.
- `--timeout` is validated before shell arithmetic: a crafted value could run a command.
- A lane whose monitor died is reported as `class=lost` instead of waiting forever. `.end` and `.monitor` are written atomically, and identity checks no longer depend on time zone or locale.
- Pre-tool guards fail closed when no parser is available, and no longer set a temporary locale, which could crash Homebrew bash 5.3 and let a call through unchecked.
- Guard gaps closed: shell tokenizer and wrapper-option bypasses, secret names in any letter case, and worker Git configuration injection through `-c`, `--git-dir` or `GIT_*` variables.
- Codex lanes give the same results as Claude lanes: outcome classes, a timeout watchdog, cancellation, an authentication check, worker Git denial and the outward-action guard.
- Installer: `--all` no longer replaces global instruction files, the coordinator preview shows the values it will set, and `CDPATH`, symlinked temporary directories and custom configuration homes are handled.

### Verification

Hermetic fixture suites on macOS under both the system bash and a current bash, CI on Python 3.11 and 3.14, independent reviews from two model families with every claim checked before a fix, and isolated outsider runs. Details and limits are in [verification](docs/verification.md).
