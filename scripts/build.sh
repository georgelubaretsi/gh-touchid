#!/usr/bin/env bash
# Builds gh-touchid with Xcode's Swift compiler: arm64 and x86_64, joined into one universal executable. The release
# workflow and the flake's source build both call this script; it is the only place the compiler flags live.
#
#   scripts/build.sh --output FILE [--xcode PATH] [--xcode-version VERSION] [--gh PATH] [--testing]
#
#   --output         where to write the executable
#   --xcode          the Xcode to build with (default /Applications/Xcode.app)
#   --xcode-version  refuse any other Xcode version, e.g. 27.0; an Xcode older than 26.0 is always refused
#   --gh             the absolute path of the GitHub CLI gh-touchid runs
#   --testing        a test build (-D GH_TOUCHID_TESTING): state under GH_TOUCHID_TEST_DIR, the API at
#                    GH_TOUCHID_API_URL, no Touch ID or Keychain
#
# Without --gh the result is a development build, which runs GH_TOUCHID_GH or the gh on PATH.
set -euo pipefail

# The oldest Xcode, and the oldest macOS gh-touchid runs on.
minimum=26.0

fail() {
  echo "build.sh: $*" >&2
  exit 1
}

output=
xcode=/Applications/Xcode.app
xcode_version=
gh=
testing=
while [ $# -gt 0 ]; do
  case "$1" in
    --output | --xcode | --xcode-version | --gh)
      [ $# -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --output) output=$2 ;;
        --xcode) xcode=$2 ;;
        --xcode-version) xcode_version=$2 ;;
        --gh) gh=$2 ;;
      esac
      shift 2
      ;;
    --testing)
      testing=1
      shift
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$output" ] || fail "--output is required"
path_pattern='^/[A-Za-z0-9._+/-]+$'
if [ -n "$gh" ]; then
  [[ "$gh" =~ $path_pattern ]] || fail "--gh takes an absolute path of letters, digits and ._+/- (got: $gh)"
fi

# Xcode's own tools, with nothing of Nix's compiler setup in the way.
unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS MACOSX_DEPLOYMENT_TARGET CC CXX LD
export DEVELOPER_DIR="$xcode/Contents/Developer"
# First line only, without a pipe: `head` closing early is SIGPIPE under pipefail.
installed="$(/usr/bin/xcodebuild -version 2>&1)" || true
installed="${installed%%$'\n'*}"
if [ -n "$xcode_version" ] && [ "$installed" != "Xcode $xcode_version" ]; then
  fail "needs Xcode $xcode_version at $xcode; found: $installed"
fi
xcode_pattern='^Xcode ([0-9]+)(\.[0-9]+)*$'
[[ "$installed" =~ $xcode_pattern ]] || fail "no Xcode at $xcode: $installed"
[ "${BASH_REMATCH[1]}" -ge "${minimum%%.*}" ] || fail "needs Xcode $minimum or later; found: $installed at $xcode"

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The sources, with the gh to run pinned in a copy of BuildConfiguration.swift.
mkdir "$work/sources"
cp "$root"/Sources/GHTouchID/*.swift "$work/sources/"
if [ -n "$gh" ]; then
  configuration="$work/sources/BuildConfiguration.swift"
  sed -e "s|^let pinnedGitHubCLI = \"@gh@\"$|let pinnedGitHubCLI = \"$gh\"|" \
    "$root/Sources/GHTouchID/BuildConfiguration.swift" > "$configuration"
  grep -qx "let pinnedGitHubCLI = \"$gh\"" "$configuration" || fail "could not pin gh in BuildConfiguration.swift"
fi

defines=()
[ -z "$testing" ] || defines=(-D GH_TOUCHID_TESTING)

for architecture in arm64 x86_64; do
  # `-disable-sandbox`: swiftc otherwise runs macro plugins under its own sandbox-exec, which fails as a Nix build user.
  /usr/bin/xcrun --sdk macosx swiftc -O -swift-version 5 -disable-sandbox \
    -target "$architecture-apple-macos$minimum" -module-cache-path "$work/modules" \
    ${defines[@]+"${defines[@]}"} \
    -module-name GHTouchID "$work"/sources/*.swift -o "$work/gh-touchid-$architecture" \
    -framework Foundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework LocalAuthentication \
    -framework LocalAuthenticationEmbeddedUI \
    -framework Security
done
/usr/bin/xcrun lipo -create -output "$output" "$work/gh-touchid-arm64" "$work/gh-touchid-x86_64"
