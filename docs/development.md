# Building from source

gh-touchid is built with the Swift compiler of Xcode 26 or later, as one universal executable for arm64 and x86_64,
with no third-party code. Beside it, `gh-touchid-adapter` (for `rpc` and `mcp`) is built with SwiftPM from
`Package.swift`, using the versions pinned in `Package.resolved`; the first build fetches them from GitHub. Every task
goes through the justfile, inside the dev shell (`nix develop`, or direnv), which has `just` and the linters:

```sh
just build           # a development build in build/ (scripts/build.sh)
just test            # a test build (scripts/build.sh --testing) and the test suite in tests/, against a mock GitHub
just package         # the release tarball in dist/, as the release workflow builds it (scripts/package.sh)
just check-formula   # the Homebrew formula for dist/'s tarball, checked with a throwaway copy of the newest Homebrew
just lint            # the workflows with actionlint, the scripts with ShellCheck
just gh-reference    # gh's command list, release/gh-reference.md, from the pinned gh (scripts/pinned-gh.sh)
```

`scripts/build.sh` takes `--xcode` to pick the Xcode (default `/Applications/Xcode.app`) and `--xcode-version` to
refuse any other version.

## Development builds

A development build runs `GH_TOUCHID_GH` or the `gh` on PATH, unchecked. It keeps its own Keychain items
(`com.lubaretsi.gh-touchid.dev.*`), so trying one never reads or replaces an installed gh-touchid's Apps, sign-ins
and tokens. It keeps its own background agent too, which a rebuilt binary at the same path goes on using. It needs an
App of its own, with a name of its own:

```sh
build/gh-touchid app create acme --name acme-dev
```

## Release builds

`scripts/package.sh` downloads GitHub's `gh` for macOS from the release pinned in `release/gh.json`
(`scripts/pinned-gh.sh`, which keeps it in `build/pinned-gh/`), and refuses it unless its SHA-256 matches. It builds
gh-touchid to run only that `gh`, checked by its SHA-256 and by the cdhashes of its two slices (`scripts/build.sh` with
`--gh ../libexec/gh-touchid/gh`, `--gh-sha256` and `--gh-cdhash`).

gh-touchid reads `gh` command lines by `gh`'s own list of its commands and flags, `gh help reference`, and allows only
the commands on it that it does not ban. A release builds in `release/gh-reference.md` (`--gh-reference`), which
`just gh-reference` writes from the pinned `gh`; `scripts/package.sh` refuses to package unless it is exactly what that
`gh` prints, so a `gh` upgrade comes with a reviewed diff of `gh`'s commands. The Nix build from source builds in the
list of its own `gh`, and a development build reads it from the `gh` it runs.

On a `v*` tag, after the tarball passes its checks, the release workflow signs `bin/gh-touchid` and
`libexec/gh-touchid/gh-touchid-adapter` with `scripts/sign.sh`, in a job of the GitHub environment `release`, which
holds the certificate and the notary key and which only `v*` tags reach. It imports the Developer ID Application
certificate into a temporary keychain, signs with the hardened runtime, a secure timestamp and the identifiers
`com.lubaretsi.gh-touchid` and `com.lubaretsi.gh-touchid-adapter` (no entitlements), and has Apple's notary service
accept the result (`notarytool`). Then it repacks the tarball and its `.sha256` as
`scripts/package.sh` lays them out (`scripts/pack.sh`), checks that every other file, GitHub's `gh` above all, is
unchanged, and deletes the keychain and the keys. The signed tarball passes the tarball and formula checks again, and
only it is published: its SHA-256 goes into the formula and the Nix pin. Pull-request builds never see the secrets and
stay ad hoc signed. `scripts/sign.sh TARBALL --ad-hoc` signs with the ad hoc identity and the hardened runtime and
skips notarization, to check the repack and the hardened runtime without the certificate.

`just check-formula` (`nix run .#check-formula`) renders the formula for the tarball. Then it runs `brew style`,
`brew audit --strict`, `brew install`, `brew test` and `brew linkage`, and checks that Homebrew installed gh-touchid
and GitHub's `gh` byte for byte as the tarball has them, with a copy of Homebrew's newest release made for the check
in `~/Library/Caches/gh-touchid/check-formula` and deleted after it. So it needs no sudo and never touches the
Homebrew you use. The release workflow runs the same checks on every pull request and tag, before anything is
published. The tap runs `brew test-bot` on changes made there.

## Tests

`just test` builds the test builds (`scripts/test-builds.sh`): the current sources with their adapter, an older
version and one that marks it revoked, and v0.4.1 from its tag, which is built once and kept. They keep their state
in `GH_TOUCHID_TEST_DIR`, talk to a mock GitHub at `GH_TOUCHID_API_URL`, print `AUTH:` and `OPEN:` lines instead of
showing Touch ID or a browser, and run a fake `gh`, which prints `release/gh-reference.md` as its command list. The
pinned `gh` is linked at `build/test/pinned-gh`, for the tests that check what the real `gh` does with a command
line. Then `bun test` runs the suite in `tests/` against them; the `rpc` and `mcp` tests run the adapter through
`GH_TOUCHID_ADAPTER`. One test shows the real approval window for about a second, answered by the test build itself
rather than Touch ID, and checks with the window server that it leaves the screen; it needs a login session, as macOS
runners have. The tests need Apple silicon. The check workflow runs `just test` and `just lint` on every pull request
and push to main. The release workflow runs `just test` before packaging.

## Nix from source

The flake's `packages.<system>.from-source` builds through the same script with Xcode 27.0, which Nix cannot provide.
It pins nixpkgs' `gh` by its store path and SHA-256. Install Xcode 27.0 at `/Applications/Xcode.app` and build with
Nix's sandbox off or relaxed (`sandbox = false` or `sandbox = relaxed` in `nix.conf`; the package sets
`__noChroot`), with network access for SwiftPM to fetch the adapter's pinned packages. The build stops, naming the
Xcode it needs, when it finds another version. For an Xcode installed
elsewhere, or another version at your own risk, override the package:

```nix
gh-touchid.packages.${system}.from-source.override {
  xcode = { version = "27.0"; path = "/Applications/Xcode-27.0.app"; };
}
```
