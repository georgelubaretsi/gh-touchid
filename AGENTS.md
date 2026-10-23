# gh-touchid

A Swift CLI for macOS that puts Touch ID in front of `gh` and Git. Each use gets a token narrowed
from the user's sign-in to the owner's GitHub App, for one repository, revoked after `gh` exits.

## Layout

- `Sources/GHTouchID/`: the executable; `Access.swift` is the access policy, `GitHubApp.swift` the
  tokens, `Usage.swift` the help text.
- `tests/`: black-box suite (Bun) against a test build; `tests/support/` has the mock GitHub.
- `scripts/`: `build.sh` (the only place compiler flags live), `package.sh`, formula scripts.
- `release/`: the pinned `gh` (`gh.json`), the Nix pin (`nix.json`), the Homebrew formula.
- `docs/threat-model.md`: assets, actors, boundaries. `SECURITY.md`: reporting, review checklist.

## Commands

```sh
nix develop --command just test     # test build + suite: no Touch ID, no Keychain, mock GitHub
nix develop --command just lint     # actionlint + shellcheck
nix develop --command just build    # development build in build/ (real Keychain and Touch ID)
nix develop --command just package  # release tarball in dist/
```

## Workflow

- Never run `build/gh-touchid`, the installed `gh-touchid`, or `gh`/Git against github.com: they
  ask the user for Touch ID. Test through `just test`.
- Changes users would notice get a CHANGELOG.md entry in the same change; others say
  `Changelog: none` in the commit message.
- Change README.md together with behaviour: it documents every command and the security model.
- Every behaviour change adds or changes a test; assert on exit status, AUTH lines, mock records.

## Conventions

- Swift 5 language mode, built by `scripts/build.sh` with Xcode; lines up to 120 columns.
- Test-only code sits behind `#if GH_TOUCHID_TESTING`; development-only paths check
  `pinnedGitHubCLI`.
- Errors are `ToolError`s with lowercase messages that say what to run next.
- Comments say why, in full sentences, and stay true when the code changes.
- Changing what a stored item holds bumps `itemFormat` (Secrets.swift) and keeps reading the
  earlier formats; add a test with an item in each format.

## Code Review Rules

- No token, client secret or refresh token may reach an error, log line, output, browser page,
  process argument or file. Safe path: only the pinned gh's `GH_TOKEN` and Git's credential pipe.
- Every token handed out passes `authorizeUse` (Touch ID or an approved session) before
  `issueCredential`. Safe path: change `Access.swift` only with a test for each rule touched.
- A handed-out token covers one repository, has `workflows` only if elevated at mint time, and is
  revoked after gh. Safe path: `mintScopedToken` and `revokeAfterUse`; never pass the sign-in out.
- Only the pinned gh runs with a token, checked by SHA-256 and cdhash. Safe path: `gitHubCLI()`
  and `runGitHubCLI`; no environment variable picks the gh in a release build.
- Sign-ins are read, renewed and replaced under the owner's lock, and Touch ID comes before any
  secret is stored. Safe path: `currentSignIn`, `storeSignedIn`, `withSignInLock`.

## More detail

- [docs/threat-model.md](docs/threat-model.md): what is protected, from whom, what is out of scope.
- [SECURITY.md](SECURITY.md): reporting a vulnerability, and the security review checklist.
- [README.md](README.md): every command, the security model, building and testing.
