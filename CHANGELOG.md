# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Approved sessions survive upgrades. Every release you have installed shares one background agent (`agent.sock`);
  after an upgrade the old release's agent keeps serving until its sessions end. Sessions approved under 0.4.0 or
  0.4.1 keep working too, and `status` and `lock` include their agent.
- `release/known-releases`: the releases a release trusts, by cdhash; one marked `revoked` is no longer trusted, and
  the first gh-touchid that meets its agent locks it, carrying nothing over: its sessions need `gh-touchid session`
  again.
- `session` warns on stderr, once registered, for each owner of its repositories whose Git does not ask this
  gh-touchid alone, and when the `gh` first on PATH is not gh-touchid's wrapper, with the same fixes as `status`.

### Changed

- gh-touchid and its agent trust each other by the kernel's view of the running code (valid signature, hardened
  runtime, cdhash, or gh-touchid's Developer ID for a later release), not by the executable's path. An agent it cannot
  verify is left alone, each use asks for Touch ID, and `status` names the program holding the socket.
- Agent requests and replies carry a protocol version; a protocol the agent does not speak is refused before anything
  is done.

### Fixed

- `status` no longer advises `gh-touchid git setup OWNER` when the credential helpers are overridden in the
  repository's own configuration (or its worktree file, or the environment), which `git setup` cannot change: it
  names the file and the command that removes the setting, such as `git config --local --unset-all credential.helper`.
- Two agents starting at once could delete each other's socket; starting and stopping now take `agent.lock`, and an
  agent deletes only the socket it made.

## [0.4.1] - 2026-10-23

### Added

- Every stored item (App, sign-in, account token) says its format in its Keychain description: `gh-touchid format 1`.
  Items 0.4.0 stored without one are format 1. An item a newer gh-touchid stored in a later format is refused before
  any Touch ID, and `status` marks it "stored by a newer gh-touchid: upgrade it"; so is an item whose description says
  no format at all, with the command that stores it again.

### Removed

- Recognizing an App stored by 0.3.1 or earlier: such an item is now reported as not valid, like any other unreadable
  one; `app create` replaces it.

## [0.4.0] - 2026-10-23

### Added

- A justfile: `just build`, `just package`, `just check-formula` and `just lint`, inside the dev shell, which now
  has `just`, actionlint and ShellCheck.
- `just check-formula` (`nix run .#check-formula`) installs and tests the Homebrew formula for a tarball with a
  throwaway copy of Homebrew's newest release, after `brew style` and `brew audit --strict`; it never touches the
  Homebrew you use.
- `gh-touchid app login <owner>` signs you in to the owner's App again, once the sign-in has ended.
- `status` says for each owner's App who is signed in to it, or the `app login` to run.
- A test suite (`just test`): a test build against a mock GitHub, run on every pull request and push to main, and
  before each release.
- `gh-touchid help <command>` and `gh-touchid <command> --help` print one command's usage; a wrong use of a
  command prints that command's usage instead of every command's.
- `as <login> -- <command>`: a `--` before the command is accepted, and optional.
- SECURITY.md says how to report a vulnerability privately; docs/threat-model.md describes what gh-touchid protects,
  from whom, and what is out of scope.

### Changed

- The release workflow builds the tarball with `just package` and lints and runs the formula check on every pull
  request and tag, before publishing, and renders the published formula with the same `scripts/render-formula.sh`.
- **Breaking:** `gh` and Git act as you, not as the App's bot. Each use gets a token narrowed from your sign-in to
  the owner's App: still one repository and no `workflows` unless elevated, and revoked when `gh` exits, but your
  account on GitHub, so Codex reviews agents' pull requests and answers their `@codex review`. A narrowed token lasts
  as long as your sign-in's access token (one to eight hours), so tokens given to Git live longer than the hour they
  used to. Apps stored by 0.3.1 and earlier are refused: run `gh-touchid app create <owner>` for each owner (see
  "Upgrading from 0.3.1" in the README).
- **Breaking:** `app create` also signs you in: after **Create GitHub App**, the browser goes on to the App's
  **Authorize** page, then to its installation page; one Touch ID stores the App and your sign-in. It listens on the
  fixed port 47911, which the App lists as its callback URL.
- **Breaking:** `app set <owner> --client-id <id>` takes the App's client secret (hidden input or stdin) instead of
  its private key, and signs you in; the App must list `http://127.0.0.1:47911/callback` as a callback URL.
- Dialogs name who a use acts as: you, via the App.
- Development builds (`just build`) keep their own Keychain items (`com.lubaretsi.gh-touchid.dev.*`), so trying one
  never reads or replaces an installed gh-touchid's Apps, sign-ins and tokens.
- **Breaking:** `user add` and `user remove` are now `account add` and `account remove`.
- **Breaking:** `git-setup <owner>` is now `git setup <owner>`, and the credential helper `git-credential` is now
  `git credential`. Run `gh-touchid git setup <owner>` again for each owner: it replaces the old helper entry, which
  no longer works.
- `app create` names a new App `<owner>-touchid` (was `<owner>-agent`), so it does not clash with an App made by
  0.3.1 and earlier.

### Removed

- The App's private key: gh-touchid no longer stores or uses it, so nothing it holds can act as the App's bot.

### Fixed

- The Homebrew formula failed to load ("Calling `depends_on :macos` with `depends_on macos:` is disabled"); it now
  states only `depends_on macos: :tahoe`, which also limits it to macOS.
- `gh api repos/OWNER/REPO/…` got a token for `GH_REPO` or the current folder's repository instead of the one its
  endpoint names, so from an umbrella folder it failed with 404.

### Security

- Releases are signed with a Developer ID, run with the hardened runtime, and are notarized: on a `v*` tag the
  release workflow signs `bin/gh-touchid` (`scripts/sign.sh`, with the certificate and notary key of the `release`
  environment), has Apple notarize it, repacks the tarball, checks it again and publishes only the signed one.
  Other programs running as you can no longer load code into a release, the Keychain trusts gh-touchid by its
  signature so **Always Allow** lasts across updates (items allowed for an unsigned release ask once more), and a
  quarantined download runs after macOS checks it with Apple. GitHub's `gh` inside is unchanged. Development builds
  and the flake's build from source stay ad hoc signed, without the hardened runtime.

## [0.3.1] - 2026-10-16

### Changed

- Running `gh` through gh-touchid is opt-in. The release puts only `gh-touchid` in `bin/`; the `gh` wrapper moves to
  `libexec/bin/gh`, which runs the installation's own `gh-touchid` wherever it is linked from. Put that folder first
  in PATH (Homebrew: `/opt/homebrew/opt/gh-touchid/libexec/bin`, the same across updates), use
  `alias gh='gh-touchid gh'`, or run `gh-touchid gh …`. After upgrading from 0.3.0, `gh` no longer goes through
  gh-touchid until you choose one; Git, set up with `git-setup`, is unaffected.
- The Homebrew formula installs `gh-touchid` and `libexec`, and its caveats say how to route `gh` and that a
  signed-in Homebrew `gh` stays usable by any program running as you.
- The flake's `default` and `from-source` packages install `bin/gh-touchid` and the wrapper in `libexec/bin`, no
  `bin/gh`; the new `with-gh` package adds `bin/gh`, a link to the wrapper, to replace `gh` in a profile.
- `gh-touchid status` says whether the first `gh` on PATH is this gh-touchid's wrapper, another `gh` (named), or
  none, and otherwise prints the PATH line for this installation (Homebrew's `opt` folder for a Cellar install) and
  the alias. When a `gh` other than the wrapper is on PATH and a `gh` is signed in to github.com, it says so and
  suggests `gh auth logout`. It runs no other `gh` for this: it looks for an `oauth_token` in gh's `hosts.yml` and
  for gh's `gh:github.com` Keychain item by its attributes only.

### Fixed

- gh-touchid installs beside Homebrew's `gh`: the formula no longer conflicts with it, so it no longer has to be
  uninstalled first.
- `status` no longer suggests removing another `gh`, which never made `gh` gh-touchid's.

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
