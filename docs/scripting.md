# Scripts and agents

Every command takes these flags, before or after its words; after `gh`, `as` and `git credential`, whose arguments
belong to another program, only before them:

| Flag | What it does |
| --- | --- |
| `--json` | print the result as one JSON value on stdout; later versions only add fields |
| `--input <file\|->` | take the input as one JSON object, from a file or stdin, keyed as in the command's schema; flags are the same names in kebab-case |
| `--no-input` | never prompt; fail naming the command to run instead |

```sh
gh-touchid --json status
echo '{"owner": "acme"}' | gh-touchid --json --input - git setup
gh-touchid --json gh -R acme/widget pr list      # {"exit_code": 0, "stdout": "…", "stderr": "…"}
gh-touchid --help --json                         # every command as an MCP tool, with its JSON Schemas
```

- Exit status 0 is success, 2 wrong input, 1 anything else. Without `--json`, `gh` and `as` pass on the status of
  what they ran; with it, that status is `exit_code` in the output, and output over 1 MiB goes to a private file
  whose path replaces it.
- With `--json`, an error is the last line on stderr: `{"error": {"code": "no_app", "message": "…"}}`. The codes are
  stable; [errors.md](errors.md) lists them.
- What gh-touchid tells its caller besides the result goes to stderr as `gh-touchid: …` lines without `--json`, and
  with it into the result's `notices`, a list present only when there is any: the reader's notice, a token that could
  not be revoked, how to approve a session, a session's warnings, a problem with the background program, and which
  repository a failed `gh` had its token for when the command line did not name it. If the command fails instead, they
  go to stderr before the error line.
- Input is checked against the command's schema before anything is done, and every result against its output schema
  (a mismatch is an `output_invalid` error, a bug to report). Secrets (a client secret, a token, the reader's key)
  come only on stdin, never as flags or from an input file.
- `git credential get` answers only Git's own pipe, never `--json`.

`gh-touchid mcp` serves every command as an MCP tool over stdio, and `gh-touchid rpc` as JSON-RPC 2.0 methods, one
message per line, named as in `--help --json` (`app_create`, `gh`, `status`; see [commands.md](commands.md)). Both run
`libexec/gh-touchid/gh-touchid-adapter`, a separate program that holds no secrets and runs gh-touchid once per call.
Touch ID still decides what needs it. Commands that take a secret are refused there, with the command to run in a
terminal instead, so that a secret never passes through a model. Long commands report progress and stop when
cancelled (`notifications/progress`, `notifications/cancelled`).
