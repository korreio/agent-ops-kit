# License and dependency scope

The owner-authored toolkit and documentation are covered by the root MIT license. Existing notices must be preserved in future contributions. The project was developed with AI assistance; the maintainer remains responsible for checked content.

No vendor CLI, parser, runtime or GitHub Action source is bundled. Users obtain those dependencies separately under their own licenses and service terms:

| Dependency | Purpose | Distribution boundary |
| --- | --- | --- |
| Bash, Python, jq | Shell tools, standard-library helpers and JSON parsing | User/runner provided; no vendored source |
| Claude Code, Codex CLI | Optional provider adapters | User installed and authenticated; no credentials bundled |
| Node.js | Optional version inventory; guards use jq or Python JSON parsing and the shipped shell tokenizer | User provided; no Node module or third-party shell parser is bundled or required |
| `actions/checkout` | CI source checkout | SHA-pinned workflow dependency; MIT upstream |
| `actions/setup-python` | CI Python runtime selection | SHA-pinned workflow dependency; MIT upstream |

Action repository identifiers and pins in the workflow are supply-chain declarations, not related-project endorsements. The workflow does not upload session records, raw sources or artifacts. Each action's upstream license remains available from its repository. Warmboot Light and Full are optional, independently maintained companion repository contracts; their source is not bundled.
