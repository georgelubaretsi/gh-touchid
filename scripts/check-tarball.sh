#!/usr/bin/env bash
# Checks a release tarball the way it is installed: its layout, gh-touchid run through links as Homebrew links it, the
# gh wrapper, `gh-touchid rpc` finding and running gh-touchid-adapter, the bundled gh's SHA-256 and cdhashes pinned in
# both slices of gh-touchid, the earlier releases of release/known-releases built into both, a Developer ID signature
# that meets releaseCodeRequirement (and the adapter's, which must not), and a changed gh refused. The release workflow
# runs it on the tarball scripts/package.sh builds and again on the one scripts/sign.sh signs. It reads docs/,
# release/known-releases and BuildConfiguration.swift from the checkout it is in.
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
adapter="$root/libexec/gh-touchid/gh-touchid-adapter"
[ -x "$adapter" ] || fail "libexec/gh-touchid/gh-touchid-adapter is missing or not executable"
# README.md beside docs/, which it links into: every page of this checkout's docs/, as package.sh copies them
checkout="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$root/README.md" ] || fail "README.md is missing"
for page in "$checkout"/docs/*.md; do
  cmp -s "$page" "$root/docs/${page##*/}" || fail "docs/${page##*/} is missing or differs from this checkout's"
done

# Linked from other folders, as Homebrew links bin/ into its Cellar and opt/ to the installed version
ln -s "$root/bin/gh-touchid" "$work/bin/"
ln -s "$root" "$work/opt/gh-touchid"
lipo -info "$root/bin/gh-touchid" "$root/libexec/gh-touchid/gh" "$adapter"
for architecture in arm64 x86_64; do
  lipo "$adapter" -verify_arch "$architecture" || fail "gh-touchid-adapter has no $architecture slice"
done
"$work/bin/gh-touchid" help
version="$("$work/bin/gh-touchid" version)"
echo "gh-touchid version: $version"
[ -z "$expected_version" ] || [ "$version" = "$expected_version" ] ||
  fail "gh-touchid version prints $version, not $expected_version"

# The wrapper, through the opt link, runs this gh-touchid: outside a repository, with no account to act as and no
# reader stored (a build machine has none), gh-touchid stops before asking for any token
if output="$(cd "$work" && "$work/opt/gh-touchid/libexec/bin/gh" --version 2>&1)"; then
  fail "the gh wrapper ran gh without gh-touchid"
fi
echo "$output"
case "$output" in
  *"gh-touchid: no reader is stored; run \`gh-touchid reader create\`"*) ;;
  *) fail "the gh wrapper did not run gh-touchid" ;;
esac

# `gh-touchid rpc`, through the link, finds the adapter beside the bundled gh and answers a call by running this
# gh-touchid (`version` reads nothing stored).
request='{"jsonrpc":"2.0","id":1,"method":"version","params":{}}'
output="$(printf '%s\n' "$request" | "$work/bin/gh-touchid" rpc 2>&1)" || fail "gh-touchid rpc failed: $output"
echo "gh-touchid rpc: $output"
case "$output" in
  *'"result":{"version":"'"$version"'"}'*) ;;
  *) fail "gh-touchid rpc did not answer version with $version" ;;
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

# The earlier releases of release/known-releases, in both slices of gh-touchid as knownReleaseList holds them:
# `VERSION STATUS arm64=CDHASH,x86_64=CDHASH`. scripts/build.sh has checked each line.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  read -r release_version status cdhashes <<< "$line"
  entry="$release_version $status ${cdhashes// /,}"
  for architecture in arm64 x86_64; do
    grep -q -a -F "$entry" "$work/gh-touchid-$architecture" ||
      fail "the $architecture gh-touchid does not know the release $entry"
  done
  echo "known release: $entry"
done < "$checkout/release/known-releases"

# Signed with a Developer ID, each slice meets the designated requirement that releases check of a newer release; the
# adapter's slices, signed by the same team under an identifier of their own, do not, so no release trusts it.
requirement="$(sed -n 's/^let releaseCodeRequirement = #"\(.*\)"#$/\1/p' \
  "$checkout/Sources/GHTouchID/BuildConfiguration.swift")"
[ -n "$requirement" ] || fail "found no releaseCodeRequirement in Sources/GHTouchID/BuildConfiguration.swift"
for architecture in arm64 x86_64; do
  info="$(codesign -d -vv --arch "$architecture" "$root/bin/gh-touchid" 2>&1)"
  if grep -q '^Authority=Developer ID Application: ' <<< "$info"; then
    # `-R` and its value apart: in `-R=…` the `=` would be read as the start of the value, doubling the literal `=`.
    codesign --verify --strict --arch "$architecture" -R "=$requirement" --verbose=2 "$root/bin/gh-touchid" ||
      fail "the $architecture gh-touchid does not meet releaseCodeRequirement: $requirement"
    codesign --verify --strict --arch "$architecture" --verbose=2 "$adapter" ||
      fail "the $architecture gh-touchid-adapter's signature is not valid"
    if codesign --verify --arch "$architecture" -R "=$requirement" "$adapter" 2>/dev/null; then
      fail "the $architecture gh-touchid-adapter meets releaseCodeRequirement, which only gh-touchid may"
    fi
  else
    echo "the $architecture gh-touchid is not signed with a Developer ID: releaseCodeRequirement not checked"
  fi
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
