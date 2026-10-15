#!/usr/bin/env bash
# Packages a release: gh-touchid-<version>-macos.tar.gz and its .sha256, in the output folder. The tarball holds
# gh-touchid built by scripts/build.sh and GitHub's own gh, downloaded from GitHub's release of the version pinned in
# release/gh.json and refused unless its SHA-256 matches the pin:
#
#   gh-touchid-<version>-macos/
#     bin/gh-touchid                  checks libexec/gh-touchid/gh's SHA-256, and its cdhash as gh starts
#     libexec/bin/gh                  runs `gh-touchid gh "$@"` with this installation's bin/gh-touchid; on PATH only
#                                     for those who put libexec/bin there, so it sits beside any other gh
#     libexec/gh-touchid/gh           GitHub's gh for macOS (universal, signed by GitHub)
#     libexec/gh-touchid/gh-LICENSE   gh's license
#     LICENSE
#     README.md
#
#   scripts/package.sh [--output FOLDER] [--xcode PATH] [--xcode-version VERSION]
#
# --output defaults to dist; --xcode and --xcode-version go to scripts/build.sh.
set -euo pipefail

fail() {
  echo "package.sh: $*" >&2
  exit 1
}

output=dist
build_arguments=()
while [ $# -gt 0 ]; do
  case "$1" in
    --output | --xcode | --xcode-version)
      [ $# -ge 2 ] || fail "$1 needs a value"
      if [ "$1" = --output ]; then
        output=$2
      else
        build_arguments+=("$1" "$2")
      fi
      shift 2
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^let toolVersion = "\([^"]*\)"$/\1/p' "$root/Sources/GHTouchID/BuildConfiguration.swift")"
[ -n "$version" ] || fail "found no toolVersion in Sources/GHTouchID/BuildConfiguration.swift"
pin="$root/release/gh.json"
gh_version="$(/usr/bin/plutil -extract version raw -o - "$pin")"
gh_pkg="$(/usr/bin/plutil -extract pkg raw -o - "$pin")"
gh_sha256="$(/usr/bin/plutil -extract sha256 raw -o - "$pin")"

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# GitHub's gh, exactly as pinned.
curl -fsSL --proto '=https' --retry 3 -o "$work/$gh_pkg" \
  "https://github.com/cli/cli/releases/download/v$gh_version/$gh_pkg"
downloaded="$(/usr/bin/shasum -a 256 "$work/$gh_pkg")"
downloaded="${downloaded%% *}"
[ "$downloaded" = "$gh_sha256" ] || fail "$gh_pkg has SHA-256 $downloaded; release/gh.json pins $gh_sha256"
/usr/sbin/pkgutil --expand-full "$work/$gh_pkg" "$work/pkg"
gh="$work/pkg/com.github.cli.pkg/Payload/usr/local/bin/gh"
[ -f "$gh" ] || fail "$gh_pkg holds no com.github.cli.pkg/Payload/usr/local/bin/gh"

name="gh-touchid-$version-macos"
stage="$work/$name"
mkdir -p "$stage/bin" "$stage/libexec/bin" "$stage/libexec/gh-touchid"
install -m 755 "$gh" "$stage/libexec/gh-touchid/gh"
install -m 644 "$work/pkg/Resources/LICENSE" "$stage/libexec/gh-touchid/gh-LICENSE"
bundled="$(/usr/bin/shasum -a 256 "$stage/libexec/gh-touchid/gh")"
# The cdhash of each architecture of GitHub's gh: the code the kernel loads when gh starts must have one of them.
cdhash_arguments=()
for architecture in arm64 x86_64; do
  cdhash="$(/usr/bin/codesign -d -vvv --arch "$architecture" "$stage/libexec/gh-touchid/gh" 2>&1 |
    sed -n 's/^CDHash=//p')" || true
  [ -n "$cdhash" ] || fail "GitHub's gh has no code signature for $architecture"
  cdhash_arguments+=(--gh-cdhash "$architecture=$cdhash")
done
"$root/scripts/build.sh" ${build_arguments[@]+"${build_arguments[@]}"} \
  --gh ../libexec/gh-touchid/gh --gh-sha256 "${bundled%% *}" "${cdhash_arguments[@]}" \
  --output "$stage/bin/gh-touchid"
chmod 755 "$stage/bin/gh-touchid"
cat > "$stage/libexec/bin/gh" <<'EOF'
#!/bin/sh
# gh through gh-touchid: runs the bin/gh-touchid of the installation this script is in (../../bin/gh-touchid from its
# real folder), wherever a link to the script or to its folder is.
self="$(/usr/bin/readlink -f "$0")" || exit 1
exec "${self%/libexec/bin/*}/bin/gh-touchid" gh "$@"
EOF
chmod 755 "$stage/libexec/bin/gh"
install -m 644 "$root/LICENSE" "$root/README.md" "$stage/"

mkdir -p "$output"
COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
  --uid 0 --gid 0 --uname root --gname wheel -czf "$output/$name.tar.gz" -C "$work" "$name"
(cd "$output" && /usr/bin/shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "$output/$name.tar.gz"
