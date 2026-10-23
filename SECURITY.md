# Security

## Reporting a vulnerability

Report it privately with GitHub's **Report a vulnerability** button on this repository's **Security** tab. Please do
not open a public issue or pull request for it. Say what an attacker needs (for example "a program running as the
user" or "a web page open in the browser during `app login`"), what they get, and how to reproduce it.

Only the latest release gets fixes. What gh-touchid protects, against whom, and what is out of scope are in
[docs/threat-model.md](docs/threat-model.md).

## Reviewing a change for security

Read [docs/threat-model.md](docs/threat-model.md) first; its invariants are what a change must keep. Then check the
parts the change touches:

| If the change touches | Check that |
| --- | --- |
| `Access.swift` | each access rule still asks Touch ID or checks the session before a token is minted; acting as an account asks every time; refusals that need no dialog come before it; every outcome is logged |
| `GitHubApp.swift` | a handed-out token names one repository; `workflows` only when elevated at mint time; the sign-in's own token never leaves; renewal and reads happen under the owner's lock; replies holding tokens never reach an error |
| `SignIn.swift`, `LocalServer.swift`, `AppManifest.swift` | callbacks need this attempt's `state`; PKCE is sent and checked; Touch ID comes before anything is stored; failures say truthfully what was stored; the manifest page is not served after an App was made |
| `GitHubCLI.swift` | only the pinned gh runs with a token (SHA-256, and cdhash before it runs); `GH_TOKEN` goes only to it, with a fresh `GH_CONFIG_DIR`; token-revealing commands stay refused; signals are passed on and the token is still revoked |
| `Commands.swift` (`git credential`) | a credential goes only to Git's HTTP(S) transport and never to a terminal |
| `Agent.swift`, `Socket.swift` | same-user peers only; approving and elevating only from this executable; clients trust only an agent served by their own executable; the agent holds no secrets |
| `Secrets.swift` | checks before a dialog read attributes only; development builds keep their own items; nothing secret is written outside the Keychain (test builds excepted) |
| `Repository.swift`, `GitHubFlags.swift` | the repository in the dialog is the one the token is for; for an account's token, ambiguity is refused, not guessed |
| Anything that prints, logs or builds an error | no token, client secret or refresh token can end up in it |
| `scripts/`, `release/`, `.github/workflows/` | the bundled gh stays pinned by SHA-256 and cdhash; actions are pinned by commit; workflows keep the least permissions they need |

A change to any of these needs a test in `tests/` for the behaviour it keeps or changes; `just test` runs them
against a mock GitHub, with no Touch ID and no Keychain.

## Severity

| Severity | Examples |
| --- | --- |
| Critical | a token, client secret or refresh token reaching a program, log, file or web page outside the documented paths (the pinned gh's `GH_TOKEN`, which the programs gh starts inherit while it runs, and Git's credential pipe to its HTTPS transport); a token handed out without Touch ID or a covering session; gh-touchid handing a token to any program but the pinned gh or Git's transport |
| High | a token for more than one repository, or with `workflows` when not elevated; a `gh` token not revoked after gh exits; a session approved or elevated by a peer that is not this executable; a sign-in callback accepted without this attempt's `state` |
| Medium | a dialog naming a different repository, command or identity than the token is for; a refused or failed flow leaving a secret stored, or saying it stored nothing when it did; a refusal that should come before a dialog coming after it |
| Low | an access-log line missing or wrong; a misleading message that does not change what is granted |

Behaviour that [docs/threat-model.md](docs/threat-model.md) lists under "Accepted risks" or "Out of scope" is not a
vulnerability by itself; a change that widens it is.
