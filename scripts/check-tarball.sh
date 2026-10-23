#!/usr/bin/env bash
# Checks a release tarball the way it is installed: its layout, gh-touchid run through links as Homebrew links it, the
# gh wrapper, the bundled gh's SHA-256 and cdhashes pinned in both slices of gh-touchid, and a changed gh refused. The
# release workflow runs it on the tarball scripts/package.sh builds and again on the one scripts/sign.sh signs.
#
#   scripts/check-tarball.sh TARBALL [VERSION]
#
# With VERSION, `gh-touchid version` must print it. The checks run the tarball's gh-touchid, a release build that
# uses the login Keychain: outside a repository and with a changed gh it stops before reading it, but run this on a
# build machine, not on a Mac with gh-touchid set up.
set -euo pipefail

fail() {
  echo "check-tarball.sh: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: scripts/check-tarball.sh TARBALL [VERSION]"
tarball=$1
expected_version=${2:-}
[ -f "$tarball" ] || fail "no such tarball: $tarball"

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-check.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT

name="$(basename "$tarball" .tar.gz)"
mkdir "$work/unpacked" "$work/bin" "$work/opt"
tar -xzf "$tarball" -C "$work/unpacked"
root="$work/unpacked/$name"
[ -d "$root" ] || fail "$tarball holds no $name/"

# The layout: gh-touchid alone in bin/, the gh wrapper in libexec/bin/, so the tarball has no bin/gh to collide with
# another gh
bin="$(ls "$root/bin")"
[ "$bin" = gh-touchid ] || fail "bin/ holds $bin, not gh-touchid alone"
[ -x "$root/libexec/bin/gh" ] || fail "libexec/bin/gh is missing or not executable"

# Linked from other folders, as Homebrew links bin/ into its Cellar and opt/ to the installed version
ln -s "$root/bin/gh-touchid" "$work/bin/"
ln -s "$root" "$work/opt/gh-touchid"
lipo -info "$root/bin/gh-touchid" "$root/libexec/gh-touchid/gh"
"$work/bin/gh-touchid" help
version="$("$work/bin/gh-touchid" version)"
echo "gh-touchid version: $version"
[ -z "$expected_version" ] || [ "$version" = "$expected_version" ] ||
  fail "gh-touchid version prints $version, not $expected_version"

# The wrapper, through the opt link, runs this gh-touchid: outside a repository, with no account to act as,
# gh-touchid stops before asking for any token
if output="$(cd "$work" && "$work/opt/gh-touchid/libexec/bin/gh" --version 2>&1)"; then
  fail "the gh wrapper ran gh without gh-touchid"
fi
echo "$output"
case "$output" in
  *"gh-touchid: current Git repository must have an origin on github.com"*) ;;
  *) fail "the gh wrapper did not run gh-touchid" ;;
esac

# The bundled gh's SHA-256 and cdhashes, pinned in both slices of gh-touchid
gh="$root/libexec/gh-touchid/gh"
expected="$(shasum -a 256 "$gh" | cut -d ' ' -f 1)"
cdhashes="arm64=$(codesign -d -vvv --arch arm64 "$gh" 2>&1 | sed -n 's/^CDHash=//p')"
cdhashes="$cdhashes,x86_64=$(codesign -d -vvv --arch x86_64 "$gh" 2>&1 | sed -n 's/^CDHash=//p')"
echo "libexec/gh-touchid/gh: $expected $cdhashes"
for architecture in arm64 x86_64; do
  lipo -thin "$architecture" "$root/bin/gh-touchid" -output "$work/gh-touchid-$architecture"
  for pin in "$expected" "$cdhashes"; do
    grep -q -a -F "$pin" "$work/gh-touchid-$architecture" || fail "the $architecture gh-touchid does not pin $pin"
  done
done

# A changed gh is refused, through the gh wrapper reached by a link, before anything else happens.
cp -R "$root" "$work/changed"
printf '\n' >> "$work/changed/libexec/gh-touchid/gh"
ln -s "$work/changed/libexec/bin/gh" "$work/gh-changed"
if output="$("$work/gh-changed" -R octocat/hello-world api user 2>&1)"; then
  fail "gh-touchid ran a changed gh"
fi
echo "$output"
case "$output" in
  *"the gh next to gh-touchid was changed"*) ;;
  *) fail "gh-touchid did not refuse the changed gh as expected" ;;
esac
echo "check-tarball.sh: $tarball passes"
