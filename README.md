# gh-touchid

Touch ID-gated GitHub access for macOS.

`gh` and Git act as a GitHub App of yours (a bot) with short-lived tokens limited to one repository. Each use asks
for Touch ID, naming the command and the processes that asked, unless it comes from inside a session you approved.
Your own account is one Touch ID away with `gh-touchid me`.

- Every use gets its own token, minted for that use: one repository, about an hour long, without the `workflows`
  permission unless you elevate the repository for a while. The token `gh` used is revoked as soon as `gh` exits.
- A session is a process, such as an AI agent's harness, registered with `gh-touchid session`. Its first GitHub use
  asks for Touch ID once; after that it and everything it starts work unattended for the session's repositories
  until the process exits.
- The raw token goes only to the `gh` that gh-touchid starts and to Git's network transport.

## Setup

The Nix package provides `gh-touchid` and a transparent `gh` wrapper; see [Nix](#nix). gh-touchid works with the
`gh` pinned in the package, whichever `gh` is on your PATH.

### 1. A GitHub App per owner

Create one App for each account or organization whose repositories you work on (the *owner*):

1. On GitHub, open **Settings → Developer settings → GitHub Apps → New GitHub App** (for an organization, its own
   **Settings → Developer settings**).
2. Give it a name and any homepage URL. Under **Webhook**, clear **Active**.
3. Under **Repository permissions**, set:
   - **Contents**: Read and write
   - **Pull requests**: Read and write
   - **Issues**: Read and write
   - **Actions**: Read and write
   - **Workflows**: Read and write
   - **Checks**: Read-only
   - **Metadata**: Read-only

   Leave everything else, **Administration** in particular, at **No access**. gh-touchid leaves `workflows` out of
   every token unless you elevate the repository.
4. Under **Where can this GitHub App be installed?**, choose **Only on this account**, then **Create GitHub App**.
5. Note the **Client ID** (`Iv23li…`). Under **Private keys**, **Generate a private key**; the browser downloads a
   `.pem` file.
6. **Install App** on the owner, for all repositories or the ones agents should reach.

### 2. Store the App

```sh
gh-touchid app set OWNER --client-id Iv23li... < ~/Downloads/your-app.2026-10-14.private-key.pem
```

After Touch ID, gh-touchid checks the key with GitHub (`GET /app`) and stores the client ID and key in your login
Keychain (this Mac only, not synced). Delete the downloaded `.pem` afterwards. The key must be the PKCS#1 PEM GitHub
hands out (`-----BEGIN RSA PRIVATE KEY-----`).

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
Git where `gh-touchid` is on PATH.

### 4. Your own token (optional)

For things the App may not do, store a token of your own per owner (from hidden input, or from stdin):

```sh
gh-touchid set --owner OWNER
```

Without `--owner`, the owner of the current repository's `origin` is used.

## Everyday use

```sh
gh pr list
gh pr create --fill
git push
```

Outside a session, each command asks for Touch ID, e.g. "use GitHub for owner/repo: gh pr list (asked by
zsh[790] < Terminal[700])", then gets a token for that one repository. The repository is the one named with
`-R`/`--repo` (`OWNER/REPO`, `github.com/OWNER/REPO` or a URL), else `GH_REPO`, else the current repository's
`origin`; for Git, the repository in the URL.

To act as yourself rather than the App:

```sh
gh-touchid me gh pr merge 12      # gh with your own token
gh-touchid me git push            # any other command runs with GH_TOUCHID_AS=me, so Git's requests use your token
```

Each use asks for Touch ID ("run gh pr merge 12 as you on owner/repo"). `GH_TOUCHID_AS=me` in the environment does the
same for any `gh` or Git command.

## Sessions

```sh
gh-touchid session --repo owner/one --repo owner/two
```

registers the process that ran the command (the shell or agent harness that started `gh-touchid session`) for the
named repositories (by default the current one). The session is pending until its first GitHub use: then one Touch
ID dialog asks to "let omp in ~/devel/one (started 14:05) use GitHub for owner/one, owner/two until it exits". From
then on, the process and everything it starts get tokens for those repositories without Touch ID, until it exits.

- Other repositories, and processes outside the session, still ask for Touch ID per use.
- When several commands of a pending session start at once, one dialog covers them all.
- Running `session` again from the same process with the same repositories keeps its approval; other repositories
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
gh-touchid status    # sessions (pending or approved, program, folder, repositories) and elevations
gh-touchid lock      # ends every session approval and elevation now
```

Sessions and elevations live in a small background agent started by `session` or `elevate`. It holds no tokens or
keys, answers only processes running as you on a socket in your private temporary directory (`getconf
DARWIN_USER_TEMP_DIR`), and exits when nothing is left. Logging out or restarting ends everything too.

Every use, granted or refused, is logged to `~/Library/Logs/gh-touchid/access.log` with the chain of processes that
asked, e.g. `granted owner/one (session omp[700]), elevated to gh-touchid[812] < git-remote-https[811] < git[810] <
zsh[790] < omp[700]`, along with sessions registered, approved and ended, and elevations.

## Upgrading from 0.2

- `unlock` is gone: use `session` for unattended work, `elevate` for workflow changes.
- Tokens stored per repository (Keychain service `com.lubaretsi.gh-touchid`, account `owner/repo`) are no longer
  read. List them with `security find-generic-password -s com.lubaretsi.gh-touchid -a owner/repo` (this prints no
  secret) and delete each with `security delete-generic-password -s com.lubaretsi.gh-touchid -a owner/repo`. Your
  own tokens of 0.3 use the same service with the owner alone as the account; keep those.
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
- Starting a session is the user's decision: the user, or a harness plugin, runs `gh-touchid session --repo …` from
  the agent's process. The first GitHub use then shows the approval dialog; the user decides.
- `elevate` and `me` are the user's decision too: show the exact command, its repositories and duration before
  starting it.
- Storing the App key and your own token is human-only. Run `gh-touchid set` in an interactive PTY where the user
  types at the hidden prompt, and `app set` from the user's own terminal. Never request or accept a token or key
  through chat, tool arguments, environment dumps or agent messages.
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

- App tokens cover one repository, last about an hour, and leave out `workflows` unless the repository is elevated.
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
- The App key and your own tokens are generic passwords in your login Keychain, available only while this Mac is
  unlocked and never synced. This build is not signed with the hardened runtime, so the protection is enforced by
  gh-touchid itself: it asks for Touch ID or checks the session before using them, but macOS lets a process read
  the items once you allow it in the Keychain dialog or with your account password.
- Everything inside an approved session shares its access: any process the session's root starts, at any depth, gets
  tokens for the session's repositories without Touch ID until the root exits. Approve sessions for programs you
  trust, with the repositories they need.
- The background agent trusts only the gh-touchid executable it was started from: only that executable may approve a
  session or elevate a repository, and gh-touchid ignores an agent socket served by any other program. Any process
  running as you can register its parent as a pending session (which still needs your Touch ID), see the status, or
  `lock`.
- gh-touchid does not defend against code that already runs as you and sets out to tamper with it, for example by
  loading code into it (which an unsigned build without the hardened runtime allows) or by answering the Keychain
  dialogs. It makes token use visible, approved and short-lived; the access log shows who asked.
