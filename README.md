# gh-touchid

gh-touchid puts Touch ID in front of `gh` and Git access to GitHub on your Mac. `gh` and Git act as you, through a
private GitHub App you create for each owner. Every use gets its own token for one repository, and the token `gh`
used is revoked when `gh` exits. Outside a session, each use asks for Touch ID in a window that names who asked, the
command and the repository. An AI agent can run as a *session*, which you approve once instead of on every command.
Public data of other owners comes through a *reader*: an App of yours with no permissions, which needs no Touch ID.
Every command also speaks JSON, and `gh-touchid mcp` serves them all to agents as MCP tools.

Terms used below:

- **Owner**: the GitHub account or organization a repository belongs to, such as `acme` in `acme/widget`.
- **Sign-in**: your authorization of an owner's App. gh-touchid narrows each use's token from it.
- **Session**: a running program, such as an agent's harness, that you approved once with Touch ID. It and
  everything it starts get tokens for its repositories without Touch ID until it exits. See [Sessions](docs/sessions.md#sessions).
- **Elevate**: let tokens for a repository include the `workflows` permission for a while. See
  [Elevating a repository](docs/sessions.md#elevating-a-repository).
- **Your accounts**: GitHub accounts whose own tokens you stored, for what your Apps cannot reach. See
  [Acting as one of your accounts](docs/everyday-use.md#acting-as-one-of-your-accounts).
- **Reader**: a GitHub App of yours with no permissions, whose tokens let `gh` read public data of owners you have
  no App for, without Touch ID. See [The reader](docs/setup.md#5-the-reader-optional).

## Quick start

```sh
brew install georgelubaretsi/tap/gh-touchid
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
