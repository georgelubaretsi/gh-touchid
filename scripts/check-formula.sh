#!/usr/bin/env bash
# Checks the Homebrew formula the way users get it, with the newest Homebrew: renders release/gh-touchid.rb.in for a
# tarball, then runs brew style, audit --strict, install, test and linkage with a throwaway copy of Homebrew in
# ~/Library/Caches/gh-touchid/check-formula, never the Homebrew you use. Run it through `just check-formula`.
#
#   scripts/check-formula.sh [TARBALL | FOLDER]
#
# A folder (default dist) must hold exactly one gh-touchid-*-macos.tar.gz, as scripts/package.sh writes it.
set -euo pipefail

fail() {
  echo "check-formula.sh: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-dist}"
if [ -d "$target" ]; then
  shopt -s nullglob
  found=("$target"/gh-touchid-*-macos.tar.gz)
  shopt -u nullglob
  [ ${#found[@]} -eq 1 ] || fail "$target must hold exactly one gh-touchid-*-macos.tar.gz (run just package)"
  target="${found[0]}"
fi
[ -f "$target" ] || fail "no such tarball: $target"
tarball="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
sha256="$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)"

# Homebrew refuses a prefix inside the folders its sandbox lets builds write to (the temporary folders), so the
# throwaway copy lives in the user's cache; Homebrew's downloads stay there between runs.
cache="${XDG_CACHE_HOME:-$HOME/Library/Caches}/gh-touchid/check-formula"
mkdir -p "$cache/downloads"
run="$(mktemp -d "$cache/run.XXXXXX")"
trap 'chmod -R u+w "$run" 2>/dev/null; rm -rf "$run"' EXIT
mkdir "$run/home"

# The newest Homebrew release: users have it, and a newer Homebrew is what disables formula syntax.
release="$(git ls-remote --tags --refs https://github.com/Homebrew/brew.git |
  sed -n 's|.*refs/tags/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' | sort -t . -k 1,1n -k 2,2n -k 3,3n | tail -n 1)"
[ -n "$release" ] || fail "found no Homebrew release"
echo "==> Homebrew $release in $run"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$release" https://github.com/Homebrew/brew.git \
  "$run/brew"

# Only this Homebrew's own settings: a clean environment, so nothing of the Homebrew you use (its prefix, cellar,
# repository, caches or settings in your home) reaches it.
brew() {
  env -i \
    HOME="$run/home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TERM="${TERM:-dumb}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOMEBREW_CACHE="$cache/downloads" \
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
    "$run/brew/bin/brew" "$@"
}

brew tap-new --no-git local/check >/dev/null
tap="$(brew --repository local/check)"
"$here/render-formula.sh" "file://$tarball" "$sha256" > "$tap/Formula/gh-touchid.rb"

formula=local/check/gh-touchid
for step in "style $formula" "audit --strict --formula $formula" "install $formula" "test $formula" \
  "linkage --test $formula"; do
  echo "==> brew $step"
  # shellcheck disable=SC2086 # each step is brew's arguments, split on purpose
  brew $step
done
echo "==> The formula installs and passes Homebrew's checks."
