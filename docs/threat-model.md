# Threat model

gh-touchid runs on one person's Mac. It lets that person, and the programs they start (AI agents above all), use
GitHub through `gh` and Git, but only as far as the person approved with Touch ID. This file says what it protects,
from whom, where data crosses a boundary, what it assumes and what it does not try to stop. README.md's "Security
model" section has the same facts from the user's side; Sources/GHTouchID/Access.swift has the policy itself.

## What it protects

| Asset | Where it lives | Why it matters |
| --- | --- | --- |
| Your sign-in to each owner's App: an access token (8 h) and a refresh token (6 months) | Keychain, `com.lubaretsi.gh-touchid.signin` | Together with the client secret it reaches every repository the App is installed on, with all its permissions, as far as your own access goes |
| Each App's client secret | Keychain, `com.lubaretsi.gh-touchid.app` | Narrows, renews and revokes tokens of your sign-in |
| Your accounts' tokens (`account add`) | Keychain, `com.lubaretsi.gh-touchid.user` | As broad and long-lived as you made them on GitHub |
| Narrowed tokens, one per use | memory of gh-touchid, the env of the gh it starts, Git's credential pipe | One repository, `workflows` only when elevated; revoked after gh, Git's run out (at most 8 h) |
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
  new private key for an App on GitHub and act as its bot wherever it is installed; gh-touchid keeps no such key.

## Entry points

| Entry point | Who supplies it | Handling |
| --- | --- | --- |
| Command-line arguments and environment (`GH_REPO`, `GH_TOUCHID_AS`) | any program running as the user | They choose the repository and command shown in the dialog; titles and bodies are shown in full; flags that could reveal a token (`auth token`, `--show-token`, `alias`, `extension`) are refused |
| Git's credential requests (`git credential get`) | Git | Answered only when the nearest non-shell ancestor is `git-remote-http(s)` and stdout is not a terminal |
| The background agent's Unix socket | processes of the same user | `register`, `check`, `status` and `lock` for any same-user peer; `begin-approval`, `approve`, `deny` and `elevate` only for a peer running the same executable; clients trust only an agent served by their own executable |
| The local server on `127.0.0.1:47911` (`app create`, `app set`, `app login`) | the browser, and any web page or local process | Only `GET`; a callback must carry this attempt's random `state`; the code exchange needs the PKCE verifier and the client secret; the manifest page stops being served once an App was made |
| GitHub's replies | GitHub | Parsed defensively; replies that hold tokens never go into errors; a sign-in without an expiry or a refresh token is refused |
| `gh help reference` of the pinned gh | the pinned gh | Parsed only to tell which flags take values, for ambiguous `-R` |
| The process table (names, parents, folders) | the kernel | Used for dialog wording, the session root and the access log; a same-user process can choose its own name |

## Trust boundaries

1. **gh-touchid → gh.** The narrowed token goes to the pinned gh in `GH_TOKEN`, with a fresh empty `GH_CONFIG_DIR`.
   A release starts gh suspended and lets it run only if the code the kernel loaded has the pinned cdhash. Programs
   gh starts (editor, Git, the repository's hooks, extensions) inherit the token while gh runs.
2. **gh-touchid → Git.** Git's transport gets the token over the credential-helper pipe. Git's tokens are not
   revoked; they run out with the sign-in's access token.
3. **gh-touchid ↔ background agent.** The agent holds no tokens or secrets, only session and elevation state.
4. **gh-touchid ↔ GitHub.** All token minting and revocation happens here; GitHub enforces the narrowed scope.
5. **Browser ↔ local server.** The sign-in result crosses here; `state` and PKCE bind it to this attempt.
6. **gh-touchid ↔ Keychain.** Items are read only after Touch ID or a session check; `status` and the checks before
   a dialog read attributes only (which items exist, their formats, the App's slug, the signed-in login). An item in a
   format newer than this gh-touchid's is refused, not misread.

## Invariants reviewers should hold

- No token, client secret or refresh token appears in an error, log line, stdout/stderr, browser page, process
  argument or file.
- Every handed-out token passes `authorizeUse` (Touch ID, or an approved session that covers the use) before
  `issueCredential` mints it; acting as an account asks for Touch ID on every use.
- A handed-out token covers exactly one repository and the installation's permissions minus `workflows`, unless the
  repository is elevated when the token is minted; issue-only tokens never include `workflows`.
- The token of a `gh` use is revoked when gh exits, also after SIGINT, SIGQUIT, SIGHUP and SIGTERM to gh-touchid.
- Touch ID comes before any secret is stored; a refused dialog stores nothing.
- Renewing, replacing and reading a sign-in happen under the owner's lock, so a single-use refresh token is never
  spent twice and an App's secret is never paired with another App's sign-in.
- Release builds run only the pinned gh; only development and test builds honour `GH_TOUCHID_GH`.

## Accepted risks

- **A session shares its access** with every process its program starts, until the program exits, including
  issue-only tokens (without asking) for private repositories the session does not list.
- **gh's children see the token** while gh runs; a hook in a repository the agent can write can read it. The token is
  limited to one repository and revoked when gh exits; Git's tokens live up to 8 hours.
- **Dialog wording comes from the process table**, which a same-user process can influence (its name, its folder).
  The dialog names the repository, command and scope from gh-touchid's own parsing, which a program cannot change.
- **Your sign-in and client secret are broad.** They sit in the Keychain, available while the Mac is unlocked.
- **Account tokens are as broad and long-lived as the user made them**, and are never revoked by gh-touchid.
- **The fixed port 47911**: a process already listening there makes a sign-in fail; it cannot receive the code,
  because the browser is sent to GitHub only once gh-touchid holds the port.
- **An expired or revoked sign-in is found after the use's Touch ID**, since the checks before a dialog read no
  secret.

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
- `SignIn.swift`, `LocalServer.swift`, `AppManifest.swift` (browser flows, `state`, PKCE, what gets stored when).
- `GitHubCLI.swift` (pinned gh, cdhash, the environment gh gets, refused commands, signals).
- `Commands.swift` `gitCredential` (who gets a Git credential), `Agent.swift` and `Socket.swift` (peer checks).
- `Repository.swift` and `GitHubFlags.swift` (which repository a command is for, which decides the dialog and token).
- `Secrets.swift` (Keychain items, attribute-only reads, the development namespace).
