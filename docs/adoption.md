# Adopt one component at a time

The minimum adoption is a document. Read the [design sequence](design.md), take the ownership and verification ideas that solve your problem, and adapt them to the repository's existing contract. Nothing needs to be installed for this route.

## Before a live lane

Before live use, read the [startup, trust and data issues](potential-issues.md).

## Disposable first use

From the kit root, run the [synthetic example](../examples/README.md). It runs on the stock macOS Python 3.9, reads shipped samples, and writes only to an explicit new scratch directory. Its records are authored samples, not live-agent evidence. `verify.sh`, the Codex launchers and native Codex targets need Python 3.11+: on a stock Mac, run `brew install python` or use a python.org installer, then check `python3 --version`.

For installer behavior, use a private disposable copy and scratch home. The following creates only a demo directory beneath the system temporary directory. It makes no model call; inventory may invoke installed provider CLIs for version/status information:

```sh
kit="$PWD"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/agent-ops-install.XXXXXX")"
mkdir "$sandbox/home"
cp -R "$kit/agent-orchestration" "$sandbox/toolkit"
```

For a provider-free preview, run this optional block in the same scratch shell before either installer command. These two stubs answer only synthetic inventory requests and refuse everything else:

```sh
mkdir "$sandbox/fake-bin"
for provider in claude codex; do
  cat > "$sandbox/fake-bin/$provider" <<'SH'
#!/bin/sh
case "$*" in
  --version) printf '%s\n' 'synthetic provider fixture'; exit 0 ;;
  'login status') printf '%s\n' 'synthetic: no real login status inspected'; exit 1 ;;
  *) printf '%s\n' 'synthetic fixture: unsupported request' >&2; exit 2 ;;
esac
SH
  chmod +x "$sandbox/fake-bin/$provider"
done
original_path="$PATH"
export PATH="$sandbox/fake-bin:$PATH"
```

With this block, provider versions and unavailable-status warnings are synthetic; they establish nothing about real provider installation or login. `node` and `python3` remain ordinary local runtime version checks. Skipping the block allows the inventory reads described below.

```sh
HOME="$sandbox/home" bash "$sandbox/toolkit/install.sh" --check
```

Working directory: kit root. Prerequisites: macOS shell tools; Python 3.11+ for native Codex targets; `jq` for Claude hooks. Expected: inventory output with each planned action on a `PLAN` line; no installation into your real home. The preview runs available CLI version commands and Codex login-status inspection, and can report unavailable optional CLIs. Use the optional block above when real CLI/status access is unsuitable. A preview is not a live permission probe. `--check` does not run MCP commands, including when `--remove-codex-mcp` is selected. `--contracts-root DIR` sets contract inventory to `DIR/*/AGENTS.md`; the default is `$HOME/Development/*/AGENTS.md`, not a recursive scan or a complete repository inventory.

Choose only the target you inspected. For example, in the same shell:

```sh
HOME="$sandbox/home" bash "$sandbox/toolkit/install.sh" --apply --bin
```

Expected: launcher links beneath the scratch home's `.local/bin`, each reported on an `APPLY` line, with backups when a file is replaced. This links tools; it does not run a model. Inspect them with `ls -l "$sandbox/home/.local/bin"`. A second application should be idempotent for unchanged links. The test suites cover named fixtures; inspect actual output before relying on that result in your environment.

## Effects by target

| Target | Reads | Writes when explicitly applied | Use or omit |
|---|---|---|---|
| `--bin` | Supplied launcher scripts | Links under `~/.local/bin` | Useful across coordinating platforms; omit if calling scripts directly |
| `--global-claude-md`, `--codex-agents-md` | Sample standing orders | Provider's global instruction entry point | Imports autonomous action/fix/install orders and the paid-account/authentication policy into future sessions; adapt before use |
| `--agents`, `--rules`, `--skills` | Claude native definitions and sample rules | Links in selected Claude directories | Review sample text before use; personal/domain rules are not supplied |
| `--hooks` | Hook scripts and settings fragment; at session start, `roster-freshness` also reads up to 20 lane transcripts and `~/.codex/models_cache.json` | Hook links plus merged Claude settings | Requires `jq`; includes the staging, Homebrew, outward-ask (`gh workflow run` prompts; its allow file sits in the tracked tree) and roster-freshness policies below |
| `--codex-agents`, `--codex-hooks`, `--codex-skills` | Codex native definitions | Managed role copies, hook links/definitions/trust or skill links | Native target selection runs separately from other target families; inspect version support |
| `--codex-config` | Codex permission fragment | Adds `permissions.orchestration-*` lane profiles (the review profile has command network off, the writer profile keeps it); differing named profiles are refused | Leaves coordinator defaults and legacy sandbox keys unchanged |
| `--codex-coordinator` | Sample coordinator configuration | Sets default model/effort, `project_doc_max_bytes`, `default_permissions`, `approval_policy = "on-request"`, `approvals_reviewer = "auto_review"`, features and `permissions.development` (workspace/temporary writes and command network access); removes legacy sandbox configuration. With `auto_review`, Codex's reviewer subagent, not you, reviews eligible approval prompts under `on-request`; the default is `user`, and the setting does not change sandboxing ([configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)) | Separate opt-in; PLAN names each key with the value it will set and withholds your existing one; inspect each before changing your security posture |
| `--remove-codex-mcp` | Legacy registration lookup on explicit apply only | Removes the user-scope `codex` registration | Record the previous registration before removal; the installer supplies no registration backup |
| `--memory-root … --memory …` | One project's Claude memory and external destination | Per-project relocation/link/backups | See [memory](memory.md); external private store required |

`--apply` needs an explicit target. `--all` is a convenience subset, not a universal setup: it means exactly `--skills --bin`. Sensitive/native targets, the global loaders (`--global-claude-md`, `--codex-agents-md`) and memory still require their own selection. Read `bash agent-orchestration/install.sh --help` for the current exact membership. A preview prints each planned change as `PLAN`; `--apply` prints the same lines as `APPLY`, because it makes each change as it reports it. This kit omits the optional marketplace installation target; independent CLI adapters remain usable.

The installer refuses to edit a home the provider is not reading. If `CODEX_HOME` or `CLAUDE_CONFIG_DIR` names another directory than `$HOME/.codex` or `$HOME/.claude`, that provider's selected targets stop with exit 2 before any change, including in a preview, which selects every target. Hook commands hard-code those two homes and the installer edits them, so a provider pointed elsewhere would never read what a target installs. Unset the variable for the run or omit those targets; `--apply --bin` and `--remove-codex-mcp` are not affected.

## Sample policy effects

Global instruction targets load the [sample standing orders](../agent-orchestration/standing-orders.md): finish authorized work, fix confirmed findings without asking again, send scoped source and context to review providers without asking for each review under order 6, install qualifying dependencies without asking under order 11, and read a tool's official documentation before building on it under order 12. Order 10 requires paid accounts and prohibits signing in/out, creating accounts or changing authentication. These are the author's policy choices; adapt them before global adoption. Repository contracts retain their stricter authority.

The staging hook blocks `git add .`, `git add -A`/`--all`, forced staging, bare `git add -u`/`--update`, and `git commit -a`. Explicit paths such as `git add src/file` and `git add -u src/file` are permitted by this check; the worker's Git prohibition still applies.

Hook installation prepends the ordered sample deny rules when any are missing, preserving the existing list's order and duplicates. Existing owner rules can override the sample's exceptions. The extension-wide rules among them (`*.pem`, `*.key` and similar) are tool-level denials with false positives, such as a Keynote `.key` document or a CA bundle. They are distinct from the native profile in the [case study](case-studies.md#2-protect-secrets-while-preserving-legitimate-dependencies), and an owner exception later in the same list can override them.

The outward-ask hook stops `gh workflow run`, because the command starts remote CI work. On Claude it raises a native permission prompt, even where a mode or an allow rule would run the command, and an unattended run has no one to answer it. On Codex it denies the call, because Codex continues a tool call on an ask. A run is exempt only when `agent-orchestration/claude/hooks/outward-ask.allow` lists both the repository and the workflow, and no `-R`/`--repo` appears. That allow file sits in the kit's tracked tree beside the hook and ships empty, so an entry you add is a change to the checkout and can name a private path; keep it out of anything you publish. The check parses selected shell forms: `bash -c`, scripts, aliases and `GH_REPO` are not inspected.

The worker-git hook blocks direct Git changes by a subagent, an in-process teammate or a launched writer lane, on both platforms. `git status`, `git log`, `git blame` and `git show <rev>:<path>` stay allowed; `git diff`, `git show <sha>` and `git rev-parse` do not. A coordinator session is unaffected. After `--hooks`, every Claude subagent is bound by this, so omit the hook if your subagents hold Git.

The roster-freshness hook runs at session start on both platforms. It reads the roster, `~/.codex/models_cache.json` and up to 20 of the newest lane transcripts under `~/.claude/projects` (the last 256 KB of each) to compare model names, and it adds one line to the session's context only when the roster looks stale. It makes no model call and uses no network. To clear its notice, recheck and update the roster: its `Last checked` date for an age notice, the row it names for a model notice. Or omit the hook. On Codex it also compares the running model with the roster.

The Homebrew hook requires `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1` and `HOMEBREW_NO_AUTOREMOVE=1` for `brew install` and other recognized mutating commands, set inline or exported earlier in the same command. It always blocks `brew autoremove`, `brew cleanup` and `brew bundle cleanup`. Read-only commands pass. These checks parse selected shell forms rather than arbitrary scripts.

Pre-tool guards fail closed on both platforms. When neither `jq` nor `python3` can read the hook input, the Bash call is blocked with a message telling you to install one in your own terminal, and Bash stays blocked until then. A missing `lib/shell-tokens.bash` blocks the same way and says to reinstall the hooks. Advisory hooks (`bash-syntax`, `roster-freshness`) stay non-blocking. This does not replace native access controls. Read [permission layers](design.md#four-different-layers) before relying on a lane boundary.

A hook that crashes, times out or cannot start lets the call proceed unless it sets `onFailure: "block"`, which needs Claude Code 2.1.295 or later. The kit does not set it, because a moved checkout would then block every Bash call on the machine; it is an owner opt-in. A repository can also switch hooks off, so these guards [catch mistakes and are not a boundary against repository content](potential-issues.md#guards-catch-mistakes-not-repository-content).

## Upgrading an earlier linked installation

Inspect installed links and keep a recovery copy before updating the checkout they point at.
Updating linked source changes the next session even without reinstalling: the Claude deep,
wide and rule reviewers lose Bash, while copied definitions/configuration keep their older
contents until explicitly reconciled. This release directly changes no installed path and
performs no cleanup. The writer commands, native writer roles/profiles and local ledger remain.

The old Claude reviewer form `--tools 'Read,Grep,Glob,Bash'` now refuses with usage exit 2.
Use reading-tool subsets and supply shell/Git/test evidence in the brief. A missing `--tools`
value, a repeated option and boundary whitespace also refuse. `codex-review --sandbox workspace-write` now
refuses; use `codex-write` explicitly for authorized edits. Review commands do not silently
become writers or downgrade an editing request into a paid review.

Lanes in an unseen repository no longer run its project configuration by default, on either
platform. A lane that relied on repository hooks or MCP servers there needs `--project-config` or
a trust decision of your own. A trust entry an earlier `codex-write` run recorded still counts as
trust, so inspect the `projects` table: see [Codex repository trust](#codex-repository-trust).

Codex lanes now classify outcomes as Claude lanes do. `<job>.result.json` is new, `--wait` exits
with the class number and a missing `codex` exits 125, so a script that expected exit 1 or 2 needs
a look. They also check `codex login status` first, and they have a watchdog where they had none:
10m for a review and 60m for a writer, with a 300 s floor. Pass `--timeout` for a longer run.

`--all` now means exactly `--skills --bin`. It no longer links the global loaders, so select
`--global-claude-md` or `--codex-agents-md` by name if you want them. Links it made earlier stay
in place.

`--codex-config` over an older install stops with the existing conflict refusal, `existing named
permission profile conflicts`, because the review profile's description changed. Edit or remove
the `description` line of the `orchestration-review` profile in `~/.codex/config.toml`, then
re-apply. Lanes are unaffected: the launcher builds its profile per run and does not read the
installed `orchestration-*` tables.

Memory slugs now use the repository's physical path. There is no migration. If you made a memory
link through a symlinked path, inspect it with `ls -ld` and `readlink`: it sits under the old
slug, and a new `--memory` run would act on a different one. Follow
[manual migration](memory.md#manual-migration-and-undo) to move it.

Antigravity targets and `agy-review` no longer ship; retired `--agy`, `--agy-rules` and
`--agy-allowlist` options refuse before applying anything. Existing installation artifacts are
not pruned:

| Earlier artifact | Owner-directed inspection and recovery |
|---|---|
| `~/.local/bin/agy-review`, `~/.claude/skills/agy-reviewer` | Inspect with `ls -ld` and `readlink`, including dangling links. Remove only links verified to point to the old kit and restore their exact matching backups, if any. Keep links owned by another checkout or tool. |
| `~/.gemini/config/agents/read-only-reviewer.md`, `~/.gemini/config/rules/agent-orchestration-standing-orders.md` | These were copied files. Preserve current contents, compare with the prior install receipt/backups and reconcile later edits. Restore the matching original, or remove only an unchanged kit-owned new copy. |
| `~/.gemini/antigravity-cli/settings.json` | If the old allowlist target was used, reconcile its adjacent pre-merge backup with later settings. Remove only prefixes known to have been introduced by that installation; preserve preexisting/shared prefixes and unrelated preferences. If ownership is ambiguous, leave it for manual reconciliation. |

Do not delete a provider directory or replace its entire configuration to remove one component.
The current installer cannot reconstruct earlier ownership or backups. A missing source target
does not prove that a copied setting has been removed.

## Linked versus copied

Links point at this toolkit. Editing or updating their target can affect the next session immediately, even if you never rerun the installer. Keep the toolkit in a stable location and review updates before using linked configuration.

Native definitions/configuration can instead be copied or merged by their owning installer. A copy does not update when the toolkit changes, and merge behavior can retain a setting removed from a newer fragment. Compare the installed file with the current fragment; absence from the fragment is not proof of absence from installed settings. Do not blindly replace user configuration to resolve drift.

## Failure and recovery

A differing Claude rule is preserved for manual reconciliation. Populated directories and concurrent configuration changes are refused where the installer can detect them; a warning is not a merge. Read the result and re-inventory before retrying. Missing parser/runtime dependencies can leave a target unapplied; report that target as failed.

There is no uninstall command. Save the installer's exact target and backup paths. Shell-installer backups normally live beneath `~/.claude/backups/agent-orchestration-*`; native Codex backups are adjacent `*.bak-*` files. A newly created target has no prior file to restore.

Populated memory-directory relocation instead keeps a sibling `memory.local-backup-*`; eligible empty-directory or link replacements use the shell backup directory. Follow the exact reported path.

Before any recipe below, stop affected sessions, copy the current targets to a separate recovery directory, and compare them with the matching pre-install backups. Preserve later edits by reconciling them into the recovered file. Do not restore unrelated backups or remove an entire provider directory.

| Target | Manual undo |
|---|---|
| `--bin`, Claude `--agents`/`--rules`/`--skills`, global Claude/Codex loaders | Inspect `ls -ld` and `readlink` for each installed path. Remove only a link that still points to this kit, then move its matching backup to the original path. If no original existed, leave that exact path absent. Global loaders are `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`; preserve any later replacement instead of deleting it. |
| Claude `--hooks` | Restore/reconcile `~/.claude/settings.json` from its pre-merge backup, including both hook registrations and deny entries. Then remove only this kit's hook links beneath `~/.claude/hooks` and restore their matching originals. If settings were newly created, remove only the installed fragment's entries while retaining later settings. |
| Native Codex `--codex-agents`/`--codex-skills` | Restore matching adjacent backups beneath `~/.codex/agents` or `~/.codex/skills`. Roles are managed regular-file copies; skills are links. Remove only unchanged new artifacts when no prior target existed. |
| Native Codex `--codex-config`/`--codex-coordinator` | Restore/reconcile `~/.codex/config.toml` from its adjacent pre-change backup. Retain later unrelated keys. Undo only selected lane/coordinator keys; a coordinator rollback may need the previous legacy sandbox keys as well. |
| Native Codex `--codex-hooks` | Treat `~/.codex/hooks.json` and `~/.codex/config.toml` as a pair: restore their matching pre-install definitions and hook trust states together, then restore/remove this kit's script links in `~/.codex/hooks`. Hook trust is keyed by definition position/hash; restoring only one file can attach trust to the wrong definition. If later hooks changed, reconcile both files and inspect native hook metadata before restarting. Follow any `RECOVERY INCOMPLETE` receipt rather than assuming rollback completed. |
| `--remove-codex-mcp` | Recreate the prior registration using the recorded scope, transport, command/arguments or URL and environment details, with the installed Claude CLI's supported registration interface. Those details must have been preserved before removal; there is no installer backup or generic reconstruction recipe. Keep secrets outside this repository. |
| Memory | Use [manual migration and undo](memory.md#manual-migration-and-undo); preserve both stores and later notes before changing the exact project-memory link. |

For a link with a verified matching backup, the manual operation is `rm "$installed_link"` followed by `mv "$matching_backup" "$installed_link"`. Substitute only paths you have inspected; do not use wildcards. For merged/copied files, prepare and inspect the reconciled replacement first, then replace that exact target and read it back. The installer does not reconcile changes made after installation.

If you used the fake-provider block, restore this shell's path with `export PATH="$original_path"` after the demo. Remove the exact scratch demo directory after inspection. The demo does not install real global configuration or need private memories or a model call; inventory can inspect existing provider status without changing authentication. Real adoption is an owner-directed configuration choice; this repository's preparation does not install itself into a user environment.

## Codex repository trust

This is not an installer effect, and no kit target wrote it. A writer run under native loading in an unseen repository can make Codex record it as trusted in `~/.codex/config.toml`: a direct `codex exec`, or a `codex-write` run from a version of the kit whose default was native. `codex-write --project-config` wrote no entry when observed live. [Later lanes on that repository then load it natively](potential-issues.md), review lanes included. The installer neither creates nor removes that entry.

1. Stop Codex sessions and lanes on that repository, and copy `~/.codex/config.toml` to a separate recovery directory.
2. Find the `[projects."<repository path>"]` table with `trust_level = "trusted"`. Remove that line, and the table header if nothing else sits under it. Retain every other key, including other repositories' entries.
3. Read the file back. Launch the next lane on that repository without `--project-config`, and confirm its `<job>.project-config` says `off`.

Removing the entry stops later loads. It does not undo what a repository MCP server already did while it ran with your rights, so inspect that separately. If you trusted the repository yourself, the entry is yours; keep it.
