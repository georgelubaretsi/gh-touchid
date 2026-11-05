# Every task goes through here; the work lives in scripts/ and the flake. Run inside the dev shell (`nix develop`, or
# direnv), which has just and the linters; Xcode builds gh-touchid.

# List the recipes
default:
    @just --list

# Development build for this Mac (runs GH_TOUCHID_GH or the gh on PATH), gh-touchid-adapter beside it (scripts/build.sh)
build output="build/gh-touchid" *args:
    scripts/build.sh --output {{ output }} {{ args }}

# The release tarball and its .sha256 in dist/, as the release workflow builds it (scripts/package.sh)
package *args:
    scripts/package.sh {{ args }}

# gh's command list, release/gh-reference.md, from the gh release/gh.json pins (scripts/pinned-gh.sh); review its diff
gh-reference:
    scripts/pinned-gh.sh reference > release/gh-reference.md

# docs/commands.md and docs/errors.md from `--help --json` of a test build of these sources, made in build/reference/
# with $XCODE when it is set (scripts/reference.ts); review their diff
reference:
    scripts/build.sh --testing --no-adapter --output build/reference/gh-touchid ${XCODE:+--xcode "$XCODE"}
    bun scripts/reference.ts build/reference/gh-touchid

# The Homebrew formula checked against a tarball (default: the one in dist/) with a throwaway newest Homebrew
check-formula tarball="dist":
    nix run .#check-formula -- {{ tarball }}

# The black-box tests in tests/ (Bun, with the dependencies locked in tests/bun.lock) against the test builds in
# build/test/ (scripts/test-builds.sh), made with $XCODE when it is set; then that docs/commands.md and docs/errors.md
# are what the test build declares (scripts/reference.ts --check)
test *args:
    scripts/test-builds.sh ${XCODE:+--xcode "$XCODE"}
    bun install --cwd tests --frozen-lockfile
    bun test --concurrent --timeout 30000 ./tests {{ args }}
    bun scripts/reference.ts --check build/test/gh-touchid

# The workflows, the shell scripts with ShellCheck, that only Launch.swift starts programs (scripts/check-launch.sh), and
# the documentation's links and #anchors, offline (lychee)
lint:
    actionlint
    shellcheck scripts/*.sh
    scripts/check-launch.sh
    lychee --offline --include-fragments --no-progress README.md SECURITY.md AGENTS.md CHANGELOG.md docs
