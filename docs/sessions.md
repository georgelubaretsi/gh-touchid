# Sessions

```sh
gh-touchid session
gh-touchid session --repo acme/one --repo acme/two
```

`session` registers the program that ran it, such as the shell in your terminal or an agent's harness, for these
repositories:

- With `--repo`: the ones named.
- Without: the outermost Git repository containing the current folder, and the Git repositories nested up to two
  levels below it (an umbrella folder with clones inside). It keeps those with a github.com `origin` whose owner has
  an App stored.

gh-touchid looks past shells that only run a command or a script (`sh -c …`, `bash script.sh`) to the program that
started them. So a harness that runs `sh -c 'gh-touchid session'` registers itself. An interactive shell registers
itself.

Once registered, `session` warns on stderr, without changing its exit status, for each owner of those repositories
whose Git does not ask this gh-touchid alone, and when the `gh` first on PATH is not gh-touchid's wrapper: the same
lines, and fixes, as `status`, after `Warning: `.

The session is *pending* until its first GitHub use. Then one Touch ID window asks to let the program use those
repositories until it quits, and open issues in your other repositories. It names the program's folder and when it
started. From then on, the program and everything it starts get tokens for those repositories without Touch ID,
until it exits.

- **Other repositories** that one of your Apps is installed on get issue-only tokens: open and comment on issues, read
  the code, never `workflows`, even when elevated. A private one needs no dialog. A public one asks for Touch ID on
  each use (the window marks it public), and the token is revoked if you decline. Git gets the issue-only token for a
  private repository, so fetching works and pushing does not. It gets nothing for a public one, which it reads
  without a credential.
- **Processes outside the session** still ask for Touch ID on each use. Acting as an account always does.
- **Several commands at once**: when commands of a pending session start together, one dialog covers them all.
- **Nesting**: for each repository, an approved session that lists it decides, even when a pending session that does
  not list it was registered further down.
- **Running `session` again** from the same program with the same repositories keeps its approval. Other repositories
  make it pending again.
- gh-touchid knows nothing about agent tools. An agent harness, or a plugin of it, runs `gh-touchid session` at the
  start of its session. In a terminal, running it makes that shell a session.

# Elevating a repository

Tokens get only the everyday permissions, at most at these levels: contents, pull requests, issues and Actions to
write; checks, commit statuses and metadata to read. Everything else the App has reaches a token only while the
repository is elevated for it: `workflows`, which changing `.github/workflows` needs; `environments` and `secrets`,
which [`app create`](setup.md#1-a-github-app-per-owner) also asks for, to set an environment's secrets and variables
or the repository's Actions secrets; any permission added to the App, such as Variables (`actions_variables`, for
the repository's Actions variables) or Administration; and one of the everyday ones at a higher level. A permission
GitHub adds later is held back the same way.

Elevating a repository lets the permissions you name through for a while, at the level the App has:

```sh
gh-touchid elevate --for 30m --repo acme/one
gh-touchid elevate --for 30m --repo acme/one --permission environments --permission secrets
```

- `elevate` asks for Touch ID. The window names the repositories, the permissions and the duration.
- `--for` takes `30m`, `8h`, `1h30m` or `1d`, the longest.
- Each `--repo` names one repository. Without one, the current repository is elevated.
- Each `--permission` names one permission as GitHub spells it (`environments`, `secrets`, `actions_variables`,
  `administration`). Without one, `elevate` adds `workflows`. A permission is elevated only for the repositories
  named, and only until the end time.
- Running `elevate` again sets a new end time for the permissions it names.
- `status` lists each elevated repository and permission with its end time.
- Elevation counts when a token is made, which is after any Touch ID dialog. A command still waiting on a dialog when
  the elevation ends, or when `lock` runs, gets a token without those permissions.
- When `gh` fails with a token made without a permission the App has, other than `workflows`, a notice names the
  permissions and the `elevate --permission` command. GitHub itself says only "Resource not accessible by
  integration".
- The background agent of an earlier release (0.7.0 and before) elevates for `workflows` only. While it runs,
  `elevate` with any other permission is refused before the Touch ID window; it exits once its sessions and
  elevations end, or `gh-touchid lock` ends it now. Elevations made through 0.7.0 count for `workflows` only.
