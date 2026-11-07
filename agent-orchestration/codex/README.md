# Native Codex adapter (experimental, macOS-focused)

These files adapt the dated sample roster to native role TOMLs, hook events and permission
profiles. Historical native-profile probes used Codex 0.162.0; fixtures exercise emitted
configuration, not current live permission enforcement. Recheck the installed CLI before real
use. Native configuration interfaces can change independently of the kit.

Before live use, read the [startup, trust and data issues](../../docs/potential-issues.md).

`config-fragment.toml` includes a coordinator profile named `development`: reads from the Mac,
writes current workspace roots, `/tmp`, the system temporary directory and
`~/.claude/session-env`. It does not grant writes throughout the home directory. Actions outside
those roots follow native approval configuration. The display guard is a heuristic that
catches mistakes; it enforces nothing natively for the coordinator. Install no profile merely to
make a blocked action pass.

Review and writer lanes share one list of literal denials. It is minimal and is not a boundary:
review lanes can read other files on the disk. The reviewer has no write roots, and its profile
has command network off. The writer keeps command network, and adds workspace edits and
temporary/session paths while keeping workspace `.git`, `.codex` and `.agents` read-only. That
is what the fragment configures. Native hooks also reject worker Git mutation. This is not
hostile-code isolation: inherited permissions, interpreters and native path matching matter.
The shared-guard wrapper resolves its installed link in the shell, and any failure in it blocks.
The underlying guard tries jq, then Python, and fails closed with an actionable message when
neither parses the input. Advisory hooks stay non-blocking.

`bin/codex_job.sh` chooses the lane from its invocation name, resolves a roster role and asks
`lane_config.py` for run-specific profile names. This avoids merging stale installed lane tables.
A review invocation refuses `--sandbox workspace-write` and writer roles; use `codex-write`
for intentional editing. It passes no legacy sandbox flag. Resume uses the same lane and working directory. Existing
unrelated user configuration remains loaded, so ordinary reviewer launches are not cold sessions.

A repository already trusted in the `projects` table of `config.toml` loads natively. Lookup checks
`--cwd`, its physical path and the nearest folder holding a .git entry, walking up from the physical
path without following that entry or invoking Git. A linked worktree does not inherit its main
checkout's trust, and a nested repository stops the walk before a trusted ancestor. An unseen
repository does not run its project configuration: the launcher adds a per-run untrusted override,
and a missing or unreadable trust file counts as unseen. An explicit `untrusted` entry is yours and
nothing is added to it. `--no-project-config` forces the override. `--project-config` adds a per-run
trusted override instead, even over an `untrusted` entry, and writes nothing to `config.toml`;
both together is a usage error. The launch line and `<job>.project-config` give `on` or `off`, then
a reason. Observed live with Codex
0.166.0 on 1 November 2026: a read-only lane in an unseen repository ran no repository code, loaded no
project `.codex` configuration or hooks, and still read `AGENTS.md`. A native writer run did not stay
out: it ran the repository's MCP server and recorded `trust_level = "trusted"` in
`~/.codex/config.toml`, and a later read-only review of that repository ran the server too. See
[potential issues](../../docs/potential-issues.md) and
[trust recovery](../../docs/adoption.md#codex-repository-trust).

Optional installation uses `install.sh --apply --codex-agents`, `--codex-hooks`, `--codex-skills`
or `--codex-config`, each explicitly selected. `--codex-config` installs the lane profiles only.
The separate `--codex-coordinator` opt-in installs coordinator root defaults, features and the
`development` profile, and removes legacy permission settings; preview those named changes
before applying. Python 3.11+ is required for `tomllib`. Roles are
managed regular copies with a digest marker; local divergent copies refuse replacement. Skills
and hook scripts link to toolkit files, so later toolkit updates affect future sessions. Config
and hook state remain per-machine regular files, with backups, concurrency checks and conflict
refusal. Hook hash trust needs native CLI metadata; fake providers supply it only during tests.

Inspect the installer before applying. Use a scratch home first and keep existing credentials
owner-managed. Recover by stopping writers, comparing adjacent backups and restoring only the
chosen file or link. No rollback merges notes or resets unrelated settings.

Use native roles to make duties visible; use the launcher when independent native fencing is
required. Omit installation when document-only coordination is enough. Adapt role pins in the
roster and checked copies together, then run `tests/test_roster.sh`, `tests/test_codex.sh` and
`tests/test_install_codex.sh`. Successful fixtures prove those cases, not live model compliance.
