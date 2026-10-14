# gh-touchid

Touch ID-gated GitHub access for macOS.

`gh` and Git act as a GitHub App of yours (a bot) with short-lived tokens limited to one repository. Each use asks
for Touch ID, naming the command and the processes that asked, unless it comes from inside a session you approved.
Your own GitHub accounts are one Touch ID away with `gh-touchid as <login>`.

- Every use gets its own token, minted for that use: one repository, about an hour long, without the `workflows`
  permission unless you elevate the repository for a while. The token `gh` used is revoked as soon as `gh` exits.
- A session is a process, such as an AI agent's harness, registered with `gh-touchid session`. Its first GitHub use
  asks for Touch ID once; after that it and everything it starts work unattended for the session's repositories
  until the process exits, and may open issues on your other repositories.
- The raw token goes only to the `gh` that gh-touchid starts and to Git's network transport.

## Setup

The Nix package provides `gh-touchid` and a transparent `gh` wrapper; see [Nix](#nix). gh-touchid works with the
`gh` pinned in the package, whichever `gh` is on your PATH.

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

### 2. Or store an App made by hand

For an App you created yourself (in **Settings → Developer settings → GitHub Apps**, with the permissions above,
**Administration** at **No access**, and **Only on this account**), or to rotate its key:

```sh
gh-touchid app set OWNER --client-id Iv23li... < ~/Downloads/your-app.2026-10-14.private-key.pem
```

After Touch ID, gh-touchid checks the key with GitHub and stores it like `app create`. Delete the downloaded `.pem`
afterwards. The key must be the PKCS#1 PEM GitHub hands out (`-----BEGIN RSA PRIVATE KEY-----`).

### 3. Git

For each owner, let gh-touchid answer Git's HTTPS credential requests for that owner's repositories, in your global
Git configuration:

```sh
git config --global credential.https://github.com/OWNER.helper ''
git config --global --add credential.https://github.com/OWNER.helper '!gh-touchid git-credential'
git config --global credential.https://github.com/OWNER.useHttpPath true
```

The empty first helper turns off any other helper (such as `osxkeychain`) for these repositories; `useHttpPath`
tells gh-touchid which repository Git is talking to. Use HTTPS remotes (`https://github.com/OWNER/REPO.git`), and run
Git where `gh-touchid` is on PATH. To push as one of your accounts to repositories of other owners (`gh-touchid as
LOGIN git push`), configure the same three settings for `https://github.com` as a whole instead; Git reads public
repositories without asking, and for other owners' private ones gh-touchid refuses unless you act as an account.

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

```sh
gh pr list
gh pr create --fill
git push
```

Outside a session, each command asks for Touch ID, e.g. "gh-touchid is trying to let omp run “gh pr list” on
owner/repo", naming the program that asked (the full process chain goes to the access log). It then gets a token
for that one repository, and prints `To approve this whole session once, run: gh-touchid session` to stderr. The
repository is the one named with `-R`/`--repo` (`OWNER/REPO`,
`github.com/OWNER/REPO` or a URL), else `GH_REPO`, else the current repository's `origin`; for Git, the repository
in the URL. When a flag right before `-R` might take a value (as in `gh issue create --body -R`), gh-touchid reads
which `gh` flags take values from the pinned `gh`'s `help reference`, only for such ambiguous commands. If that
cannot settle it, `as <login> gh …` is refused (an account's token is not limited to the repository in the dialog).

For a repository whose owner has no App stored, `gh` and Git are refused before any Touch ID dialog, with a hint
naming your stored accounts.

To act as one of your accounts rather than the App:

```sh
gh-touchid as LOGIN gh pr merge 12    # gh with LOGIN's token
gh-touchid as LOGIN git push          # any other command runs with GH_TOUCHID_AS=LOGIN, which gh and Git honour
```

Every use asks for Touch ID, inside sessions too: "let omp act as LOGIN: “gh pr merge” on owner/repo", without the
repository for commands outside one such as `gh api user`. Git gets LOGIN as the username.
`GH_TOUCHID_AS=LOGIN` in the environment does the same for any `gh` or Git command.

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

The session is pending until its first GitHub use: then one Touch ID dialog asks to "let omp use owner/one and two
until it quits, and open issues in your other repos (started 14:05 in ~/devel/one)". From then on, the process and
everything it starts get tokens for those repositories without Touch ID, until it exits.

- Other repositories that one of your Apps is installed on get issue-only tokens (open and comment on issues, read
  the code; no workflows even when elevated). Private ones need no dialog; for a public one each use asks for Touch
  ID ("let omp run “gh issue create” on public owner/three"), and the token is revoked if you decline. Git gets the
  issue-only token for a private repository (fetching works, pushing does not) and nothing for a public one, which
  it reads without a credential.
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
gh-touchid status    # stored Apps and accounts (names only), sessions (pending or approved, program, folder,
                     # repositories) and elevations
gh-touchid lock      # ends every session approval and elevation now
```

Sessions and elevations live in a small background agent started by `session` or `elevate`. It holds no tokens or
keys, answers only processes running as you on a socket in your private temporary directory (`getconf
DARWIN_USER_TEMP_DIR`), and exits when nothing is left. Logging out or restarting ends everything too.

Every use, granted or refused, is logged to `~/Library/Logs/gh-touchid/access.log` with the chain of processes that
asked, e.g. `granted owner/one (session omp[700]), elevated to gh-touchid[812] < git-remote-https[811] < git[810] <
zsh[790] < omp[700]`, `granted owner/three (issues, session omp[700]) to …` or `granted owner/one (as LOGIN) to …`,
along with sessions registered, approved and ended, and elevations.

## Upgrading from 0.2

- `unlock` is gone: use `session` for unattended work, `elevate` for workflow changes.
- `set` and the tokens stored per repository (Keychain service `com.lubaretsi.gh-touchid`, account `owner/repo`) are
  gone: store a token per GitHub account with `user add` and use it with `as`. List the old items with `security
  find-generic-password -s com.lubaretsi.gh-touchid -a owner/repo` (this prints no secret) and delete each with
  `security delete-generic-password -s com.lubaretsi.gh-touchid -a owner/repo`.
- Create an App per owner with `app create` (or by hand and `app set`).
- Replace the per-repository `credential.helper` settings of 0.2 (`git config --local --unset-all
  credential.helper`) with the per-owner global ones above.

## Nix

Add the package to a Darwin development shell:

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
          gh-touchid.packages.${system}.default
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

The package pins `gh` at build time and ignores `GH_TOUCHID_GH`. A development build of the sources (`swiftc
Sources/GHTouchID/*.swift`) runs `GH_TOUCHID_GH` or the `gh` on PATH.

## AI agent usage

This workflow has been tested only with [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) on macOS. Other agent
harnesses have not been verified to keep hidden PTY input and Git credential-helper traffic outside model context.

- Agents run ordinary `gh` and Git commands. Inside an approved session they need no Touch ID for the session's
  repositories and act as the App; anything else asks for Touch ID per use.
- Starting a session is the user's decision: the user, or a harness plugin, runs `gh-touchid session` from the
  agent's process (a tool's `sh -c` counts as the agent). The first GitHub use then shows the approval dialog; the
  user decides. Outside a session, gh-touchid prints a hint to stderr with each per-use dialog.
- `elevate` and `as` are the user's decision too: show the exact command, its repositories and duration before
  starting it.
- Storing App keys and account tokens is human-only. Run `gh-touchid user add` in an interactive PTY where the user
  types at the hidden prompt, and `app create`/`app set` from the user's own terminal. Never request or accept a
  token or key through chat, tool arguments, environment dumps or agent messages.
- Use an OMP supervised PTY for commands waiting on Touch ID so normal conversation does not abort the process.
- On first use, and sometimes after an upgrade, macOS may ask for the login Keychain password. Choose **Always Allow**
  only when the dialog names `gh-touchid` and a `com.lubaretsi.gh-touchid` item; deny it if it names Terminal,
  `security`, `gh` or another process. Never ask for, enter, or handle the user's Mac password.
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
  is unlocked and never synced. `status`, the hint and the checks before a dialog read only which items exist. This build is not signed with the hardened runtime, so the protection is enforced by
  gh-touchid itself: it asks for Touch ID or checks the session before using them, but macOS lets a process read
  the items once you allow it in the Keychain dialog or with your account password.
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
