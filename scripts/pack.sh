#!/usr/bin/env bash
# Packs a release folder into the tarball and its .sha256: FOLDER/../NAME becomes OUTPUT/NAME.tar.gz and
# OUTPUT/NAME.tar.gz.sha256, with no macOS metadata and every file owned by root:wheel. scripts/package.sh packs a new
# release with it, and scripts/sign.sh repacks one after signing gh-touchid, so both tarballs have the same layout.
#
#   scripts/pack.sh FOLDER OUTPUT
#
# Prints the tarball's path.
set -euo pipefail

fail() {
  echo "pack.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || fail "usage: scripts/pack.sh FOLDER OUTPUT"
[ -d "$1" ] || fail "no such folder: $1"
parent="$(cd "$(dirname "$1")" && pwd)"
name="$(basename "$1")"
output=$2

mkdir -p "$output"
COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
  --uid 0 --gid 0 --uname root --gname wheel -czf "$output/$name.tar.gz" -C "$parent" "$name"
(cd "$output" && /usr/bin/shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "$output/$name.tar.gz"
