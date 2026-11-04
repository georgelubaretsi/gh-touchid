# AI agent usage

This workflow has been tested only with [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) on macOS. Other agent
harnesses have not been verified to keep hidden PTY input and Git credential-helper traffic outside model context.

- Agents run ordinary `gh` and Git commands. Inside an approved session they need no Touch ID for the session's
  repositories and act as you through the App. Public data of other owners comes through the reader without Touch ID.
  Anything else asks for Touch ID on each use. For `gh`, the wrapper's folder must come first in the PATH the agent
  gets; an alias in your shell does not reach it.
- The reader is for reading. Its token is the reader App's bot, which GitHub lets open issues and perhaps more on
  public repositories; gh-touchid refuses opening issues and says so on every use. Agents must not create or change
  anything with it.
- Harnesses that speak MCP can run `gh-touchid mcp` as a server instead of a shell; the same approvals apply.
- Starting a session is the user's decision. The user, or a harness plugin, runs `gh-touchid session` from the agent's
  process (a tool's `sh -c` counts as the agent). The first GitHub use then shows the approval dialog, and the user
  decides. Outside a session, gh-touchid prints a hint to stderr with each per-use dialog.
- `elevate` and `as` are the user's decision too. Show the exact command, its repositories and duration before
  starting it.
- Storing Apps, sign-ins, account tokens and the reader's key is for humans only. Run `gh-touchid account add` and
  `app add` in an interactive PTY where the user types at the hidden prompt. Run `app create`, `app login` and
  `reader create` from the user's own terminal. Never request or accept a token, secret or key through chat, tool
  arguments, environment dumps or agent messages.
- Use an OMP supervised PTY for commands waiting on Touch ID, so that normal conversation does not abort the process.
- On first use, macOS may ask for the login Keychain password: a signed release once more after the first signed
  update, a development build after each new build. Choose **Always Allow** only when the dialog names `gh-touchid`
  and a `com.lubaretsi.gh-touchid` item. Deny it if it names Terminal, `security`, `gh` or another process. Never ask
  for, enter, or handle the user's Mac password.
- If Touch ID is declined or not answered (dialogs close after five minutes), stop and report it. Do not inspect the
  Keychain, switch credentials, or fall back to other GitHub authentication.
- Never invoke credential-revealing paths such as `gh auth token`, `git credential fill`,
  `gh-touchid git credential get` or `security find-generic-password -w`. Never talk to the agent's socket directly.
- Never enable shell or HTTP tracing around authenticated commands, including `set -x`, `GIT_TRACE`,
  `GIT_TRACE_CURL`, `GIT_CURL_VERBOSE` or `GH_DEBUG`.
- Treat command stdout and stderr as model-visible. Tokens are meant only for the pinned `gh` child and Git's
  credential pipe. They must never be printed or inspected.
