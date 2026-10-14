# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `gh` and Git act as a GitHub App per owner. Every use gets its own token for one repository, without the
  `workflows` permission; the token `gh` used is revoked when it exits, also when gh-touchid is interrupted or
  terminated (it passes SIGINT, SIGQUIT, SIGHUP and SIGTERM on to `gh`).
- `gh-touchid app create <owner> [--name <name>] [--no-open]` creates the owner's App from a manifest in your
  browser (GitHub's App manifest flow through a one-off page on `127.0.0.1`), checks that GitHub made it for that
  owner, and stores it after Touch ID; then it opens the App's installation page. `gh-touchid app set <owner>
  --client-id <id>` stores an App made by hand (its PKCS#1 private key on stdin, checked with GitHub).
- `gh-touchid session [--repo <owner/name>]...` registers the program that ran it, looking past shells that only run
  a command or a script; an interactive shell registers itself. Without `--repo`, it covers the outermost Git
  repository here and those nested up to two levels below it whose owner has an App. Its first GitHub use asks for
  Touch ID once; then it and everything it starts work without Touch ID for those repositories until it exits.
  Several first uses at once share one dialog. Outside a session, each per-use dialog comes with a hint to run
  `gh-touchid session`.
- Inside a session, other repositories that one of your Apps is installed on get issue-only tokens (issues write,
  contents and metadata read, never workflows): private ones without a dialog, public ones with Touch ID per use;
  Git gets them for private repositories only. The session's approval dialog says so.
- `gh-touchid elevate --for <duration> [--repo <owner/name>]...` lets tokens for the repositories include
  `workflows` for up to a day. It counts when a token is minted, after any Touch ID dialog.
- `gh-touchid user add <login>` stores a token of one of your GitHub accounts once GitHub confirms its login (it
  prints the token's scopes and warns about fine-grained tokens); `user remove <login>` deletes it. `gh-touchid as
  <login> <command>` acts as that account (`as <login> gh …` directly; anything else with `GH_TOUCHID_AS=<login>`,
  which `gh` and Git then honour), with Touch ID on every use, sessions included.
- The access log records every use, granted or refused, with the process chain, plus sessions registered, approved
  and ended, and elevations.
- Touch ID dialogs are withdrawn after five minutes without an answer.

### Changed

- **Breaking:** without a session, every `gh` and Git use asks for Touch ID naming the command and the processes
  that asked, and gets an App token instead of a stored token.
- **Breaking:** `gh` and Git refuse, before any Touch ID dialog, repositories whose owner has no App stored, and
  name your stored accounts to act as instead.
- **Breaking:** the Git credential helper answers only Git's HTTPS transport, so `git credential fill` gets nothing;
  configure it per owner in the global Git config with `credential.useHttpPath=true` (see the README).
- `gh` and Git pick the repository from `-R`/`--repo` (including `HOST/OWNER/REPO` and URLs) or `GH_REPO` before
  the current repository; Git uses the repository in the URL. When a flag right before `-R` might take a value,
  gh-touchid reads which flags take values from the pinned `gh`'s `help reference`, only for such ambiguous commands.
- **Breaking:** the Nix package pins `gh` at build time and no longer honours `GH_TOUCHID_GH`.
- `status` lists stored Apps and accounts (names only), sessions and elevations; `lock` ends sessions and
  elevations.

### Removed

- **Breaking:** `gh-touchid unlock` with `--all` and `--until-screen-lock`; sessions and elevation replace it.
- **Breaking:** `gh-touchid set` and the tokens it stored per repository; `user add` and `as` replace them.

### Security

- `gh auth` subcommands other than `auth status` are refused, as are `auth status -t` and the `ext`/`extensions`
  aliases of `gh extension`.
- The background agent and its clients trust each other only when they run the same gh-touchid executable.
