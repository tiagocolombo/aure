# Security policy

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue, pull request or discussion.

Use GitHub's private reporting: open the repository's **Security** tab, then **Report a vulnerability** (https://github.com/tiagocolombo/aure/security/advisories/new).

Include:

- what an attacker could do, and what they need first (local user, a malicious web page, a crafted model file, and so on);
- the steps to reproduce it, with the Aure version or commit, macOS version and Mac hardware;
- any proof of concept, using invented text only. Never send real private writing, credentials or personal data.

You should get a reply within 7 days. Aure is maintained by one person, so fixes are best effort. Once there is a fix, or 90 days have passed, we will agree on when to disclose. Reporters are credited unless they ask not to be.

## Supported versions

Aure is pre-1.0. Only the latest release and the `main` branch get security fixes.

## Scope

In scope:

- the Aure app and its helpers, including the bundled `llama-server` launch and its local API key;
- reading and replacing text through Accessibility, including clipboard save and restore;
- model downloads and checksum checks, GGUF import, and models found from other apps;
- build, signing and release scripts, and GitHub Actions workflows.

Out of scope:

- bugs in upstream llama.cpp itself (please report those upstream; tell us if Aure is affected);
- the quality of what a model suggests, unless the app applies text the user did not approve;
- attacks that need an administrator account or a Mac that is already compromised.

## What Aure is designed to do

- Your writing is processed on your Mac and is not sent over the network. The only network use is downloading a model you choose.
- `llama-server` listens only on `127.0.0.1`, on a random port, and requires a per-launch API key passed in a file only your account can read. Its slots endpoint, which would return the text being checked, is off. Aure only trusts the port once it has confirmed its own helper is listening on it.
- `llama-server` does not inherit Aure's Accessibility permission (it is spawned as its own TCC responsible process), gets an empty environment and no open files, and runs in a sandbox: no reading your home folder beyond the model's folder, no writing outside the temporary folders, no outgoing connections, no starting other programs. A release build only runs the helper in its own bundle, signed with the app's certificate.
- With the Ollama engine, text only goes to `127.0.0.1`/`localhost`, and only when the server on that port runs under your account.
- A model id saved in preferences only loads files inside the folders Aure scans for models. Model output is stripped of invisible characters (zero-width, bidirectional and tag characters) your text did not contain, so a review shows every change.
- Aure does not store the text it checks.
