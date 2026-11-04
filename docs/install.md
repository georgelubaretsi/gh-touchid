# Install

gh-touchid runs on macOS 26 (Tahoe) or later, on Apple silicon and Intel Macs. It uses the `git` on your PATH. Every
way to install it gives you the same release:

| File                    | What it is                                                                         |
| ----------------------- | ---------------------------------------------------------------------------------- |
| `bin/gh-touchid`        | gh-touchid itself, the only file that goes on your PATH                            |
| `libexec/bin/gh`        | a wrapper that runs `gh` through gh-touchid                                        |
| `libexec/gh-touchid/gh` | GitHub's own `gh` for macOS, the only `gh` gh-touchid runs ([details](security-model.md#which-gh-runs)) |
| `libexec/gh-touchid/gh-touchid-adapter` | the program `gh-touchid rpc` and `gh-touchid mcp` run; it holds no secrets ([details](scripting.md#scripts-and-agents)) |

## Homebrew

```sh
brew install georgelubaretsi/tap/gh-touchid
```

It installs beside Homebrew's `gh` formula. Homebrew's `opt` link keeps the wrapper's folder the same across updates:
`/opt/homebrew/opt/gh-touchid/libexec/bin` (`/usr/local/opt/…` on Intel).

## Release tarball

Download `gh-touchid-VERSION-macos.tar.gz` and its `.sha256` from the
[releases](https://github.com/GeorgeLubaretsi/gh-touchid/releases). Check it and unpack it into a folder that stays
put across updates:

```sh
shasum -a 256 -c gh-touchid-VERSION-macos.tar.gz.sha256
xattr -d com.apple.quarantine gh-touchid-VERSION-macos.tar.gz   # only for a download from a browser
mkdir -p ~/.local/gh-touchid
tar -xzf gh-touchid-VERSION-macos.tar.gz -C ~/.local/gh-touchid --strip-components 1
export PATH="$HOME/.local/gh-touchid/bin:$PATH"                 # in your shell's profile
export PATH="$HOME/.local/gh-touchid/libexec/bin:$PATH"         # also, to run `gh` through gh-touchid
```

A browser marks downloads as quarantined, and `tar` passes the mark on to the files it unpacks. Releases are
notarized, so macOS checks a quarantined gh-touchid with Apple, online, the first time it runs. Removing the attribute
before unpacking skips that check; so does `xattr -dr com.apple.quarantine ~/.local/gh-touchid` afterwards. `curl`
marks nothing. To update, unpack the new tarball over the old folder the same way.

## Nix

The flake has two packages that install the release tarball. Both need no Xcode and build with Nix's sandbox on.

| Package                       | Contents                                                                        |
| ----------------------------- | ------------------------------------------------------------------------------- |
| `packages.<system>.default`   | `bin/gh-touchid` and the wrapper in `libexec/bin`; no `bin/gh`                  |
| `packages.<system>.with-gh`   | the same, plus `bin/gh`: a link to the wrapper, to replace `gh` where installed |

In a Darwin development shell:

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
          gh-touchid.packages.${system}.default   # gh-touchid only; .with-gh for `gh` through it too
          pkgs.git
        ];
      };
    };
}
```

with an `.envrc` of `use flake`. Or in your profile:

```sh
nix profile install github:GeorgeLubaretsi/gh-touchid           # gh-touchid only; `gh` stays as it is
nix profile install github:GeorgeLubaretsi/gh-touchid#with-gh   # also `gh`, through gh-touchid
```

`with-gh` cannot share a profile with another package that has `bin/gh`, such as nixpkgs' `gh`. The release Nix
installs is pinned in `release/nix.json`, which each release updates. Without that file, `default` builds from source
like `packages.<system>.from-source` (see [Building from source](development.md#building-from-source)), which installs the same
files.

## Running `gh` through gh-touchid

Only `gh-touchid` goes on your PATH, so it installs beside any other `gh`. Git goes through gh-touchid once you
[set it up](setup.md#3-git). `gh` goes through it only if you choose one of these:

| Choice                                      | Who gets gh-touchid's `gh`                                  |
| ------------------------------------------- | ----------------------------------------------------------- |
| Put the wrapper's folder first in PATH      | every program that runs `gh` with that PATH, agents included |
| `alias gh='gh-touchid gh'`                  | your own interactive shell only                             |
| Run `gh-touchid gh …`                       | that command only                                           |

`gh-touchid status` prints the PATH line for your installation.

Uninstalling another `gh` does not make `gh` gh-touchid's: without one of the choices above, `gh` is not found.
gh-touchid never uses another `gh`'s login or configuration. But another `gh` that is signed in (`gh auth login`)
stays usable by any program running as you, whichever `gh` comes first on PATH. Run `gh auth logout` with it, or
uninstall it. `gh-touchid status` says which `gh` comes first on PATH and whether another one is signed in.

## Signed releases

Releases, which Homebrew and the flake's default package install, are signed with a Developer ID, run with the
hardened runtime, and are notarized by Apple. (GitHub's `gh` inside stays as GitHub signed it.) What that gives you:

- The login Keychain trusts gh-touchid by its signature (the identifier `com.lubaretsi.gh-touchid` and the Developer
  ID team), so **Always Allow** lasts across updates. Items allowed for an unsigned release ask for your login
  Keychain password once more, the first time a signed release reads them. Allow it only when the dialog names
  `gh-touchid`.
- The hardened runtime keeps other programs running as you from loading code into gh-touchid, such as a library
  through `DYLD_INSERT_LIBRARIES`. gh-touchid still does not defend against code that already runs as you (see
  [Security model](security-model.md#security-model)).
- macOS runs a quarantined copy, such as a browser download, after checking it with Apple (see above).

Development builds and the flake's build from source (`from-source`) are only ad hoc signed, by the linker, and run
without the hardened runtime. The Keychain remembers **Always Allow** for one exact executable, so each new build asks
for your login Keychain password again, and another program running as you could load code into one.
