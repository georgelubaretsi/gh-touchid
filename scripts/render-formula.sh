#!/usr/bin/env bash
# Writes the Homebrew formula for one release tarball to stdout, from release/gh-touchid.rb.in. The release workflow
# renders the formula it publishes with it, and scripts/check-formula.sh the one it checks.
#
#   scripts/render-formula.sh URL SHA256
#
# URL is where Homebrew downloads the tarball (https:// for a release, file:// for a local check); SHA256 its SHA-256.
set -euo pipefail

fail() {
  echo "render-formula.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || fail "usage: scripts/render-formula.sh URL SHA256"
url=$1
sha256=$2
# Both go into a Ruby string and a sed replacement: allow only what a URL and a hex digest need.
[[ $url =~ ^(https|file)://[A-Za-z0-9._~/%+@:-]+\.tar\.gz$ ]] || fail "not a tarball URL: $url"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || fail "not a SHA-256: $sha256"

template="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/release/gh-touchid.rb.in"
sed -e "s|@URL@|$url|" -e "s|@SHA256@|$sha256|" "$template"
