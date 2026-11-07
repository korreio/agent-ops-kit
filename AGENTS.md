# Contributor guidance

Agent Operations Kit is a macOS-focused collection of optional tools, practices and synthetic examples. Start with [README.md](README.md), choose one component, and read its effects and recovery notes before changing configuration.

- Preserve unrelated work. Keep private memories, credentials, session transcripts, local configuration and real project records outside this repository.
- Root `AGENTS.md` and `CLAUDE.md` contain identical contributor guidance. Keep them byte-identical when changing it.
- Code lives under `agent-orchestration/`; examples use synthetic data. Model configuration belongs in the sample roster, with its native copies checked by tests.
- Run `./verify.sh` for the owning hermetic suites and example/content checks. Tests use disposable homes and fake providers; they must not change real user configuration or call paid providers.
- Review changes independently, verify each actionable claim before fixing it, and rerun the affected checks. Never present fixture results as live provider or other-machine proof.
- Installation is optional. Preview the exact target, preserve backups and inspect configuration before opting into an apply operation. Do not change authentication, disable platform protections or promise model compliance.
- Changes to another repository, real user environment, hosted settings, visibility or promotion require that owner's authorization. A reusable example grants no such authority.

Contribution and security routes are in [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md) and [.github/SECURITY.md](.github/SECURITY.md).
