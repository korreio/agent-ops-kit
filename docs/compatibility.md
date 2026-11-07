# Compatibility and evidence

Executable support is **macOS-focused**. Claude Code and Codex are the supported agent platforms. “Platform” here names an agent harness, not an operating system. No Linux/Windows or second-Mac execution parity is claimed.

## Evidence tiers

| Tier | Meaning | What it cannot establish |
|---|---|---|
| Historical observation | Dated behavior recorded in prior experiments | Current shipped bytes, current vendor behavior or reproducibility from retained raw transcripts |
| Current hermetic fixture | Shipped code exercised with fake providers, scratch homes and synthetic records | Live model compliance, paid-account access or host containment |

The recorded environment, commands, results and execution limits are in [verification](verification.md). Historical observations and fixture checks provide different evidence.

## Adapter matrix

| Component | Historical probe baseline | Current hermetic check | Live/portability limit |
|---|---|---|---|
| Claude launcher | macOS CLI 2.1.220; later writer/denial probes at 2.1.296; repository-configuration probe at 2.1.316 (1 November 2026) | `tests/test_launchers.sh`, scratch fake CLI | The file-tool availability list and schema combination are fixture-checked; fresh live combination remains unproved; an unseen repository's hooks and `.mcp.json` servers are excluded by default, a trusted one loads natively; user-level startup/MCP/settings still apply |
| Codex launcher and native profiles | macOS CLI 0.162.0 profile behavior; 0.163.0 exec-identity stop probe; 0.166.0 trust, network and denial probes (1 November 2026) | `tests/test_launchers.sh`, `tests/test_codex.sh`, `tests/test_install_codex.sh` | Native permission schema and precedence are version-sensitive; no hostile-code isolation claim; an unseen repository gets a per-run untrusted override by default, because a native writer run records trust persistently |
| Claude hooks/settings | Historical installed hooks and parser behavior; `disableAllHooks` probe on 1 November 2026 | `claude/hooks/test_hooks.sh`, `tests/test_install_claude.sh` | Pre-tool guards fail closed without a parser; advisory hooks do not. A repository can switch hooks off and a failed hook lets the call proceed: [guards are not a boundary](potential-issues.md#guards-catch-mistakes-not-repository-content) |
| Role roster/native copies | Dated role selections | `tests/test_roster.sh` | Sample configuration; no evergreen model recommendation |
| External memory | Claude absolute-project-path layout assumption | `tests/test_install_memory.sh` | Same-machine fixtures; no automatic multi-Mac service or universal memory |
| Session ledger | Historical usage schemas and dated list-price proxies | Synthetic records only where explicitly checked | Private transcript formats/prices can change; Codex tokens are priced in credits, never added to dollars |

Paths above are relative to `agent-orchestration/`. Python 3.11+ is the documented baseline because `verify.sh`, the Codex launchers and the native installer use standard-library TOML parsing; the synthetic example also runs on the stock macOS Python 3.9. Runtime versions actually exercised and CI's selected runtime must be recorded separately.

## How to assess your environment

Read the chosen script and its `--help`; compare installed CLI help and official documentation before using version-sensitive fields. Keep native configuration under the owner's authority. If a setting is unsupported, omit that component and report the missing behavior instead of weakening a fence or inventing a flag.

- [Claude Code documentation](https://code.claude.com/docs/en/overview): CLI, permissions and configuration are vendor-owned interfaces.
- [Codex documentation](https://developers.openai.com/codex/): native profiles, agent roles and CLI behavior may change.

These are reference entry points, not a claim that every current interface has been reviewed. The kit's [maintenance route](maintenance.md) calls for a dated recheck, owning tests and a bounded live probe when a version-sensitive assumption changes.
