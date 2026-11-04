# Threat model

gh-touchid runs on one person's Mac. It lets that person, and the programs they start (AI agents above all), use
GitHub through `gh` and Git: public data through a reader App that can do almost nothing else, and everything beyond
that only as far as the person approved with Touch ID. This file says what it protects, from whom, where data crosses
a boundary, what it assumes and what it does not try to stop. [security-model.md](security-model.md) has the same facts
from the user's side; Sources/GHTouchID/Access.swift has the policy itself.

## What it protects

| Asset | Where it lives | Why it matters |
| --- | --- | --- |
| Your sign-in to each owner's App: an access token (8 h) and a refresh token (6 months) | Keychain, `com.lubaretsi.gh-touchid.signin` | Together with the client secret it reaches every repository the App is installed on, with all its permissions, as far as your own access goes |
| Each App's client secret | Keychain, `com.lubaretsi.gh-touchid.app` | Narrows, renews and revokes tokens of your sign-in |
| Your accounts' tokens (`account add`) | Keychain, `com.lubaretsi.gh-touchid.user` | As broad and long-lived as you made them on GitHub |
| Narrowed tokens, one per use | memory of gh-touchid, the env of the gh it starts, Git's credential pipe | One repository, `workflows` only when elevated; revoked after gh, Git's run out (at most 8 h) |
| The reader's private key (`reader create`, `reader add`) | Keychain, `com.lubaretsi.gh-touchid.reader` | Mints tokens of the reader App's bot until the key is deleted on GitHub; it never expires |
| Reader tokens, one per use | memory of gh-touchid, the env of the gh it starts | No permissions and no repositories: public data only, plus opening issues on public repositories; revoked after gh; they act as the reader's bot, not as you |
| Session approvals and elevations | memory of the background agent | Let a program and its descendants get tokens without Touch ID |
| What a Touch ID dialog shows | the approval window | The user decides from it; it must name the real command, repository, identity and scope |
| The access log | `~/Library/Logs/gh-touchid/access.log` | Shows who asked for what; an audit aid, not tamper-proof |

Development builds keep their items under `com.lubaretsi.gh-touchid.dev.*`; test builds keep files under
`GH_TOUCHID_TEST_DIR` and never touch the Keychain.

## Who acts

- **The user**: trusted, present at the Mac, approves with Touch ID. A locked screen means nobody can approve.
- **Programs running as the user**, chiefly AI agents and their tools: not trusted to stay within what the user
  approved. They may be prompt-injected and may run any command, write any file the user can, and pick any
  arguments or environment for gh-touchid. They are assumed **not** to attack gh-touchid itself (see below).
- **GitHub** (api.github.com, github.com): trusted to authenticate, to enforce token scopes and to tell the truth
  about who a token belongs to. Reached over TLS.
- **Web pages in the user's browser**: untrusted; they can send requests to `127.0.0.1:47911` while a sign-in waits.
- **Other local users**: untrusted; they cannot reach the user's Keychain, temp directory or the agent's socket.
- **Owners and App managers of the user's Apps** (the user, or an organization's owners): trusted. They can make a
  new private key for an App on GitHub and act as its bot wherever it is installed. gh-touchid keeps no such key for
  an owner's App, only for the user's reader, whose bot has no permissions.

## Entry points

| Entry point | Who supplies it | Handling |
| --- | --- | --- |
| Command-line arguments and environment (`GH_REPO`, `GH_TOUCHID_AS`) | any program running as the user | They choose the repository and command shown in the dialog. A gh command line is read as gh reads it, from gh's own list of commands and flags, so the dialog names the command gh runs; only gh's own commands run (no extensions, user aliases or hidden commands); those that could reveal or store the token (`auth` other than `auth status` without `-t`, `--show-token`, `alias`, `extension`) are refused wherever flags put their name; titles and bodies are shown in full |
| Git's credential requests (`git credential get`) | Git | Answered only when the nearest non-shell ancestor is `git-remote-http(s)` and stdout is not a terminal |
| The background agent's Unix socket | processes of the same user | Every request and reply carries the protocol and the version. The agent answers protocols 1 (earlier releases) and 2, each as it means (in 2, `register` also looks past `gh-touchid-adapter`), and refuses any other before anything is done; a client falls back once to protocol 1 for a trusted earlier release's agent. `register` (always the caller's own session root), `check`, `status` and `lock` for any same-user peer; `begin-approval`, `approve`, `deny` and `elevate` only for a trusted peer (boundary 3). Clients act only on replies of a trusted agent |
| The local server on `127.0.0.1:47911` (`app create`, `app add`, `app login`, `reader create`) | the browser, and any web page or local process | Only `GET`; a callback must carry this attempt's random `state`; the code exchange needs the PKCE verifier and the client secret (a manifest conversion needs the one-time code); the manifest page stops being served once an App was made |
| `--input` JSON and command words | any program running as the user, directly or through the adapter | Checked against the operation's schema before anything is done: unknown keys, wrong types and input over 1 MiB are refused; secrets come only on stdin, never as arguments; text that becomes a program's argument or folder is refused with a NUL, at which a C string would end, and every program start refuses it again |
| The adapter's stdio (`gh-touchid rpc`, `gh-touchid mcp`) | the client that started it (an agent harness) | The adapter holds no secrets and calls the core's CLI once per call; it refuses operations that take a secret, so a secret never passes through a model's parameters |
| GitHub's replies | GitHub | Parsed defensively; replies that hold tokens never go into errors; a sign-in without an expiry or a refresh token is refused |
| gh's list of commands (`gh help reference`) | the pinned gh: built into a release (`release/gh-reference.md`, checked against the packaged gh); in a development build, the gh that runs | Every decision about a gh command line comes from it: the command, which flags take values, the repository. A development build reads it with throwaway configuration and data folders, so installed extensions are not taken for gh's commands |
| The process table (names, parents, folders) | the kernel | Used for dialog wording, the session root and the access log; a same-user process can choose its own name |

## Trust boundaries

1. **gh-touchid → gh.** The narrowed token goes to the pinned gh in `GH_TOKEN`, with a fresh empty `GH_CONFIG_DIR`.
   A release starts gh suspended and lets it run only if the code the kernel loaded has the pinned cdhash. Programs
   gh starts (editor, Git, the repository's hooks, extensions) inherit the token while gh runs.
2. **gh-touchid → Git.** Git's transport gets the token over the credential-helper pipe. Git's tokens are not
   revoked; they run out with the sign-in's access token.
3. **gh-touchid ↔ background agent.** The agent holds no tokens or secrets, only session and elevation state. Each
   side identifies the other by the connection's audit token (`identifyPeer`): same user, a valid code signature, the
   hardened runtime when it has it, then the kernel's cdhash of the peer. Trusted: this release's own cdhashes, an
   earlier release on the built-in list (`release/known-releases`, marked `trusted`), or a later release whose code
   meets `releaseCodeRequirement` (gh-touchid's Developer ID) and which states a later version. A release marked
   `revoked` is not trusted; the first client that meets its agent locks it and carries nothing over. The
   kernel keeps a running program's cdhash after its file is deleted; its code signature can then no longer be
   checked, so a later release whose file an upgrade deleted is not trusted. Releases share `agent.sock`; every
   other build keeps an agent named after its path and trusts its own path. Changes to the socket path happen under
   `agent.lock`, and an agent deletes only the socket it bound.
4. **gh-touchid ↔ GitHub.** All token minting and revocation happens here; GitHub enforces the narrowed scope.
5. **Browser ↔ local server.** The sign-in result crosses here; `state` and PKCE bind it to this attempt.
6. **gh-touchid ↔ Keychain.** Items are read only after Touch ID or a session check; `status` and the checks before
   a dialog read attributes only (which items exist, their formats, the App's slug, the signed-in login). An item in a
   format newer than this gh-touchid's is refused, not misread.
7. **gh-touchid → gh, as the reader.** For an owner without a stored App, or a command that names no repository,
   gh gets an installation token of the reader App, minted only when GitHub reports it has no permissions and no
   repositories, after the command was checked for opening an issue. Git never gets one.
8. **Adapter → gh-touchid.** The adapter is a separate program without secrets; the core treats its calls like any
   program's command line, and the agent never trusts it (it is not on the release list and has its own cdhash).

## Invariants reviewers should hold

- No token, client secret or refresh token appears in an error, log line, stdout/stderr, browser page, process
  argument or file.
- Every handed-out token passes `authorizeUse` before `issueCredential` mints it: Touch ID, or an approved session
  that covers the use, or, for the reader, the issue check; acting as an account asks for Touch ID on every use.
- A handed-out token covers exactly one repository and the installation's permissions minus `workflows`, unless the
  repository is elevated when the token is minted; issue-only tokens never include `workflows`. A reader token covers
  no repository and is used only when GitHub reports `permissions` `{}`, `repository_selection` `selected` and no
  repositories; it goes only to the pinned gh, never to Git.
- The core links no third-party code. The adapter holds no secrets, never reads the Keychain or talks to the agent,
  and refuses operations that take a secret.
- The token of a `gh` use is revoked when gh exits, also after SIGINT, SIGQUIT, SIGHUP and SIGTERM to gh-touchid.
- Touch ID comes before any secret is stored; a refused dialog stores nothing.
- Renewing, replacing and reading a sign-in happen under the owner's lock, so a single-use refresh token is never
  spent twice and an App's secret is never paired with another App's sign-in.
- Release builds run only the pinned gh; only development and test builds honour `GH_TOUCHID_GH`.
- Only a trusted peer (boundary 3) may approve, deny or elevate, and clients act only on a trusted agent's
  answers. A release that shares `agent.sock` never trusts a peer because of its file path.

## Accepted risks

- **The reader's bot can open issues** on any public repository with issues turned on: GitHub lets anyone with read
  access do that, the bot included. gh-touchid refuses `gh issue create`, `gh api` POST to a repository's issues (by
  owner and name, by id, or through a placeholder gh fills in) and `gh api graphql` with `createIssue`, a query it
  cannot read, or a typed query with a placeholder; it finds the command as gh's parser (Cobra) does. Other writes
  GitHub might allow the same way (reactions, forks, discussions, pull requests) were not tested and are not refused.
  The issues appear under the reader App's name, and GitHub may suspend the App for abuse.
- **The instruction on stderr is advice, not a boundary.** Every reader use prints that the token is for reading;
  a prompt-injected agent can ignore it, and it arrives with the command's output, after the command ran.
- **The reader's key never expires.** Whoever reads it mints bot tokens with the limits above until the key is
  deleted on GitHub; `reader add` replaces it with a new one.
- **Reader content is untrusted text.** Public issues, READMEs and code an agent reads through the reader can carry
  prompt injections; the limits above are what bounds the result.
- **A session shares its access** with every process its program starts, until the program exits, including
  issue-only tokens (without asking) for private repositories the session does not list.
- **gh's children see the token** while gh runs; a hook in a repository the agent can write can read it. The token is
  limited to one repository and revoked when gh exits; Git's tokens live up to 8 hours.
- **Dialog wording comes from the process table**, which a same-user process can influence (its name, its folder).
  The dialog names the repository, command and scope as gh will read the command line, so a program cannot make it
  name one command while gh runs another.
- **Your sign-in and client secret are broad.** They sit in the Keychain, available while the Mac is unlocked.
- **Account tokens are as broad and long-lived as the user made them**, and are never revoked by gh-touchid.
- **The fixed port 47911**: a process already listening there makes a sign-in fail; it cannot receive the code,
  because the browser is sent to GitHub only once gh-touchid holds the port.
- **An expired or revoked sign-in is found after the use's Touch ID**, since the checks before a dialog read no
  secret.
- **A genuine older release can be run as the agent** by a same-user process (old releases stay downloadable). It
  holds only sessions approved with Touch ID through it. A release found flawed is marked `revoked`, and newer
  releases then lock its agent.
- **An untrusted program can hold `agent.sock`.** Clients then use no session (each use asks for Touch ID) and
  `status` names it; they do not end it, since it may be a later release whose file is already gone. A same-user
  process could always end the agent.
- **A release's own entry is added after it is published**, by the release workflow, so the next release knows it.
  The list in the repository is part of what a release trusts.

## Out of scope

- Code that already runs as the user and attacks gh-touchid itself: loading code into it (a release's hardened
  runtime blocks that; development builds and builds from source are ad hoc signed, without it, and allow it), reading
  Keychain items it was allowed, answering Keychain dialogs, ptrace, or replacing gh-touchid's own executable.
- Root, the kernel, and anyone with the Mac unlocked and the user's finger.
- GitHub's own security, the browser's, and TLS interception by a trusted root certificate.
- What an approved session does with the access it was given, within that access.
- An owner or App manager making a new private key for an App.

## Where to look first

- `Access.swift` (policy), `GitHubApp.swift` (narrowing, permissions, renewal, revocation).
- `Reader.swift`, `IssueCheck.swift`, `JWT.swift` (the reader's checks, the issue refusal, the App's key).
- `Operations.swift`, `Schema.swift` (input checking, where secrets may come from, what is printed).
- `AdapterLaunch.swift` and `Sources/GHTouchIDAdapter/` (what the adapter may do and refuses).
- `SignIn.swift`, `LocalServer.swift`, `AppManifest.swift` (browser flows, `state`, PKCE, what gets stored when).
- `GitHubCLI.swift` (pinned gh, cdhash, the environment gh gets, refused commands, signals).
- `Commands.swift` `gitCredential` (who gets a Git credential); `Identity.swift` (`identifyPeer`, `sharesAgentSocket`),
  `Agent.swift`, `AgentClient.swift` and `Socket.swift` (`exchange`, `withAgentLock`; peer checks, socket ownership).
- `Repository.swift` and `GitHubFlags.swift` (which repository a command is for, which decides the dialog and token).
- `Secrets.swift` (Keychain items, attribute-only reads, the development namespace).
