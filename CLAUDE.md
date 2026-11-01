# HephaestusV2

`docs/` is the specification of this app. Read [docs/README.md](docs/README.md) first, then the documents your change touches. The rules below come from [docs/workflow.md](docs/workflow.md) and [docs/development.md](docs/development.md); those documents win when this file and they differ.

## Docs first

- A change of behaviour first rewrites the affected docs sections so that they describe the result completely; then the code changes until it does what they say. Both go into the same commit.
- Never invent a requirement, a behaviour, a text shown to users, a file format or a product decision. Take them from the docs, the ticket or the user; ask when they are unknown.
- Keep every docs file linked from `docs/README.md`, follow the conventions of [docs/README.md › Conventions](docs/README.md#conventions), and keep tables aligned: `python3 -I scripts/tables.py --fix <files>`.
- A new user requirement goes into `docs/requirements.md` and the `Requirements covered` section of each docs file that fulfils it.
- HephaestusV2 is written from these docs only: nothing is read or taken from its first version (v1).

## Code

- Modules, folders and file locations: [docs/architecture.md › Modules](docs/architecture.md#modules) and [Repository layout](docs/architecture.md#repository-layout). Keep each type in the folder the docs assign.
- Build and test with `swift build` and `swift test`; the make targets are in [docs/ci.md › Local make targets](docs/ci.md#local-make-targets). The docs conformance tests run with `swift test` and must pass.
- Tests use Swift Testing, create their own temporary directories, and never touch the default data directory, `~/.claude` or the user's projects ([docs/development.md › Tests](docs/development.md#tests)).
- Check the user interface only on an isolated offscreen instance through the debug MCP tools, never on the app the user is running ([docs/development.md › Automated UI checks](docs/development.md#automated-ui-checks)).
- Never create, edit or delete files inside a `.hephaestus` folder yourself.

## Public repository

Never commit personal data: real names, e-mail addresses, home paths, device names or team ids. Write `user@example.com`, `/Users/example`, `Studio` or `MacBook` instead. Fixtures are sanitized before they are committed ([docs/development.md › Sanitizing a capture](docs/development.md#sanitizing-a-capture)).

## Commits and pushes

- Conventional commits ([docs/workflow.md › Commits](docs/workflow.md#commits)): `<type>: <summary> (<TICKET-ID>)` for a ticket, `<type>: <summary>` otherwise; types `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`; no scope; imperative summary; first line at most 72 characters.
- Stage by path only the files you changed; never `git add -A` or `git add .`, never stage `.hephaestus/`.
- Never amend or rebase a pushed commit, skip hooks, force-push or change the git configuration.
- Every push to `main` starts a release that installed copies of the app pick up ([docs/workflow.md › Self-update loop](docs/workflow.md#self-update-loop)), so `main` always passes the checks and the tests.
