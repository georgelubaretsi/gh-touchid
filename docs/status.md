# Status, lock and the access log

```sh
gh-touchid status [--json]
gh-touchid lock      # ends every session approval and elevation now
```

`status` shows:

- stored Apps, with who is signed in to each (or the `app login` to run), and your accounts (names only);
- the reader: its App and the account it belongs to, or `none`;
- for each owner, which credential helpers Git asks, with the fix unless it is this gh-touchid alone. That is
  `fix: gh-touchid git setup OWNER`, except when a setting Git reads after the global file (the repository's own
  `.git/config`, its worktree file, or `GIT_CONFIG_PARAMETERS`) overrides it: then the file and the command that
  removes the setting, such as `git config --local --unset-all credential.helper (set in ~/src/app/.git/config)`;
- which `gh` comes first on PATH: gh-touchid's wrapper, another `gh`, or none. Unless it is the wrapper, it prints the
  PATH line for this installation and the alias. For Homebrew that is the `opt` folder, which stays the same across
  updates;
- whether another `gh` is signed in, when a `gh` other than the wrapper is on PATH: `another gh is signed in as
  LOGIN: any program can use that login; gh auth logout to close it`. It runs no other `gh` to tell. It looks only
  for an `oauth_token` in gh's `hosts.yml` (in `GH_CONFIG_DIR`, `$XDG_CONFIG_HOME/gh` or `~/.config/gh`) and for
  gh's Keychain item `gh:github.com`, by its attributes, never its secret;
- sessions (pending or approved, program, folder, start time, repositories) and elevations.

Sessions and elevations live in a small background agent that `session` or `elevate` starts. Every release you have
installed shares one agent. After an upgrade the old release's agent keeps serving, so running sessions stay approved;
it exits when nothing is left, and the next use starts the new release's. Logging out or restarting ends everything
too. (See [Security model](security-model.md#sessions-and-the-background-agent).)

Every use, granted or refused, is logged to `~/Library/Logs/gh-touchid/access.log` with the chain of processes that
asked:

```text
granted acme/one (session agent[700]), elevated as octocat to gh-touchid[812] < git-remote-https[811] < git[810] < zsh[790] < agent[700]
granted acme/three (issues, session agent[700]) as octocat to …
granted kubevirt/kubevirt (reader gh-touchid-reader-1a2b3c) to …
granted acme/one (as octocat) to …
```

The log also records sign-ins, renewals, sessions registered, approved and ended, and elevations.
