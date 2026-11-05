# gh-touchid

gh-touchid puts Touch ID in front of `gh` and Git access to GitHub on your Mac. `gh` and Git act as you, through a
private GitHub App you create for each owner. Every use gets its own token for one repository, and the token `gh`
used is revoked when `gh` exits. Outside a session, each use asks for Touch ID in a window that names who asked, the
command and the repository. An AI agent can run as a *session*, which you approve once instead of on every command.
Public data of other owners comes through a *reader*: an App of yours with no permissions, which needs no Touch ID.
Every command also speaks JSON, and `gh-touchid mcp` serves them all to agents as MCP tools.

## Requirements

macOS 26 (Tahoe) or later, on an Apple silicon or Intel Mac. gh-touchid uses the `git` on your PATH and bundles
GitHub's `gh`.

## Install

```sh
brew install georgelubaretsi/tap/gh-touchid
```

The release tarball and Nix are in [docs/install.md](docs/install.md); setting up each owner is in
[docs/setup.md](docs/setup.md).

## Quick start

```sh
export PATH="/opt/homebrew/opt/gh-touchid/libexec/bin:$PATH"   # run `gh` through gh-touchid; put it in your profile

gh-touchid setup acme         # in the browser: acme's App (create, authorize, install), then the reader; Git too

cd ~/code/widget              # a clone of https://github.com/acme/widget.git
gh pr list                    # Touch ID, then a token for acme/widget only
git push                      # the same, for Git
gh repo view kubevirt/kubevirt   # no Touch ID: the reader, public data only

gh-touchid session            # make this shell a session; start your agent from it
```

After `gh-touchid session`, the first GitHub use from that shell or anything it starts asks for Touch ID once. After
that, `gh` and Git work without Touch ID for the repositories in the current folder, until the shell exits.

## How it protects you

- Every token gh-touchid makes to act as you is narrowed from your sign-in to the owner's App to one repository,
  without `workflows` unless the repository is elevated, and the token of a `gh` command is revoked when `gh` exits
  ([details](docs/security-model.md#tokens-and-what-they-reach)).
- Narrowed tokens are never cached, never written to disk, and never exported to the calling shell; your sign-in and
  the App's client secret stay in the login Keychain, on this Mac only and never synced
  ([details](docs/security-model.md#what-is-stored-where)).
- Refused before any dialog: `gh` commands that would print or store the token, or install aliases or extensions
  ([details](docs/security-model.md#tokens-and-what-they-reach)).
- gh-touchid runs only the `gh` it was built with; a release checks the bundled `gh`'s SHA-256 and its cdhash before
  letting it run ([details](docs/security-model.md#which-gh-runs)).
- The reader's tokens act as a bot with no permissions, read public data and nothing private, and are revoked when
  `gh` exits ([details](docs/security-model.md#the-reader)).
- `rpc` and `mcp` run a separate adapter that holds no secrets and refuses commands that take one, so a secret never
  passes through a model ([details](docs/security-model.md#rpc-and-mcp)).

gh-touchid does not defend against code that already runs as you and sets out to tamper with it
([details](docs/security-model.md#what-gh-touchid-does-not-defend-against)).

## Documentation

All documentation is in [docs/](docs/index.md):

- [Install](docs/install.md), [Setup](docs/setup.md), [Upgrading](docs/upgrading.md)
- [Everyday use](docs/everyday-use.md), [Sessions](docs/sessions.md),
  [Status, lock and the access log](docs/status.md), [Organizations](docs/organizations.md),
  [AI agent usage](docs/agents.md)
- [Commands](docs/commands.md), [Errors](docs/errors.md), [Scripts and agents](docs/scripting.md)
- [Security model](docs/security-model.md)

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). The threat model is in
[docs/threat-model.md](docs/threat-model.md).

## Building and contributing

Building, release builds and tests are in [docs/development.md](docs/development.md). Guidance for working on the
code, for people and coding agents, is in [AGENTS.md](AGENTS.md).

## License

MIT; see [LICENSE](LICENSE).
