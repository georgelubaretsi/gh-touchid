# gh-touchid

Touch ID-gated GitHub access for macOS.

`gh` and Git act as a GitHub App of yours (a bot) with short-lived tokens limited to one repository. Each use asks
for Touch ID in a window naming who asked, the command and the repository, unless it comes from inside a session you
approved. Your own GitHub accounts are one Touch ID away with `gh-touchid as <login>`.

- Every use gets its own token, minted for that use: one repository, about an hour long, without the `workflows`
  permission unless you elevate the repository for a while. The token `gh` used is revoked as soon as `gh` exits.
- A session is a process, such as an AI agent's harness, registered with `gh-touchid session`. Its first GitHub use
  asks for Touch ID once; after that it and everything it starts work unattended for the session's repositories
  until the process exits, and may open issues on your other repositories.
- The raw token goes only to the `gh` that gh-touchid starts and to Git's network transport.

## Install

gh-touchid runs on macOS 26 (Tahoe) or later, on Apple silicon and Intel Macs, and uses the `git` on your PATH. Every
way to install it gives you the same release: `gh-touchid`; a `gh` wrapper, `libexec/bin/gh`, that runs GitHub's CLI
through gh-touchid; and GitHub's own `gh` for macOS, which gh-touchid keeps next to itself in `libexec/gh-touchid`.
gh-touchid checks that `gh` by its SHA-256 before each use and lets it run only when the code that starts is GitHub's
(see [Security model](#security-model)); a changed `gh` there is refused ("the gh next to gh-touchid was changed;
reinstall gh-touchid").

Only `gh-touchid` goes on your PATH, so it installs beside any other `gh`, Homebrew's included. Git goes through
gh-touchid once you run `gh-touchid git-setup OWNER` (see [Git](#3-git)). `gh` goes through it only if you choose
one of these:

- Put the wrapper's folder first in PATH, in your shell's profile: every program that runs `gh` with that PATH gets
  gh-touchid's. The folder for each way to install is below; `gh-touchid status` prints it for yours.
- `alias gh='gh-touchid gh'`: your own interactive shell only; scripts and agents still find any other `gh`.
- Run `gh-touchid gh …` yourself.

Uninstalling another `gh` does not make `gh` gh-touchid's: without one of these, `gh` is simply not found. gh-touchid
never uses another `gh`'s login or configuration; it gives `gh` a fresh configuration and a token of its own. But
another `gh` that is signed in (`gh auth login`) stays usable by any program running as you, whichever `gh` comes
first on PATH: run `gh auth logout` with it, or uninstall it, for the full benefit. `gh-touchid status` says which
`gh` comes first on PATH and whether another one is signed in.

### Homebrew

```sh
brew install georgelubaretsi/tap/gh-touchid
```

It installs beside Homebrew's `gh` formula. To run `gh` through gh-touchid, put the wrapper's folder first in PATH;
Homebrew's `opt` link keeps the path the same across updates:

```sh
export PATH="/opt/homebrew/opt/gh-touchid/libexec/bin:$PATH"   # in your shell's profile; /usr/local/opt/… on Intel
```

### Release tarball

Download `gh-touchid-VERSION-macos.tar.gz` and its `.sha256` from the
[releases](https://github.com/GeorgeLubaretsi/gh-touchid/releases), check it, and unpack it into a folder that stays
put across updates:

```sh
shasum -a 256 -c gh-touchid-VERSION-macos.tar.gz.sha256
xattr -d com.apple.quarantine gh-touchid-VERSION-macos.tar.gz   # only for a download from a browser
mkdir -p ~/.local/gh-touchid
tar -xzf gh-touchid-VERSION-macos.tar.gz -C ~/.local/gh-touchid --strip-components 1
export PATH="$HOME/.local/gh-touchid/bin:$PATH"                 # in your shell's profile
export PATH="$HOME/.local/gh-touchid/libexec/bin:$PATH"         # also, to run `gh` through gh-touchid
```

A browser marks what it downloads as quarantined, and `tar` passes the mark on to the files it unpacks; macOS then
refuses to run the unsigned gh-touchid. Removing the attribute from the tarball before unpacking avoids that (or run
`xattr -dr com.apple.quarantine ~/.local/gh-touchid` afterwards). `curl` marks nothing. To update, unpack the new
tarball over the old folder the same way.

### Nix

The flake's default package installs the release tarball: no Xcode, and it builds with Nix's sandbox on. It holds
`bin/gh-touchid` and the wrapper in `libexec/bin`, no `bin/gh`. `packages.<system>.with-gh` is the same plus `bin/gh`,
a link to the wrapper, for replacing `gh` where you install it. Add either to a Darwin development shell:

```nix
{
  inputs.gh-touchid.url = "github:GeorgeLubaretsi/gh-touchid";

  outputs = { nixpkgs, gh-touchid, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          gh-touchid.packages.${system}.default   # gh-touchid only; .with-gh for `gh` through it too
          pkgs.git
        ];
      };
    };
}
```

Example `.envrc`:

```sh
use flake
```

To install it in your profile instead:

```sh
nix profile install github:GeorgeLubaretsi/gh-touchid           # gh-touchid only; `gh` stays as it is
nix profile install github:GeorgeLubaretsi/gh-touchid#with-gh   # also `gh`, through gh-touchid
```

`with-gh` cannot share a profile with another package that has `bin/gh`, such as nixpkgs' `gh`. The release Nix
installs is pinned in `release/nix.json`, which each release updates; until the first release, `default` builds from
source like `packages.<system>.from-source` (see [Building from source](#building-from-source)), which installs the
same files.

### Releases are unsigned, for now

gh-touchid's releases are not signed with a Developer ID or notarized (GitHub's `gh` inside is signed by GitHub).
What that costs:

- The login Keychain remembers **Always Allow** for one exact executable, so after each update macOS asks for your
  login Keychain password again the first time gh-touchid reads its items. Allow it only when the dialog names
  `gh-touchid`.
- Without the hardened runtime, another program running as you could load code into gh-touchid and use what
  gh-touchid can reach. gh-touchid does not defend against code that already runs as you (see
  [Security model](#security-model)).
- macOS refuses to run a quarantined copy, as from a browser download: remove the attribute as shown above.

## Setup

### 1. A GitHub App per owner

Create one App for each account or organization whose repositories you work on (the *owner*):

```sh
gh-touchid app create OWNER [--name NAME] [--no-open]
```

This opens a page on `127.0.0.1` in your browser that sends GitHub a manifest for a private App named `OWNER-agent`
(or `NAME`) with these repository permissions and no webhook:

- **Contents**, **Pull requests**, **Issues**, **Actions**, **Workflows**: Read and write
- **Checks**, **Commit statuses**, **Metadata**: Read-only

Choose **Create GitHub App** on GitHub. GitHub creates the App for the account you are signed in as in that browser
(or, when OWNER is an organization, for the organization), then sends the browser back to gh-touchid, which checks
that the App belongs to OWNER, asks for Touch ID, checks the App's key with GitHub (`GET /app`) and stores its client
ID and private key in your login Keychain (this Mac only, not synced); the client and webhook secrets are dropped.
If GitHub made the App for another account, nothing is stored and gh-touchid tells you where to delete it. Finally
it opens the App's installation page: **Install** it on the owner, for all repositories or the ones agents should
reach. `--no-open` prints the URLs instead, to open them in another browser profile; gh-touchid waits up to an hour.

gh-touchid leaves `workflows` out of every token unless you elevate the repository.

At the end, in a terminal, it asks `Set up Git for OWNER now? [Y/n]` and sets Git up for the owner's repositories
(step 3); without a terminal it prints the command instead.

### 2. Or store an App made by hand

For an App you created yourself (in **Settings → Developer settings → GitHub Apps**, with the permissions above,
**Administration** at **No access**, and **Only on this account**), or to rotate its key:

```sh
gh-touchid app set OWNER --client-id Iv23li... < ~/Downloads/your-app.2026-10-14.private-key.pem
```

After Touch ID, gh-touchid checks the key with GitHub and stores it like `app create`, and asks the same question
about Git. Delete the downloaded `.pem` afterwards. The key must be the PKCS#1 PEM GitHub hands out (`-----BEGIN RSA
PRIVATE KEY-----`).

### 3. Git

For each owner, let gh-touchid answer Git's HTTPS credential requests for that owner's repositories (`app create`
and `app set` offer to do this for you):

```sh
gh-touchid git-setup OWNER
```

writes these entries to your global Git configuration with `git config --global`, and prints them:

```ini
[credential "https://github.com/OWNER"]
	helper =
	helper = !/opt/homebrew/bin/gh-touchid git-credential
	useHttpPath = true
```

The empty first helper turns off any other helper (such as `osxkeychain`) for these repositories; `useHttpPath`
tells gh-touchid which repository Git is talking to. The path is one that survives updates: the first `gh-touchid`
on PATH that is this one, preferring a link such as `/opt/homebrew/bin/gh-touchid`,
`/etc/profiles/per-user/$USER/bin/gh-touchid` or `~/.nix-profile/bin/gh-touchid` over a path in Homebrew's Cellar or
the Nix store; if only such a versioned path exists, gh-touchid uses it and tells you to run `git-setup` again after
each update. Running `git-setup` again replaces its own entries and moves them to the end of the file, after any
broader `credential.helper` (as `gh auth setup-git` writes for all of github.com), whose helpers they turn off for
OWNER. Write OWNER as it appears in your remotes' URLs (Git compares it case-sensitively), and use HTTPS remotes
(`https://github.com/OWNER/REPO.git`). `gh-touchid status` says for each owner which helpers Git asks.

To push as one of your accounts to repositories of other owners (`gh-touchid as LOGIN git push`), configure the same
three settings for `https://github.com` as a whole instead; Git reads public repositories without asking, and for
other owners' private ones gh-touchid refuses unless you act as an account.

### 4. Your accounts (optional)

For things the App may not do, such as contributing to other people's repositories, store a token of each GitHub
account you want to act as (from hidden input, or from stdin):

```sh
gh-touchid user add LOGIN
gh-touchid user remove LOGIN
```

`user add` asks GitHub whose token it is (`GET /user`) and stores nothing unless it is LOGIN's; it prints the token's
scopes, asks for Touch ID and stores the token in your login Keychain (this Mac only, not synced). A fine-grained
token (`github_pat_…`) cannot contribute to public repositories the account is not a member of; gh-touchid warns
about it, and a classic token with the `repo` scope (plus `workflow` to change workflows) can. `user remove` deletes
the token without Touch ID.

## Everyday use

With `gh` going through gh-touchid (see [Install](#install)), or as `gh-touchid gh …`, and Git set up for the owner:

```sh
gh pr list
gh pr create --fill
git push
```

Outside a session, each command asks for Touch ID in the approval window (see below), naming the program that asked
and its folder (the full process chain goes to the access log). It then gets a token for that one repository, and
prints `To approve this whole session once, run: gh-touchid session` to stderr. The repository is the one named with
`-R`/`--repo` (`OWNER/REPO`, `github.com/OWNER/REPO` or a URL), else `GH_REPO`, else the current repository's
`origin`; for Git, the repository in the URL. When a flag right before `-R` might take a value (as in `gh issue create
--body -R`), gh-touchid reads which `gh` flags take values from the pinned `gh`'s `help reference`, only for such
ambiguous commands. If that cannot settle it, `as <login> gh …` is refused (an account's token is not limited to the
repository in the dialog).

For a repository whose owner has no App stored, `gh` and Git are refused before any Touch ID dialog, with a hint
naming your stored accounts.

To act as one of your accounts rather than the App:

```sh
gh-touchid as LOGIN gh pr merge 12    # gh with LOGIN's token
gh-touchid as LOGIN git push          # any other command runs with GH_TOUCHID_AS=LOGIN, which gh and Git honour
```

Every use asks for Touch ID, inside sessions too, with "as LOGIN (your account)", the command and, when there is
one, the repository (`gh api user` has none). Git gets LOGIN as the username.
`GH_TOUCHID_AS=LOGIN` in the environment does the same for any `gh` or Git command.

### The Touch ID window

Each Touch ID request opens a small floating window that takes the keyboard (for Esc) but leaves the app you are in
active: `gh-touchid`, "approval needed", then one fact per row: the action (`push`, `open pull request`, `store app
key`), the repository, the branch, title or command where they apply, the program that asked and its folder (`agent ·
~/code/widget`), who it acts as (your App's bot or one of your accounts) and the scope (`once`, `until agent quits`, a
duration), with the scope and any risk in orange. Nothing is shortened: every repository, the whole title, body (also
one given with `--body-file`) and command are shown, and a value too tall for the window scrolls in a box that says how
many lines it has. Touch the sensor to allow (its control sits beside what you allow, e.g. "allow once"), or press Esc
or click **deny**; after five minutes without an answer the window closes and the command fails. While the screen is
locked, nobody can answer, so the command fails at once with "the screen is locked, so nobody could approve this";
the same happens if the screen locks while a dialog is up. Where no window can be shown, such as over SSH, macOS's own
Touch ID sheet asks instead, in one line: "gh-touchid is trying to let agent run “git push” on owner/repo."

## Sessions

```sh
gh-touchid session
gh-touchid session --repo owner/one --repo owner/two
```

registers the program that ran the command, such as the shell in your terminal or an agent harness, for the named
repositories. Without `--repo` it takes the outermost Git repository containing the current folder and the Git
repositories nested up to two levels below it (an umbrella folder with clones inside), keeping those with a
github.com `origin` whose owner has an App stored. A shell that only runs a command or a script (`sh -c …`, `bash
script.sh`) is not the session: gh-touchid looks past such shells to the program that started them, so a harness
that runs `sh -c 'gh-touchid session'` registers itself; an interactive shell registers itself.

The session is pending until its first GitHub use: then one Touch ID window asks to let the program use those
repositories until it quits (and open issues in your other repositories), naming its folder and when it started.
From then on, the process and everything it starts get tokens for those repositories without Touch ID, until it
exits.

- Other repositories that one of your Apps is installed on get issue-only tokens (open and comment on issues, read
  the code; no workflows even when elevated). Private ones need no dialog; for a public one each use asks for Touch
  ID (the window marks the repository public), and the token is revoked if you decline. Git gets the issue-only token
  for a private repository (fetching works, pushing does not) and nothing for a public one, which it reads without a
  credential.
- Processes outside the session still ask for Touch ID per use; acting as an account always does.
- When several commands of a pending session start at once, one dialog covers them all.
- Sessions nest: for each repository, an approved session that lists it decides, even when a pending session that
  does not list it was registered further down.
- Running `session` again from the same program with the same repositories keeps its approval; other repositories
  make it pending again.
- gh-touchid knows nothing about agent tools. An agent harness, or a plugin of it, runs `gh-touchid session` at the
  start of its session; in a terminal, running it makes that shell a session.

## Elevating a repository

Tokens never include the `workflows` permission (needed to change `.github/workflows`) unless the repository is
elevated:

```sh
gh-touchid elevate --for 30m --repo owner/one
```

`--for` takes `30m`, `8h`, `1h30m` or `1d` (the longest). Each `--repo` names one repository; without one, the
current repository is elevated. Running `elevate` again sets a new end time. Elevation counts when a token is minted,
which is after any Touch ID dialog, so a command still waiting on a dialog when the elevation ends or `lock` runs
gets a token without `workflows`.

## Status and lock

```sh
gh-touchid status    # stored Apps and accounts (names only), for each owner which credential helpers Git asks,
                     # which `gh` comes first on PATH (gh-touchid's wrapper, another gh, or none) and whether
                     # another gh is signed in, sessions (pending or approved, program, folder, repositories) and
                     # elevations
gh-touchid lock      # ends every session approval and elevation now
gh-touchid version   # prints the version
```

`status` suggests `gh-touchid git-setup OWNER` when Git asks anything but this gh-touchid for an owner's
repositories. When the wrapper is not the first `gh` on PATH, it prints the PATH line for this installation (for
Homebrew the `opt` folder, which stays the same across updates) and the alias. When a `gh` other than the wrapper is on
PATH and a `gh` is signed in to github.com, it says so: `another gh is signed in as LOGIN: any program can use that
login; gh auth logout to close it`. It runs no other `gh` to tell: it looks only for an `oauth_token` in gh's
`hosts.yml` (in `GH_CONFIG_DIR`, `$XDG_CONFIG_HOME/gh` or `~/.config/gh`) and for gh's Keychain item `gh:github.com`,
by its attributes, never its secret.

Sessions and elevations live in a small background agent started by `session` or `elevate`. It holds no tokens or
keys, answers only processes running as you on a socket in your private temporary directory (`getconf
DARWIN_USER_TEMP_DIR`), and exits when nothing is left. Logging out or restarting ends everything too.

Every use, granted or refused, is logged to `~/Library/Logs/gh-touchid/access.log` with the chain of processes that
asked, e.g. `granted owner/one (session agent[700]), elevated to gh-touchid[812] < git-remote-https[811] < git[810] <
zsh[790] < agent[700]`, `granted owner/three (issues, session agent[700]) to …` or `granted owner/one (as LOGIN) to …`,
along with sessions registered, approved and ended, and elevations.

## Upgrading from 0.3.0

0.3.0 put its own `gh` in `bin/`; 0.3.1 and later keep it in `libexec/bin`, off your PATH unless you add it. After
upgrading, `gh` is whatever other `gh` comes first on PATH, or not found: choose one of the ways in
[Install](#install) to run it through gh-touchid again. Unpacking a newer tarball over 0.3.0 leaves 0.3.0's `bin/gh`
behind, still running `gh` through gh-touchid; delete it to use the PATH entry instead. Git, set up with
`git-setup`, is unaffected.

## Upgrading from 0.2

- `unlock` is gone: use `session` for unattended work, `elevate` for workflow changes.
- `set` and the tokens stored per repository (Keychain service `com.lubaretsi.gh-touchid`, account `owner/repo`) are
  gone: store a token per GitHub account with `user add` and use it with `as`. List the old items with `security
  find-generic-password -s com.lubaretsi.gh-touchid -a owner/repo` (this prints no secret) and delete each with
  `security delete-generic-password -s com.lubaretsi.gh-touchid -a owner/repo`.
- Create an App per owner with `app create` (or by hand and `app set`).
- Replace the per-repository `credential.helper` settings of 0.2 (`git config --local --unset-all
  credential.helper`) with `gh-touchid git-setup OWNER`.

## Building from source

gh-touchid is built with the Swift compiler of Xcode 26 or later, for arm64 and x86_64 in one universal executable.
Every task goes through the justfile, inside the dev shell (`nix develop`, or direnv), which has `just` and the
linters:

```sh
just build           # a development build in build/, which runs GH_TOUCHID_GH or the gh on PATH (scripts/build.sh)
just package         # the release tarball in dist/, as the release workflow builds it (scripts/package.sh)
just check-formula   # the Homebrew formula for dist/'s tarball, checked with a throwaway copy of the newest Homebrew
just lint            # the workflows with actionlint, the scripts with ShellCheck
```

`just check-formula` (`nix run .#check-formula`) renders the formula for the tarball, then runs `brew style`,
`brew audit --strict`, `brew install`, `brew test` and `brew linkage` with a copy of Homebrew's newest release made
for the check in `~/Library/Caches/gh-touchid/check-formula` and deleted after it, so it needs no sudo and never
touches the Homebrew you use. The release workflow runs the same checks on every pull request and tag, before
anything is published, and the tap runs `brew test-bot` on changes made there.

`--xcode` picks the Xcode (default `/Applications/Xcode.app`) and `--xcode-version` refuses any other version.
`scripts/package.sh` downloads GitHub's `gh` for macOS from the release pinned in `release/gh.json`, refuses it unless
its SHA-256 matches, and builds gh-touchid to run only that `gh`, checked by its SHA-256 and by the cdhashes of its
two slices (`scripts/build.sh` with `--gh ../libexec/gh-touchid/gh`, `--gh-sha256` and `--gh-cdhash`). Only
development builds honour `GH_TOUCHID_GH`.

The flake's `packages.<system>.from-source` builds through the same script with Xcode 27.0, which Nix cannot provide,
and pins nixpkgs' `gh` by its store path and SHA-256: install Xcode 27.0 at `/Applications/Xcode.app` and build with
Nix's sandbox off or relaxed (`sandbox = false` or `sandbox = relaxed` in `nix.conf`; the package sets
`__noChroot`). The build stops, naming the Xcode it needs, when it finds another version. For an Xcode installed
elsewhere, or another version at your own risk, override the package:

```nix
gh-touchid.packages.${system}.from-source.override {
  xcode = { version = "27.0"; path = "/Applications/Xcode-27.0.app"; };
}
```

## AI agent usage

This workflow has been tested only with [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) on macOS. Other agent
harnesses have not been verified to keep hidden PTY input and Git credential-helper traffic outside model context.

- Agents run ordinary `gh` and Git commands. Inside an approved session they need no Touch ID for the session's
  repositories and act as the App; anything else asks for Touch ID per use. For `gh`, the wrapper's folder must come
  first in the PATH the agent gets (an alias in your shell does not reach it).
- Starting a session is the user's decision: the user, or a harness plugin, runs `gh-touchid session` from the
  agent's process (a tool's `sh -c` counts as the agent). The first GitHub use then shows the approval dialog; the
  user decides. Outside a session, gh-touchid prints a hint to stderr with each per-use dialog.
- `elevate` and `as` are the user's decision too: show the exact command, its repositories and duration before
  starting it.
- Storing App keys and account tokens is human-only. Run `gh-touchid user add` in an interactive PTY where the user
  types at the hidden prompt, and `app create`/`app set` from the user's own terminal. Never request or accept a
  token or key through chat, tool arguments, environment dumps or agent messages.
- Use an OMP supervised PTY for commands waiting on Touch ID so normal conversation does not abort the process.
- On first use, and after each update (releases are unsigned), macOS may ask for the login Keychain password. Choose
  **Always Allow** only when the dialog names `gh-touchid` and a `com.lubaretsi.gh-touchid` item; deny it if it names
  Terminal, `security`, `gh` or another process. Never ask for, enter, or handle the user's Mac password.
- If Touch ID is declined or not answered (dialogs close after five minutes), stop and report it. Do not inspect the
  Keychain, switch credentials, or fall back to other GitHub authentication.
- Never invoke credential-revealing paths such as `gh auth token`, `git credential fill`, `gh-touchid
  git-credential get` or `security find-generic-password -w`, and never talk to the agent's socket directly.
- Never enable shell or HTTP tracing around authenticated commands, including `set -x`, `GIT_TRACE`,
  `GIT_TRACE_CURL`, `GIT_CURL_VERBOSE` or `GH_DEBUG`.
- Treat command stdout and stderr as model-visible. Tokens are meant only for the pinned `gh` child and Git's
  credential pipe and must never be printed or inspected.

## Security model

- App tokens cover one repository, last about an hour, and leave out `workflows` unless the repository is elevated;
  issue-only tokens for repositories a session does not list never include it.
  The token of a `gh` command is revoked when `gh` exits; SIGINT, SIGQUIT, SIGHUP and SIGTERM sent to gh-touchid
  are passed on to `gh` and the token is still revoked (SIGKILL leaves it to run out). Tokens given to Git are not
  revoked and run out on their own.
- Tokens are never cached or written to disk, and never exported to the calling shell. `gh` gets one through
  `GH_TOKEN` with a fresh empty `GH_CONFIG_DIR`; Git gets one through its credential-helper pipe, and only when the
  request comes from Git's HTTPS transport (`git-remote-https`) with stdout not a terminal.
- Programs that `gh` itself starts while it runs (your editor or browser, Git and the repository's hooks, installed
  `gh` extensions) inherit its environment, token included.
- `gh` commands that would print or store the token, or install aliases or extensions, are refused: `auth` other than
  `auth status` (and `auth status -t`), `--show-token`, `alias`, `extension`.
- Your accounts' tokens are as long-lived and broad as you made them on GitHub, and are never revoked here: every
  use asks for Touch ID and names the command, the repository and who asked, and the token goes only to the `gh`
  that gh-touchid starts or to Git's transport.
- The App keys and your accounts' tokens are generic passwords in your login Keychain, available only while this Mac
  is unlocked and never synced. `status`, the hint and the checks before a dialog read only which items exist and the
  App's name (its slug, kept in the item's comment), never a secret; `status` also asks whether gh's own item
  `gh:github.com` exists, by its attributes alone. Releases are not signed and run without the hardened runtime, so
  the protection is enforced by gh-touchid itself: it asks for Touch ID or checks the session before using them, but
  macOS lets a process read the items once you allow it in the Keychain dialog or with your account password.
- A `gh` signed in on its own (`gh auth login`, with its token in the Keychain or in its `hosts.yml`) is a way to
  GitHub that gh-touchid does not gate: any program running as you can use that login, whatever `gh` comes first on
  PATH. `status` says when one is; `gh auth logout` with that `gh` closes it.
- gh-touchid runs only the `gh` it was built with, and no environment variable changes which one:
  - A release (the tarball, Homebrew, and the flake's default package, which installs the release) bundles GitHub's
    `gh` in `libexec/gh-touchid`, where any program running as you can write, as in all of Homebrew's folders.
    gh-touchid checks that file's SHA-256 before minting a token. It then starts `gh` suspended, before its first
    instruction, and lets it run only if the code the kernel loaded for it (the slice that runs, natively or under
    Rosetta) has the code directory hash (cdhash) of GitHub's `gh` pinned at build time; otherwise, or if that
    cannot be read, `gh` is killed unrun. Replacing the installed `gh` after the check therefore cannot hand the
    token to another program. GitHub's `gh` runs with the hardened runtime, so a page changed after it starts gets
    it killed.
  - The Nix build from source (`packages.<system>.from-source`) runs nixpkgs' `gh` by its store path and checks its
    SHA-256, without a cdhash: nixpkgs' `gh` is a wrapper script, and the read-only Nix store is what keeps it from
    being replaced.
- Everything inside an approved session shares its access: any process the session's root starts, at any depth, gets
  tokens for the session's repositories without Touch ID until the root exits, and can open issues on (and read)
  every private repository your Apps are installed on. Approve sessions for programs you trust, with the
  repositories they need.
- The background agent trusts only the gh-touchid executable it was started from: only that executable may approve a
  session or elevate a repository, and gh-touchid ignores an agent socket served by any other program. Any process
  running as you can register its parent (or the program above its non-interactive shells) as a pending session,
  which still needs your Touch ID, see the status, or `lock`.
- `app create` listens on `127.0.0.1` until GitHub sends the browser back, at most an hour, and accepts only the
  answer carrying the random `state` it gave GitHub; the new App's key goes from GitHub's reply straight to the
  Keychain.
- gh-touchid does not defend against code that already runs as you and sets out to tamper with it, for example by
  loading code into it (which an unsigned build without the hardened runtime allows) or by answering the Keychain
  dialogs. It makes token use visible, approved and short-lived; the access log shows who asked.
