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

## Security model

- The PAT is not exported to the parent shell.
- The pinned `gh` child receives the raw PAT through `GH_TOKEN` for the duration of one command.
- Git receives the PAT through its credential-helper pipe.
- Token-display, auth-mutation, alias, and extension commands are blocked; each invocation uses a fresh empty `GH_CONFIG_DIR`.
- This unsigned build enforces Touch ID in `gh-touchid`; the ordinary Keychain item can alternatively be authorized by macOS with the account password.
