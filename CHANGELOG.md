# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-15

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
- Touch ID dialogs are withdrawn after five minutes without an answer. While the screen is locked, a request fails at
  once saying so, instead of looking like a declined Touch ID.
- Touch ID asks in a small window of its own instead of macOS's sheet: one fact per row (the action, the repository,
  the branch, title, body or command where they apply, the program that asked and its folder, the App's bot or your
  account it acts as, and the scope), nothing shortened (a value too tall scrolls in its own box), the scope and risks
  in orange, and Touch ID right in the window beside what it
  allows ("allow once"), with **deny** on Esc. The window takes the keyboard without activating gh-touchid. `app set`
  and `app create` store the App's slug with it, so the window can name the bot. Where no window can be shown, such
  as over SSH, macOS's own sheet asks in one line as before.
- Releases for everyone, unsigned for now: each `v*` tag publishes `gh-touchid-<version>-macos.tar.gz` (one
  universal executable, a `gh` that runs `gh-touchid gh`, and GitHub's own `gh` for macOS in `libexec/gh-touchid`) as
  a GitHub release, built by `.github/workflows/release.yml`. `brew install georgelubaretsi/tap/gh-touchid` installs
  it from a formula the release job pushes to the tap, and the flake's default package installs it with Nix (no
  Xcode, sandbox on), pinned in `release/nix.json`; the build from source is `packages.<system>.from-source`.
- `gh-touchid git-setup <owner>` writes the owner's credential entries to the global Git configuration (an empty
  helper, `!<path> git-credential` by a path that survives updates, `useHttpPath`), replacing its earlier ones and
  moving them after any broader helper, and prints them. `app create` and `app set` end by asking, in a terminal,
  whether to set up Git for the owner now, and print the command otherwise.
- `status` says for each owner which credential helpers Git asks and whether `gh` on PATH is gh-touchid's, with the
  fix when not.
- `gh-touchid version` prints the version.
- `scripts/build.sh` builds the universal executable (Xcode 26 or later); `scripts/package.sh` builds the release
  tarball.

### Changed

- **Breaking:** without a session, every `gh` and Git use asks for Touch ID and gets an App token instead of a
  stored token. Dialogs name the program that asked, the command and the repository in plain words; the full process
  chain goes to the access log.
- **Breaking:** `gh` and Git refuse, before any Touch ID dialog, repositories whose owner has no App stored, and
  name your stored accounts to act as instead.
- **Breaking:** the Git credential helper answers only Git's HTTPS transport, so `git credential fill` gets nothing;
  set it up per owner with `gh-touchid git-setup <owner>`.
- **Breaking:** building needs Xcode 26 or later (`scripts/build.sh`); the Nix build from source pins Xcode 27.0 (at
  `/Applications/Xcode.app`, or wherever the package's `xcode` argument points) and needs Nix's sandbox off or
  relaxed; nixpkgs' Swift can no longer build gh-touchid, and the development shell no longer provides it.
- `gh` and Git pick the repository from `-R`/`--repo` (including `HOST/OWNER/REPO` and URLs) or `GH_REPO` before
  the current repository; Git uses the repository in the URL. When a flag right before `-R` might take a value,
  gh-touchid reads which flags take values from the pinned `gh`'s `help reference`, only for such ambiguous commands;
  `as <login> gh …` is refused when that cannot settle it.
- **Breaking:** release and Nix builds run only the `gh` they ship and no longer honour `GH_TOUCHID_GH`.
- The Nix package installs the executable itself as `bin/gh-touchid` and no longer puts nixpkgs' Git on its PATH.
- `status` lists stored Apps and accounts (names only), sessions and elevations; `lock` ends sessions and
  elevations.

### Removed

- **Breaking:** `gh-touchid unlock` with `--all` and `--until-screen-lock`; sessions and elevation replace it.
- **Breaking:** `gh-touchid set` and the tokens it stored per repository; `user add` and `as` replace them.

### Security

- `gh auth` subcommands other than `auth status` are refused, as are `auth status -t` and the `ext`/`extensions`
  aliases of `gh extension`.
- The background agent and its clients trust each other only when they run the same gh-touchid executable.
- gh-touchid checks the SHA-256 of the `gh` it ships before minting a token and refuses a changed one ("the gh next
  to gh-touchid was changed; reinstall gh-touchid"). A release then starts GitHub's `gh` suspended and lets it run
  with the token only if the code the kernel loaded has one of the cdhashes pinned at build time; otherwise `gh` is
  killed before it runs. The Nix build from source relies on the read-only store instead.
