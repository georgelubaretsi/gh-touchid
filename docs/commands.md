# Command reference

`gh-touchid help` lists every command; `gh-touchid help <command>` or `gh-touchid <command> --help` shows one, with
an example.

| Command | What it does |
| --- | --- |
| `setup [<owner>...]` | set up what is missing: an App and sign-in per owner, Git, the reader |
| `app create <owner> [--name <name>] [--no-open] [--git-setup\|--no-git-setup]` | make the owner's private App in the browser and sign in to it |
| `app add <owner> --client-id <id> [--no-open] [--git-setup\|--no-git-setup] < client-secret` | use an App made by hand; reads its client secret, then signs in |
| `app login <owner> [--no-open]` | sign in to the owner's App again |
| `app remove <owner> [--yes]` | delete the owner's App, sign-in and Git entries; end the sign-in on GitHub |
| `reader create [--name <name>] [--no-open]` | make and store the [reader](setup.md#5-the-reader-optional) |
| `reader add --app-id <id> < private-key` | store a reader made by hand, or a new key for it |
| `reader remove [--yes]` | forget the reader |
| `account add <login> < token` | store a token of one of your GitHub accounts, once GitHub confirms the login |
| `account remove <login>` | delete that token |
| `gh <arguments...>` | run GitHub CLI with a token for one repository, or the reader's |
| `git setup <owner>` | make this gh-touchid Git's only credential helper for the owner's repositories |
| `git credential <get\|store\|erase>` | that helper; answers only Git's HTTPS transport |
| `as <login> [--] <command> [arguments...]` | run a command as one of your accounts, with Touch ID on every use |
| `session [--repo <owner/name>]...` | register the program that ran it as a [session](sessions.md#sessions) |
| `elevate --for <duration> [--repo <owner/name>]...` | add `workflows` to the repositories' tokens for a while |
| `status` | show Apps, accounts, the reader, Git and `gh` setup, sessions and elevations |
| `lock` | end every session approval and elevation now |
| `version` | print the version |
| `rpc`, `mcp` | serve the commands over JSON-RPC or MCP ([below](scripting.md#scripts-and-agents)) |
| `help [<command>]` | print every command's usage, or one command's |

Everything after `gh-touchid gh` goes to GitHub CLI, so `gh-touchid gh --help` is GitHub CLI's help.
