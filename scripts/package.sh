#!/usr/bin/env bash
# Packages a release: gh-touchid-<version>-macos.tar.gz and its .sha256, in the output folder. The tarball holds
# gh-touchid and gh-touchid-adapter built by scripts/build.sh, and GitHub's own gh, downloaded from GitHub's release of
# the version pinned in release/gh.json and refused unless its SHA-256 matches the pin (scripts/pinned-gh.sh).
# gh-touchid is built with gh's command list, release/gh-reference.md, and only while that file is exactly what this
# gh's `gh help reference` prints:
#
#   gh-touchid-<version>-macos/
#     bin/gh-touchid                  checks libexec/gh-touchid/gh's SHA-256, and its cdhash as gh starts; reads gh's
#                                     command lines by release/gh-reference.md; knows the earlier releases in
#                                     release/known-releases
#     libexec/bin/gh                  runs `gh-touchid gh "$@"` with this installation's bin/gh-touchid; on PATH only
#                                     for those who put libexec/bin there, so it sits beside any other gh
#     libexec/gh-touchid/gh           GitHub's gh for macOS (universal, signed by GitHub)
#     libexec/gh-touchid/gh-LICENSE   gh's license
#     libexec/gh-touchid/gh-touchid-adapter
#                                     what `gh-touchid rpc|mcp` runs (JSON-RPC and MCP over stdio), found beside gh
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

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-package.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# GitHub's gh, exactly as pinned.
gh="$("$root/scripts/pinned-gh.sh" path)"
gh_license="$("$root/scripts/pinned-gh.sh" license)"

name="gh-touchid-$version-macos"
stage="$work/$name"
mkdir -p "$stage/bin" "$stage/libexec/bin" "$stage/libexec/gh-touchid"
install -m 755 "$gh" "$stage/libexec/gh-touchid/gh"
install -m 644 "$gh_license" "$stage/libexec/gh-touchid/gh-LICENSE"
# The command list gh-touchid is built with must be the one of the gh it ships: a gh upgrade reviews what changed in
# gh's commands before a release allows them.
"$root/scripts/pinned-gh.sh" reference "$stage/libexec/gh-touchid/gh" > "$work/gh-reference.md"
cmp -s "$work/gh-reference.md" "$root/release/gh-reference.md" ||
  fail "release/gh-reference.md is not the command list of the pinned gh; run \`just gh-reference\` and review the" \
    "change in gh's commands (git diff release/gh-reference.md) before committing it"
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
  --gh-reference "$root/release/gh-reference.md" --known-releases "$root/release/known-releases" \
  --output "$stage/bin/gh-touchid" --adapter-output "$stage/libexec/gh-touchid/gh-touchid-adapter"
chmod 755 "$stage/bin/gh-touchid" "$stage/libexec/gh-touchid/gh-touchid-adapter"
cat > "$stage/libexec/bin/gh" <<'EOF'
#!/bin/sh
# gh through gh-touchid: runs the bin/gh-touchid of the installation this script is in (../../bin/gh-touchid from its
# real folder), wherever a link to the script or to its folder is.
self="$(/usr/bin/readlink -f "$0")" || exit 1
exec "${self%/libexec/bin/*}/bin/gh-touchid" gh "$@"
EOF
chmod 755 "$stage/libexec/bin/gh"
install -m 644 "$root/LICENSE" "$root/README.md" "$stage/"

"$root/scripts/pack.sh" "$stage" "$output"
