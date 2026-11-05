# gh-touchid documentation

- **Owner**: the GitHub account or organization a repository belongs to, such as `acme` in `acme/widget`.
- **Sign-in**: your authorization of an owner's App. gh-touchid narrows each use's token from it.
- **Session**: a running program, such as an agent's harness, that you approved once with Touch ID. It and
  everything it starts get tokens for its repositories without Touch ID until it exits. See [Sessions](sessions.md).
- **Elevate**: let tokens for a repository include the `workflows` permission for a while. See
  [Elevating a repository](sessions.md#elevating-a-repository).
- **Your accounts**: GitHub accounts whose own tokens you stored, for what your Apps cannot reach. See
  [Acting as one of your accounts](everyday-use.md#acting-as-one-of-your-accounts).
- **Reader**: a GitHub App of yours with no permissions, whose tokens let `gh` read public data of owners you have
  no App for, without Touch ID. See [The reader](setup.md#5-the-reader-optional).

## Get started

- [Install](install.md): Homebrew, the release tarball and Nix; running `gh` through gh-touchid; verifying signed
  releases.
- [Setup](setup.md): a GitHub App per owner, Git, your accounts, the reader; signing in again and removing an owner.
- [Upgrading](upgrading.md): what to do when moving from an earlier release.

## Use

- [Everyday use](everyday-use.md): which repository a command gets a token for, the Touch ID window, acting as one
  of your accounts.
- [Sessions](sessions.md): approving a program once, and elevating a repository for `workflows`.
- [Status, lock and the access log](status.md): what is stored, ending sessions, and who asked for what.
- [Organizations with more members](organizations.md): sharing an owner's App with other people.
- [AI agent usage](agents.md): running an agent inside a session.

## Reference

- [Commands](commands.md): every command, its arguments and flags.
- [Errors](errors.md): the stable error codes.
- [Scripts and agents](scripting.md): `--json`, `--input`, exit status, notices, `rpc` and `mcp`.

## Security

- [Security model](security-model.md): what tokens reach, what is stored where, which `gh` runs, sessions.
- [Threat model](threat-model.md): assets, actors, boundaries and assumptions.
- [SECURITY.md](../SECURITY.md): reporting a vulnerability.

## Development

- [Building from source](development.md): development and release builds, tests, Nix from source.
