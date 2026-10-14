# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `gh` and Git act as a GitHub App per owner, stored with `gh-touchid app set <owner> --client-id <id>` (the
  App's PKCS#1 private key on stdin, checked with GitHub). Every use gets its own token for one repository, without
  the `workflows` permission; the token `gh` used is revoked when it exits, also after Ctrl-C.
- `gh-touchid session [--repo <owner/name>]...` registers the process that ran it. Its first GitHub use asks for
  Touch ID once; then it and everything it starts work without Touch ID for those repositories until it exits.
  Several first uses at once share one dialog.
- `gh-touchid elevate --for <duration> [--repo <owner/name>]...` lets tokens for the repositories include
  `workflows` for up to a day.
- `gh-touchid me <command>` runs a command with your own token (`me gh …` directly; anything else with
  `GH_TOUCHID_AS=me`, which `gh` and Git then honour), with Touch ID per use.
- The access log records every use, granted or refused, with the process chain, plus sessions registered, approved
  and ended, and elevations.
- Touch ID dialogs are withdrawn after five minutes without an answer.

### Changed

- **Breaking:** without a session, every `gh` and Git use asks for Touch ID naming the command and the processes
  that asked, and gets an App token instead of a stored token.
- **Breaking:** `gh-touchid set` stores your own token per owner (`--owner`, by default the current repository's
  owner) instead of per repository; tokens stored per repository by 0.2 are no longer read.
- **Breaking:** the Git credential helper answers only Git's HTTPS transport, so `git credential fill` gets nothing;
  configure it per owner in the global Git config with `credential.useHttpPath=true` (see the README).
- `gh` and Git pick the repository from `-R`/`--repo` (including `HOST/OWNER/REPO` and URLs) or `GH_REPO` before
  the current repository; Git uses the repository in the URL.
- **Breaking:** the Nix package pins `gh` at build time and no longer honours `GH_TOUCHID_GH`.
- `status` lists sessions and elevations; `lock` ends them all.

### Removed

- **Breaking:** `gh-touchid unlock` with `--all` and `--until-screen-lock`; sessions and elevation replace it.

### Security

- `gh auth` subcommands other than `auth status` are refused, as are `auth status -t` and the `ext`/`extensions`
  aliases of `gh extension`.
- The background agent and its clients trust each other only when they run the same gh-touchid executable.
