# Contributing

Start with the README and choose the component affected. Open an issue before substantial changes so scope and maintenance cost can be discussed. Be respectful and describe a real user action, the observed result and the expected result.

Submit only material you have the right to contribute. Contributions are licensed under the repository's MIT license. AI assistance is welcome when the contributor checks the result, sources, behavior and license obligations. Do not include credentials, private memories, real session records, employer material or third-party code without required notices.

Run `./verify.sh` from the repository root using Python 3.11 or newer, Bash and jq on macOS. It runs fixture-only suites with disposable homes, without provider calls or real configuration changes. Include affected commands, results and limits in your change description. Live provider tests are separate, optional evidence and must not be claimed from fixtures.

Keep adapters distinct, changes small, examples synthetic and root contributor loaders identical. Preserve independent tests when removing a consumer. Review feedback should name a reachable trigger and be verified against the code before a fix.

This is an experimental, best-effort project. An issue or contribution creates no support deadline or promise of acceptance.
