# gh-touchid

Touch ID-gated GitHub credentials for macOS.

From a Git repository whose `origin` is on `github.com`, store its PAT once:

```sh
gh-touchid set
```

The Nix package provides both `gh-touchid` and a transparent `gh` wrapper. Normal commands prompt for Touch ID, then pass the PAT only to the pinned `gh` child process:

```sh
gh repo view
gh pr create
```

For HTTPS Git pushes, configure the current repository once:

```sh
git config --local credential.helper ""
git config --local --add credential.helper '!gh-touchid git-credential'
```

Run Git from the activated Nix/direnv shell so `gh-touchid` is available.

## Nix

Add the package to a Darwin development shell:

```nix
{
  inputs.gh-touchid.url = "github:GeorgeLubaretsi/gh-touchid";

  outputs = { nixpkgs, gh-touchid, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          gh-touchid.packages.${system}.default
          pkgs.git
        ];
      };
    };
}
```

Example `.envrc`:

```sh
use flake
```

Create a fine-grained PAT restricted to the repository and grant only the required GitHub permissions. Enter it with `gh-touchid set` in your own terminal; do not pass it as a command-line argument.

## AI agent usage

This workflow has been tested only with [Oh My Pi (OMP)](https://github.com/can1357/oh-my-pi) on macOS. Other agent harnesses have not been verified to keep hidden PTY input and Git credential-helper traffic outside model context.

- Run ordinary `gh` and Git commands from the activated Nix shell. `gh-touchid` supplies authentication automatically.
- Before starting an authenticated command, show the exact command to the user. The user decides whether to approve the Touch ID prompt.
- PAT enrollment is human-only. In OMP, run `nix develop -c gh-touchid set` in an interactive PTY; the user enters the PAT at the hidden prompt. Never request or accept a PAT through chat, tool arguments, environment dumps, or agent messages.
- Use an OMP supervised PTY for commands waiting on Touch ID so normal conversation does not abort the process.
- On first use, and sometimes after a `gh-touchid` upgrade, macOS may request the login Keychain password. The user may choose **Always Allow** only when the dialog identifies `gh-touchid` and the expected `owner/repository` Keychain item. This trusts that immutable Nix-built helper to read the item; `gh-touchid` still requires Touch ID before every command. Deny the request if it identifies Terminal, `security`, `gh`, `.gh-touchid-wrapped`, or another process.
- Explain the one-time Keychain prompt before starting the command. Never ask for, enter, or handle the user's Mac password.
- If Touch ID or Keychain authorization is canceled, stop and report it. Do not inspect the Keychain, switch credentials, or fall back to global `gh` authentication.
- Never invoke credential-revealing paths such as `gh auth token`, `git credential fill`, `gh-touchid git-credential get`, or `security find-generic-password -w`.
- Never enable shell or HTTP tracing around authenticated commands, including `set -x`, `GIT_TRACE`, `GIT_TRACE_CURL`, `GIT_CURL_VERBOSE`, or `GH_DEBUG`.
- Treat command stdout and stderr as model-visible. The PAT is intentionally available only to the pinned `gh` child or Git's credential pipe and must never be printed or inspected.

## Security model

- The PAT is not exported to the parent shell.
- The pinned `gh` child receives the raw PAT through `GH_TOKEN` for the duration of one command.
- Git receives the PAT through its credential-helper pipe.
- Token-display, auth-mutation, alias, and extension commands are blocked; each invocation uses a fresh empty `GH_CONFIG_DIR`.
- This unsigned build enforces Touch ID in `gh-touchid`; the ordinary Keychain item can alternatively be authorized by macOS with the account password.
