# Contributing to Aure

Aure is an early-stage macOS app. Small, testable changes are easier to review than large feature drops. Open an issue before starting an integration, changing model defaults, or adding a dependency.

You do not need to contribute code to help. Clear bug reports, anonymized examples of missed or unnecessary corrections, documentation fixes, and reproducible compatibility reports are all useful. Use [GitHub Issues](https://github.com/tiagocolombo/aure/issues) to discuss work before opening a pull request.

## Set up

Follow the [source-build instructions](README.md#build-from-source). Use the shell scripts directly; the optional Nix development shell currently has a private dependency. You need macOS and Apple's Swift 6 toolchain to build and run the Swift tests.

```sh
scripts/test.sh
scripts/lint.sh
```

`test.sh` runs the Swift package tests. `lint.sh` builds the package and runs `swift-format` when available. Both scripts also run extension checks if an extension package exists; that conditional is not evidence of a shipped extension.

## Make a change

1. Start a branch from the current default branch and keep the change focused.
2. Add a regression test before fixing a bug. Core logic belongs in the Swift package, separate from UI and Accessibility effects where possible.
3. Run the tests and lint script. Include the commands and results in your pull request, and state what you could not verify.
4. For UI or Accessibility changes, test a real app as well as the unit tests. Include macOS version, hardware architecture, target app/browser version, and the exact field tested.
5. Update public documentation if behavior or setup changes. Treat `docs/PLAN.md` and `docs/BACKLOG.md` as design history and planned work, not a list of implemented features.

Do not change unrelated files or reformat the whole project. Never commit signing identities, credentials, downloaded models, build output, private writing, or raw diagnostic logs.

Pull requests into `main` need an approving review from the maintainer and passing checks (tests, build, secret scan, CodeQL) before they can merge. Report security problems privately as described in [SECURITY.md](SECURITY.md), not in an issue.

## Corrections and model evaluation

**The model supplies the corrections.** Do not add hardcoded grammar rules, replacement dictionaries, or word lists to fix individual examples in application code. Improve the prompt, inference configuration, or model instead, and measure the result. Hardcoded examples belong in tests and evaluation fixtures. Structural output validation and replacement-safety checks are separate from generating corrections.

A useful correction report includes a short, invented or anonymized input, expected output, actual suggestion, selected model, tone, dialect, and suggestion strictness. Include examples of correct text that should stay unchanged. Do not use real customer messages or private documents as fixtures.

For model or prompt changes, report the dataset and its provenance, model/quantization, runtime revision, prompt variant, filtering thresholds, hardware, and scoring method. Include false positives on clean text and latency, not only successful corrections. Keep raw model output separate from post-processed app results. Token confidence is not a calibrated correctness score.

Obtain permission and check the license before adding third-party datasets or derived samples. A public download is not permission to redistribute. Keep restricted corpora outside the repository and document how authorized users can obtain them.

## Manual integration checks

Use disposable text or a test document. Check focus changes, typing while inference is running, selection offsets, emoji, multiline text, replacement, undo, and clipboard restoration. Verify pause behavior and that recognized secure fields and blocked apps are skipped.

Google Docs integration is experimental. Report whether reading, selection, and replacement each worked; do not describe a successful unit test or a single browser session as full Docs support. Keep Aure Pad's copy/paste workflow available when direct replacement is unreliable.

## Pull request checklist

- Explain the problem, link the related issue, and describe the observable change.
- Add or update tests and documentation for the behavior you changed.
- Include the results of `scripts/test.sh` and `scripts/lint.sh`; disclose skipped or failing checks.
- For UI and cross-app changes, include the manual checks and environment described above. Use only disposable text in screenshots.
- For model changes, include comparable before-and-after evaluation results, including false positives.
- Confirm that the diff contains no unrelated changes, private data, build artifacts, or unlicensed third-party material.

## Bug reports and security

For ordinary bugs, open a GitHub issue with reproduction steps and a minimal example. Review screenshots and logs before uploading them; remove private text, credentials, document identifiers, and local paths.

Do not disclose an exploitable vulnerability or credentials in a public issue. Use GitHub's private vulnerability reporting option if it is enabled. Otherwise ask the maintainer for a private reporting channel without posting sensitive details. This project does not promise a security-response SLA.

## Licensing

By submitting a contribution, you agree to make your original contribution available under the project's MIT License. Preserve third-party notices and disclose the origin and license of any copied or adapted code, assets, model files, or data. The project's MIT License does not relicense those materials.
