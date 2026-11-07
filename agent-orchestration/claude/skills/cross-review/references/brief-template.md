# Adversarial review brief — {{TARGET_LABEL}}

You are an independent, adversarial, READ-ONLY reviewer (skeptical staff engineer). Hard limits:
do not modify any file; do not run the project's build or test tooling. Reading files is always
fine. The ONLY git commands you may run, and only where your tools allow them, are
`git --no-optional-locks status --short`, `git log`, `git show <rev>:<path>`, `git blame` — run from the repository
cwd (no `-C <path>`, no pipes into writers, no `--output=`). Status requires the
global `--no-optional-locks` flag: plain status may refresh and write the coordinator-owned index.
Other allowed commands use their listed plain-subcommand spelling. Never run ANY `git diff` form (not
`git diff`, `git diff --cached`, `git diff <a>..<b>`, `git diff --stat`, nor a `git diff` inside
a pipeline): it rewrites the repository's index stat cache, which is state the coordinator owns,
and no reviewer needs it — the coordinator materializes the target for you. Any git write
(add/commit/stash/checkout/worktree/branch) is likewise forbidden. {{TOOL_NOTE}}

TARGET: {{TARGET}}
(The diff/plan is materialized at `{{MATERIALIZED_PATH}}` — read that file; it is the target,
not a fallback for when you cannot run git.)

READ FIRST (authoritative context, in this order): {{CONTEXT_PATHS}}
Use the post-change tree for line numbers.

LOOK FOR (priority order): {{LOOK_FOR}}
Default list when unspecified: correctness defects; where the target has them, for example
lifecycle/async races (validity or generation re-check after every await, on catch, retry and
secondary apply paths) or tenant or account leakage across logout/switch; durable-data loss or
wrong-key persistence; INCOMPLETE
HALVES (a contract, default or owner changed but not every consumer updated — enumerate the
consumers); tests that pass only on inputs the real caller never produces; guards or pins
weakened by their own fix; docs/help text that now contradicts behaviour; for a PLAN: the readiness check of orchestration reference §8; steps
that break a named invariant, missing rollback/retry/offline paths, verification gaps
(what evidence proves each step), and a simpler alternative the plan ignored.

READER CHECK (for repository-level rules, contracts, standing orders): re-read the text as a
coordinator on a DIFFERENT agent platform than the one that wrote it — every platform receives
the same repository contract through `AGENTS.md` (symlink to `CLAUDE.md`, loader, or canonical
file) and the same machine-level standing orders; flag any sentence that assumes one platform
coordinates, names one platform's tooling as the mandate, or makes an "external" role depend on
who happens to coordinate.
When asked to confirm that shared or agreed text is present on a surface, verify the WHOLE unit
string after normalizing whitespace (hard-wrapped lines, double spaces) — never a prefix, a
single line, or a paraphrase — and report the exact string you matched; a prefix match read as a
whole-unit match produced three false "identical" claims in one evening.

RULES: every finding cites `file:line` (or plan section) plus a concrete failure scenario
(inputs/state -> wrong outcome) and the smallest fix. Every finding also names its trigger,
traced forward from where it starts and never from the middle of the code: what the user does
(the action taken at that moment, including what enables or covers it)
or the system event, and how often ordinary use hits it. For a PLAN, the trigger is the step that,
followed as written, goes wrong (orchestration reference §8). Without a reachable trigger it is a
hypothesis (confidence < 0.5); `n/a` is not an answer. Prefer few verified findings over many
speculative ones; give confidence 0.0–1.0 (< 0.5 = hypothesis). No style nits unless P3 and
real. Do not trust the author's summary. If a check was impossible with your tools, say so under
`blocked` instead of guessing. Also list what you checked and found clean. If clean, name the
3–7 places most likely to still hide a defect. Cap at 10 findings ranked by severity × confidence.

OUTPUT: reply with exactly ONE JSON object and nothing else, matching this schema:
{"verdict":"CLEAN|FINDING|BLOCKED","findings":[{"severity":"P1|P2|P3","file":"path","line":123,"title":"short","trigger":"what the user does (the action taken, what enables or covers it) or the system event; how often. Never n/a","failure_scenario":"inputs/state -> wrong outcome","smallest_fix":"...","confidence":0.0}],"checked_clean":["..."],"blocked":["..."],"reviewer_notes":"<=120 words"}
