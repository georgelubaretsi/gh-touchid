#!/usr/bin/env bash
# GitHub's gh as release/gh.json pins it: its macOS pkg, downloaded from GitHub's release and refused unless its
# SHA-256 matches the pin, expanded once into build/pinned-gh/VERSION/ and reused while the pkg there still matches
# the pin and the gh expanded from it still has the SHA-256 recorded when it was expanded.
#
#   scripts/pinned-gh.sh path             prints the absolute path of the pinned gh
#   scripts/pinned-gh.sh license          prints the absolute path of its LICENSE
#   scripts/pinned-gh.sh reference [GH]   prints `gh help reference` of the pinned gh, or of GH
#
# The reference is gh's own list of its commands and flags, which gh-touchid reads command lines by
# (release/gh-reference.md, written by `just gh-reference`). gh runs with an empty environment but for a fresh, empty
# HOME and GH_CONFIG_DIR, GH_PAGER=cat and no update checks, so that no token, alias or extension of whoever runs it
# reaches the list, and with standard input from /dev/null; gh failing or printing nothing fails.
set -euo pipefail

fail() {
  echo "pinned-gh.sh: $*" >&2
  exit 1
}

root="$(cd "$(dirname "$0")/.." && pwd)"

# The pinned gh, downloaded and expanded unless the cache holds it; prints the folder of the expanded pkg.
expanded() {
  local pin="$root/release/gh.json" version pkg sha256 cache
  version="$(/usr/bin/plutil -extract version raw -o - "$pin")"
  pkg="$(/usr/bin/plutil -extract pkg raw -o - "$pin")"
  sha256="$(/usr/bin/plutil -extract sha256 raw -o - "$pin")"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "release/gh.json pins no version of digits and dots: $version"
  [[ "$pkg" =~ ^[A-Za-z0-9._-]+$ ]] || fail "release/gh.json pins no pkg file name: $pkg"
  cache="$root/build/pinned-gh/$version"
  local gh="$cache/pkg/com.github.cli.pkg/Payload/usr/local/bin/gh"
  # The marker holds the SHA-256 of the expanded gh, written last; without it, or with a pkg or gh that no longer
  # matches, everything is fetched again.
  if [ -f "$cache/$pkg" ] && [ -f "$cache/expanded" ] && [ -f "$gh" ] &&
    [ "$(sha256 "$cache/$pkg")" = "$sha256" ] && [ "$(sha256 "$gh")" = "$(cat "$cache/expanded")" ]; then
    echo "$cache/pkg"
    return
  fi

  rm -rf "$cache"
  mkdir -p "$cache"
  # Downloaded and expanded under temporary names, moved into place only once checked: an interrupted run leaves
  # nothing the next one would take for complete.
  local partial downloaded
  partial="$(mktemp "$cache/download.XXXXXX")"
  curl -fsSL --proto '=https' --retry 3 -o "$partial" "https://github.com/cli/cli/releases/download/v$version/$pkg"
  downloaded="$(sha256 "$partial")"
  [ "$downloaded" = "$sha256" ] || fail "$pkg has SHA-256 $downloaded; release/gh.json pins $sha256"
  mv "$partial" "$cache/$pkg"
  /usr/sbin/pkgutil --expand-full "$cache/$pkg" "$cache/pkg"
  [ -f "$gh" ] || fail "$pkg holds no com.github.cli.pkg/Payload/usr/local/bin/gh"
  [ -f "$cache/pkg/Resources/LICENSE" ] || fail "$pkg holds no Resources/LICENSE"
  sha256 "$gh" > "$cache/expanded.tmp"
  mv "$cache/expanded.tmp" "$cache/expanded"
  echo "$cache/pkg"
}

sha256() {
  local sum
  sum="$(/usr/bin/shasum -a 256 "$1")"
  echo "${sum%% *}"
}

usage="usage: scripts/pinned-gh.sh path | license | reference [GH]"
[ $# -ge 1 ] || fail "$usage"
case "$1" in
  path)
    [ $# -eq 1 ] || fail "$usage"
    pkg="$(expanded)"
    echo "$pkg/com.github.cli.pkg/Payload/usr/local/bin/gh"
    ;;
  license)
    [ $# -eq 1 ] || fail "$usage"
    pkg="$(expanded)"
    echo "$pkg/Resources/LICENSE"
    ;;
  reference)
    [ $# -le 2 ] || fail "$usage"
    if [ $# -eq 2 ]; then
      gh=$2
    else
      gh="$(expanded)/com.github.cli.pkg/Payload/usr/local/bin/gh"
    fi
    [ -x "$gh" ] || fail "no gh to run at $gh"
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-reference.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    mkdir "$scratch/home" "$scratch/config"
    # `env -i`: none of the caller's variables, GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN,
    # GH_HOST and XDG_* among them.
    env -i HOME="$scratch/home" GH_CONFIG_DIR="$scratch/config" GH_PAGER=cat GH_NO_UPDATE_NOTIFIER=1 \
      GH_NO_EXTENSION_UPDATE_NOTIFIER=1 PATH=/usr/bin:/bin "$gh" help reference < /dev/null > "$scratch/reference" ||
      fail "$gh help reference failed"
    [ -s "$scratch/reference" ] || fail "$gh help reference printed nothing"
    cat "$scratch/reference"
    ;;
  *) fail "$usage" ;;
esac
