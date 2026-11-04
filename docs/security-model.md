# Security model

gh-touchid makes token use visible, approved and short-lived, and the access log shows who asked. It does not defend
against code that already runs as you ([below](#what-gh-touchid-does-not-defend-against)). The full threat model is in
[docs/threat-model.md](threat-model.md); to report a vulnerability, see [SECURITY.md](../SECURITY.md).

## Tokens and what they reach

- Every token gh-touchid makes acts as you, except the reader's ([below](#the-reader)). It is narrowed from your
  sign-in to the owner's App (`POST /applications/{client_id}/token/scoped`) to one repository, without `workflows`
  unless the repository is elevated. Issue-only tokens never include `workflows`.
- A narrowed token lasts as long as the sign-in's access token: at most 8 hours, at least one. gh-touchid renews the
  sign-in when less than an hour is left.
- The token of a `gh` command is revoked when `gh` exits. SIGINT, SIGQUIT, SIGHUP and SIGTERM sent to gh-touchid are
  passed on to `gh`, and the token is still revoked. SIGKILL leaves it to run out.
- Tokens given to Git are not revoked. They run out on their own.
- Narrowed tokens are never cached, never written to disk, and never exported to the calling shell.
- `gh` gets its token through `GH_TOKEN`, with a fresh empty `GH_CONFIG_DIR`. Programs `gh` starts while it runs
  inherit that environment, token included: your editor or browser, Git and the repository's hooks, and installed
  `gh` extensions.
- Git gets its token through its credential-helper pipe. gh-touchid answers only when the request comes from Git's
  HTTPS transport (`git-remote-https`) and stdout is not a terminal.
- `gh` runs only its own commands, read as `gh` reads them. Anything else is refused before any dialog: extensions,
  your own aliases, hidden commands such as `gh help` (use `--help`), and a word that names no command where `gh`
  would look for one (`unknown_command`). Of `gh`'s own commands, those that would print or store the token, or
  install aliases or extensions, are refused too, wherever flags put their name: `auth` (except `auth status` without
  `-t`), `--show-token` anywhere, `alias`, and `extension` (also as `extensions` or `ext`), so
  `gh --hostname github.com auth token` is refused like `gh auth token`.
- An argument or folder given in JSON (`--input`, `rpc`, `mcp`) that holds a NUL character is refused
  (`invalid_input`): a program gets its arguments as C strings, which end at the first NUL, so it would get less than
  gh-touchid checked. Every program gh-touchid starts goes through one function that refuses NUL as well.
- Your sign-in (the access token, and the refresh token that renews it for six months) and the App's client secret
  stay in the Keychain. Together they reach every repository the App is installed on, with all its permissions, as
  far as your own access goes. gh-touchid uses them only to narrow, renew and revoke tokens. It keeps only sign-ins
  that expire.
- A refresh token works once, so renewing happens under a lock that other gh-touchid processes wait for.
- gh-touchid holds no private key of an owner's App, so nothing it keeps can act as that App's bot. But whoever owns
  the App on GitHub (you, or your organization's owners and App managers) can generate a new key in its settings.
  With it they can act as the bot on every account the App is installed on, as with any GitHub App.
- Your accounts' tokens are as long-lived and broad as you made them on GitHub, and gh-touchid never revokes them.
  Every use asks for Touch ID and names the command, the repository and who asked. The token goes only to the `gh`
  that gh-touchid starts, or to Git's transport.
- A `gh` signed in on its own (`gh auth login`, with its token in the Keychain or in its `hosts.yml`) is a way to
  GitHub that gh-touchid does not gate. Any program running as you can use that login, whichever `gh` comes first on
  PATH. `status` says when one is; `gh auth logout` with that `gh` closes it.

## The reader

- Its tokens act as the reader App's bot, `<app>[bot]`, not as you. The reader's private key is the one App key
  gh-touchid keeps. It signs a short-lived JSON Web Token with it to make each token, and never prints or logs it.
- For each use, GitHub must report that the new token has no permissions, that the installation's repositories are
  `selected`, and that it lists none. Otherwise the token is revoked and the use refused, so an App that later gets
  permissions or repositories on GitHub never reaches `gh`.
- A reader token reads public data and nothing private. But GitHub lets anyone who can read a repository open
  issues on it, the bot included; this was tested on public repositories of other owners. Before any token is
  made, gh-touchid refuses `gh issue create`, `gh api` posting to a repository's issues (by owner and name, by id,
  or through a placeholder such as `{owner}` that gh fills in later), and `gh api graphql` with `createIssue`, a
  query it cannot read, or a `-F` query with a placeholder. It finds the command as gh's parser does.
- In the same tests GitHub refused the bot comments, labels, stars, gists and new repositories. Other writes
  (reactions, forks, discussions, pull requests) were not tested, and gh-touchid does not refuse them. The notice, on
  stderr or in `notices`, is advice, and an agent that has been prompt-injected can ignore it.
- A reader token lasts an hour at most and is revoked when `gh` exits. Git never gets one.
- The key never expires. Whoever reads it can make bot tokens with these limits until the key is deleted in the App's
  settings; `reader add` replaces it.

## `rpc` and `mcp`

- The adapter they run is a separate program. It reads no Keychain item, never talks to the background agent, holds
  no secrets, and runs gh-touchid with `--json --input -` for each call. The agent does not trust it.
- It refuses commands that take a secret, so a token, client secret or key never passes through an MCP client's
  parameters, and from there a model's context.
- gh-touchid itself links no third-party code. The adapter uses the official MCP Swift SDK, pinned in
  `Package.resolved`.

## What is stored where

| What | Where |
| --- | --- |
| each owner's App: client ID and secret | login Keychain, service `com.lubaretsi.gh-touchid.app`, account = owner |
| your sign-in to each owner's App | login Keychain, service `com.lubaretsi.gh-touchid.signin`, account = owner |
| your accounts' tokens | login Keychain, service `com.lubaretsi.gh-touchid.user`, account = login |
| the reader: its App ID and private key | login Keychain, service `com.lubaretsi.gh-touchid.reader`, account = `reader` |
| sessions and elevations | memory of the background agent only |
| the access log | `~/Library/Logs/gh-touchid/access.log` |

- The Keychain items are generic passwords, available only while this Mac is unlocked, kept on this Mac only and
  never synced.
- A development build keeps its own items, under `com.lubaretsi.gh-touchid.dev.*`
  ([details](development.md#development-builds)).
- Each item's description says its format (`gh-touchid format 1`; Keychain Access shows it as the item's kind). An
  item without one, as 0.4.0 wrote it, is format 1. A gh-touchid that finds an item in a newer format than its own
  refuses it before any dialog, and `status` marks it: "stored by a newer gh-touchid: upgrade it". A description that
  says no format (changed in Keychain Access, or damaged) is refused too, with the command that stores the item again.
- `status`, the hints and the checks before a dialog read only which items exist, their formats, the App's name (its
  slug), the signed-in login, and the reader's name and owner. These are kept in the items' comments. They never read
  a secret. `status` also asks whether gh's own item `gh:github.com` exists, by its attributes alone.
- Releases run with the hardened runtime, so another program cannot load code into gh-touchid to use the items;
  development builds and the build from source run without it. Either way gh-touchid itself enforces the protection:
  it asks for Touch ID or checks the session before it uses the items. But macOS lets a process read them once you
  allow it in the Keychain dialog or with your account password.

## Which `gh` runs

gh-touchid runs only the `gh` it was built with. No environment variable changes which one.

- **Releases** (the tarball, Homebrew, and the flake's default package) bundle GitHub's `gh` in
  `libexec/gh-touchid`. Any program running as you can write there, as in all of Homebrew's folders. So:
  1. Before it makes a token, gh-touchid checks the file's SHA-256. A changed `gh` is refused: "the gh next to
     gh-touchid was changed; reinstall gh-touchid".
  2. It starts `gh` suspended, before its first instruction. It lets `gh` run only if the code the kernel loaded for
     it (the slice that runs, natively or under Rosetta) has the code directory hash (cdhash) of GitHub's `gh`
     pinned at build time. Otherwise, or if that cannot be read, `gh` is killed unrun. So replacing the installed
     `gh` after the SHA-256 check cannot hand the token to another program.
  3. GitHub's `gh` runs with the hardened runtime, so a page changed after it starts gets it killed.
- **The Nix build from source** (`packages.<system>.from-source`) runs nixpkgs' `gh` by its store path and checks its
  SHA-256, without a cdhash. nixpkgs' `gh` is a wrapper script, and the read-only Nix store keeps it from being
  replaced.
- **Development builds** run `GH_TOUCHID_GH` or the `gh` on PATH; only they honour `GH_TOUCHID_GH`.

## Sessions and the background agent

- Everything inside an approved session shares its access. Any process the session's program starts, at any depth,
  gets tokens for the session's repositories without Touch ID until the program exits. It can also open issues on,
  and read, every private repository your Apps are installed on. Approve sessions only for programs you trust, with
  the repositories they need.
- The background agent holds no tokens or keys. It answers only processes running as you, on a socket in your
  private temporary directory (`getconf DARWIN_USER_TEMP_DIR`).
- gh-touchid and the agent check each other on every connection by what the kernel says of the running code, not by
  its file path: a valid signature, the hardened runtime, and its cdhash. They trust the same release, an earlier one
  on the list built into this release (`release/known-releases`, which the release workflow adds each release to),
  and a later one with gh-touchid's Developer ID signature that says it is later. Only those may approve a session,
  elevate a repository, or have their answers acted on. The kernel keeps a running program's cdhash after an upgrade
  deletes its file, so an older release's agent is still recognized.
- A release marked `revoked` in that list is not trusted. The first gh-touchid that meets its agent ends it (`lock`),
  and nothing it held is carried over: each program runs `gh-touchid session` again, and until then each use asks.
- An agent that gh-touchid cannot verify is left alone: another program on its socket, or a later release whose file
  an upgrade already deleted. No session applies, so each use asks for Touch ID, and `status` names that program.
- Releases share one agent, at `agent.sock`. Development builds, and builds from source without the release list,
  keep an agent of their own, at a socket named after their path, and trust a program at their own path, as before.
- Any process running as you can register its parent (or the program above its non-interactive shells, or above
  `gh-touchid-adapter`) as a pending session, which still needs your Touch ID. It can also see the status, or `lock`.
  An agent of 0.4.2 or earlier, which speaks the older agent protocol, stops at the adapter: a session started through
  `rpc` or `mcp` then belongs to the adapter and ends with it.

## Signing in

- `app create`, `app add`, `app login` and `reader create` listen on `127.0.0.1:47911` until GitHub sends the browser
  back: at most an hour for **Create**, 15 minutes for **Authorize** and for the reader's **Install**.
- They accept only answers that carry the random `state` they gave GitHub. The code exchange also needs the PKCE
  verifier, which only this process holds. The reader's code is GitHub's one-time manifest code.
- The App's secret, your sign-in and the reader's key go from GitHub's replies straight to the Keychain.

## What gh-touchid does not defend against

Code that already runs as you and sets out to tamper with gh-touchid. For example, it can load code into a development
build or a build from source (ad hoc signed, without the hardened runtime; a release's hardened runtime blocks that),
or answer the Keychain dialogs.
