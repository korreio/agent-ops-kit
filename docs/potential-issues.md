# Potential issues before live use

Use live lanes only in repositories you trust. Read the chosen adapter and [adoption effects and recovery](adoption.md) before installation. Configuration, permissions, hooks and memory placement are optional and version-sensitive; a successful fixture check does not establish a live startup boundary.

**On both platforms, for review and writer lanes, a repository you have already trusted loads natively and an unseen repository does not run its project configuration.** Claude's trust comes from `hasTrustDialogAccepted` in `~/.claude.json`, Codex's from the `projects` table in its `config.toml`, looked up for `--cwd`, its physical path and the nearest folder holding a .git entry. The launchers walk up from the physical path without following that entry or invoking Git, and stop there even for a nested repository. A linked worktree does not inherit its main checkout's trust, because a repository can forge that link: trust it directly or use `--project-config`. The launchers read those files and never write them. A missing or unreadable trust file counts as unseen. `--no-project-config` forces exclusion anywhere and `--project-config` forces native loading; both together is a usage error. The launch line and the `<job>.project-config` receipt give `on` or `off`, then a reason: `trusted`, `unseen`, `unreadable-trust` or `flag`, and on Codex `untrusted`. In excluded mode a lane reads `CLAUDE.md` or `AGENTS.md` with its tools.

Trust follows the path, not the content: a branch from someone else, checked out in a repository you trust, loads natively. Use `--no-project-config` to review outside contributions.

**`--project-config`, and any session or lane in a trusted folder, runs repository configuration with your rights:**

- **Claude.** `claude -p` runs the repository's hooks and connects its `.mcp.json` servers without prompting, even in the review lane.
- **Codex.** The MCP servers in the repository's `.codex/config.toml` connect. Through the launchers this holds for that run only: live, `codex-write --project-config` ran the repository's MCP server and wrote nothing to `config.toml`. Outside them, a single `codex exec -s workspace-write` in an unseen repository can trust it permanently: Codex writes `trust_level = "trusted"` into your `~/.codex/config.toml`, and later lanes on that repository then load it natively, review lanes included. Undoing that means [removing the entry](adoption.md#codex-repository-trust) from `~/.codex/config.toml`.

**An interactive session is outside the launchers altogether.** Their default, flags and receipts do not reach a `claude` or `codex` you start yourself.

Exclusion keeps that configuration out of one run. It does not make any lane safe for untrusted code: the lane still takes the repository's content as input, and a writer can still run what its rules allow.

## What exclusion does

**Claude lanes.** The launcher adds `--setting-sources user` and a short notice, so neither the repository's hooks nor its `.mcp.json` servers run. User-level settings still apply. The repository's `CLAUDE.md` is no longer loaded automatically, so the notice tells the lane to read it with its file tools when its rules matter, and says its content cannot widen the lane's tools or scope.

**Codex lanes.** The launcher adds a per-run `projects` override that marks the repository untrusted under each path above, which stops both its MCP servers and the trust write, plus a short notice in the developer instructions. Nothing is persisted. An explicit `trust_level = "untrusted"` entry is yours: the receipt says `off untrusted` and the launcher adds nothing. `--project-config` adds a per-run trusted override under the same paths instead, over an `untrusted` entry too, so project configuration really loads for that run; observed live, the override ran the repository's MCP server and wrote nothing to `config.toml`.

Observed live on 1 November 2026 on Claude Code 2.1.316 with a synthetic repository: native loading ran a repository PreToolUse hook and an `.mcp.json` server. Exclusion ran neither, login kept working, and the reviewer still obtained the repository's rules by reading `CLAUDE.md` with its file tools because the notice told it to.

Observed live on 1 November 2026 on Codex 0.166.0: `codex exec -s workspace-write` in an unseen Git repository connected the MCP servers in that repository's `.codex/config.toml` and wrote `trust_level = "trusted"` for it into the user's `~/.codex/config.toml`. Read-only did neither: project `.codex` configuration and hooks stayed unloaded, no repository code ran, and `AGENTS.md` was read. After a writer run had recorded trust, a later read-only review of the same repository ran the MCP server too. The per-run override stopped both the server and the trust write. This is native Codex behaviour, not a kit defect. The vendor's [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) says project config loads only when a project is trusted; it does not describe how `exec` records trust.

## Guards catch mistakes, not repository content

A repository can disarm the kit's guards. Observed live on 1 November 2026: with native loading, `"disableAllHooks": true` in a repository's `.claude/settings.json` turned off a hook supplied at flag level. Vendor docs [rank project settings above user settings](https://code.claude.com/docs/en/settings#settings-precedence), so user settings alone cannot prevent this. The kit's guards therefore catch mistakes and are not a boundary against repository content, in any lane that loads natively and in any interactive session in a trusted folder.

A hook that crashes, times out or cannot start lets the call proceed unless the hook sets `onFailure: "block"`, which needs Claude Code 2.1.295 or later ([hooks reference](https://code.claude.com/docs/en/hooks)). The kit does not set it, because a moved checkout would then block every Bash call on the machine: installed hooks are links into the checkout. It is an owner opt-in.

Parser absence is a separate case: pre-tool guards fail closed on both platforms, and [sample policy effects](adoption.md#sample-policy-effects) says what that means.

## Startup configuration can run code

A brief is not the only input. The native CLI can load installed, repository and managed configuration, including hooks and configured tools. Inspect the effective configuration for the chosen account and working directory. Permissions and command guards do not guarantee hostile-code isolation. An export made with `git archive` can retain `.codex`, `.claude` and `.mcp.json`; an archive alone is not isolation.

Codex project trust controls project configuration discovery. The launchers supply a per-run `projects` override whenever a lane is excluded, by default in an unseen repository. With `--project-config` they supply a per-run trusted override. In a trusted repository they supply none, and existing owner settings and the native client's trust decisions decide. Hook discovery is distinct from execution: non-managed hook definitions require separate definition-hash trust. Consult the current [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference), [hook trust documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks) and [MCP configuration guide](https://learn.chatgpt.com/docs/extend/mcp). Configured MCP servers can start local programs or contact remote services. Tool-permission profiles are not a guarantee about every native startup behavior.

The Claude launchers use `-p`, which skips workspace trust prompts. This does not mean every project setting is enabled: permission allows, additional directories and some helpers have their own rules. Read the current [headless guide](https://code.claude.com/docs/en/headless) and [what runs before folder trust](https://code.claude.com/docs/en/permissions#what-runs-before-you-trust-a-folder). Inherited settings still matter when a launcher selects plan mode or a tool list.

## Review tools and writing are separate

The Claude review launcher supplies `Read`, `Grep` and `Glob` through the native availability
flag and matching preapproval rules. These flags have different purposes; see the current
[CLI reference](https://code.claude.com/docs/en/cli-reference). File-reading tool availability
does not disable native startup hooks, inherited configuration or configured MCP services.
Intentional editing uses the explicitly named writer commands.
Writer permission modes and command patterns do not establish hostile-code isolation.

Codex review retains shell access under its native read-only profile; the review command refuses
a workspace-write selection. The [permission fragment](../agent-orchestration/codex/config-fragment.toml)
turns command network off for the review lane's profile and leaves it on for the writer lane.
Its list of literal denials is minimal and is not a boundary: review lanes can read other files
on the disk.

## Live data and account choices

Live use can send briefs and selected repository context through the chosen CLI and configured provider, gateway or tools. A gateway can change the route; do not assume direct vendor delivery, exact retention or that everything stays local. Review your organisation's data policy and the applicable account, service and tool settings. Claude documents relevant distinctions in [data usage](https://code.claude.com/docs/en/data-usage).

Shipped CI uses fake providers and disposable homes. If an owner later introduces live automation, account access and authentication must follow the chosen provider's current guidance and policies; see [Codex non-interactive use](https://learn.chatgpt.com/docs/non-interactive-mode) and [Claude legal and compliance guidance](https://code.claude.com/docs/en/legal-and-compliance). The kit does not authorize account changes.

## Future CLI change

The vendor's [headless guide](https://code.claude.com/docs/en/headless) says `--bare` will become the default for `-p` in a future release, and that bare mode does not use subscription login. The launchers do not pass `--bare`, and that change could break them for subscription users. If it lands, recheck the launchers against the installed CLI before relying on them.

## Terms

The kit collects no credentials and runs the unmodified CLI under your own login. You remain responsible for your provider's terms and usage limits, which assume ordinary individual use; see [Claude legal and compliance guidance](https://code.claude.com/docs/en/legal-and-compliance). This page gives no legal opinion.
