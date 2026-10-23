#!/usr/bin/env bash
# Builds gh-touchid with Xcode's Swift compiler: arm64 and x86_64, joined into one universal executable. The release
# workflow and the flake's source build both call this script; it is the only place the compiler flags live.
#
#   scripts/build.sh --output FILE [--xcode PATH] [--xcode-version VERSION]
#                    [--gh PATH --gh-sha256 SHA256 [--gh-cdhash ARCH=CDHASH]...] [--known-releases FILE]
#                    [--testing [--testing-version VERSION]]
#
#   --output           where to write the executable
#   --xcode            the Xcode to build with (default /Applications/Xcode.app)
#   --xcode-version    refuse any other Xcode version, e.g. 27.0; an Xcode older than 26.0 is always refused
#   --gh               the GitHub CLI gh-touchid runs: an absolute path, or one relative to the folder of
#                      gh-touchid's own executable with symlinks resolved, such as ../libexec/gh-touchid/gh
#   --gh-sha256        the SHA-256 of that gh; gh-touchid refuses to run a gh whose SHA-256 differs
#   --gh-cdhash        the cdhash of one architecture of that gh (codesign -d -vvv --arch ARCH); with these, gh
#                      starts suspended and runs only if the code the kernel loaded has one of them
#   --known-releases   the earlier releases this build knows by their cdhashes, such as release/known-releases: one
#                      per line, `VERSION STATUS arm64=CDHASH x86_64=CDHASH`, STATUS trusted or revoked; lines
#                      starting with # and empty lines are ignored, any other line is refused
#   --testing          a test build (-D GH_TOUCHID_TESTING): state under GH_TOUCHID_TEST_DIR, the API at
#                      GH_TOUCHID_API_URL, no Touch ID or Keychain
#   --testing-version  with --testing only: the version the test build states instead of toolVersion, e.g. 0.4.0,
#                      for tests of one version meeting another
#
# Without --gh the result is a development build, which runs GH_TOUCHID_GH or the gh on PATH. Without
# --known-releases the build knows no earlier release.
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
gh_sha256=
gh_cdhashes=
known_releases=
testing=
testing_version=
while [ $# -gt 0 ]; do
  case "$1" in
    --output | --xcode | --xcode-version | --gh | --gh-sha256 | --gh-cdhash | --known-releases | --testing-version)
      [ $# -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --output) output=$2 ;;
        --xcode) xcode=$2 ;;
        --xcode-version) xcode_version=$2 ;;
        --gh) gh=$2 ;;
        --gh-sha256) gh_sha256=$2 ;;
        --gh-cdhash) gh_cdhashes="${gh_cdhashes:+$gh_cdhashes,}$2" ;;
        --known-releases) known_releases=$2 ;;
        --testing-version) testing_version=$2 ;;
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
path_pattern='^[A-Za-z0-9._+/-]+$'
sha256_pattern='^[0-9a-f]{64}$'
cdhashes_pattern='^(arm64|x86_64)=[0-9a-f]{40}(,(arm64|x86_64)=[0-9a-f]{40})*$'
if [ -n "$gh" ] || [ -n "$gh_sha256" ] || [ -n "$gh_cdhashes" ]; then
  [[ "$gh" =~ $path_pattern ]] || fail "--gh takes a path of letters, digits and ._+/- (got: $gh)"
  [[ "$gh_sha256" =~ $sha256_pattern ]] || fail "--gh-sha256 takes a SHA-256 in lowercase hex (got: $gh_sha256)"
  [ -z "$gh_cdhashes" ] || [[ "$gh_cdhashes" =~ $cdhashes_pattern ]] ||
    fail "--gh-cdhash takes arm64=CDHASH or x86_64=CDHASH, 40 lowercase hex digits (got: $gh_cdhashes)"
fi

version_pattern='^[0-9]+(\.[0-9]+)*$'
if [ -n "$testing_version" ]; then
  [ -n "$testing" ] || fail "--testing-version needs --testing"
  [[ "$testing_version" =~ $version_pattern ]] ||
    fail "--testing-version takes a version of digits and dots, such as 0.4.0 (got: $testing_version)"
fi

# The earlier releases, each line checked whole, joined as knownReleaseList holds them:
# `VERSION STATUS arm64=CDHASH,x86_64=CDHASH`, separated by `;`. A test build's x86_64 slice may have no cdhash, so an
# entry names at least one architecture; the release workflow lists both of every release.
releases=
if [ -n "$known_releases" ]; then
  [ -f "$known_releases" ] || fail "--known-releases: no such file: $known_releases"
  cdhash='[0-9a-f]{40}'
  release_pattern="^([0-9]+(\.[0-9]+)*) (trusted|revoked) (arm64=$cdhash( x86_64=$cdhash)?|x86_64=$cdhash)\$"
  listed=" "
  number=0
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    [[ "$line" =~ $release_pattern ]] ||
      fail "$known_releases:$number: not VERSION trusted|revoked arm64=CDHASH x86_64=CDHASH: $line"
    release_version=${BASH_REMATCH[1]}
    cdhashes=${BASH_REMATCH[4]}
    case "$listed" in
      *" $release_version "*) fail "$known_releases:$number: $release_version is listed twice" ;;
    esac
    listed="$listed$release_version "
    releases="${releases:+$releases;}$release_version ${BASH_REMATCH[3]} ${cdhashes/ /,}"
  done < "$known_releases"
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

# The sources, with the placeholders of a copy of BuildConfiguration.swift replaced: the gh to run, its SHA-256 and its
# cdhashes; the earlier releases; a test build's version. Each replacement applies on its own.
mkdir "$work/sources"
cp "$root"/Sources/GHTouchID/*.swift "$work/sources/"
configuration="$work/sources/BuildConfiguration.swift"
# Replaces the line that is PATTERN (a sed regular expression) with LINE, which the checks above keep free of sed's
# special characters, and fails saying it could not WHAT unless LINE is then in the copy.
configure() {
  local pattern=$1 line=$2 what=$3
  sed -e "s|^$pattern\$|$line|" "$configuration" > "$work/BuildConfiguration.swift"
  mv "$work/BuildConfiguration.swift" "$configuration"
  grep -qxF "$line" "$configuration" || fail "could not $what in BuildConfiguration.swift"
}
if [ -n "$gh" ]; then
  configure 'let pinnedGitHubCLI = "@gh@"' "let pinnedGitHubCLI = \"$gh\"" "pin gh"
  configure 'let pinnedGitHubCLISHA256 = "@gh-sha256@"' "let pinnedGitHubCLISHA256 = \"$gh_sha256\"" \
    "pin gh's SHA-256"
  configure 'let pinnedGitHubCLICDHashes = "@gh-cdhashes@"' "let pinnedGitHubCLICDHashes = \"$gh_cdhashes\"" \
    "pin gh's cdhashes"
fi
[ -z "$known_releases" ] ||
  configure 'let knownReleaseList = "@known-releases@"' "let knownReleaseList = \"$releases\"" \
    "build in the known releases"
[ -z "$testing_version" ] ||
  configure 'let toolVersion = "[^"]*"' "let toolVersion = \"$testing_version\"" "set the test build's version"

defines=()
[ -z "$testing" ] || defines=(-D GH_TOUCHID_TESTING)

for architecture in arm64 x86_64; do
  # `-disable-sandbox`: swiftc otherwise runs macro plugins under its own sandbox-exec, which fails as a Nix build user.
  # `-adhoc_codesign`: the linker signs only arm64 by default; an unsigned x86_64 slice (Intel, Rosetta) fails the
  # kernel's code-signature check that agent and clients make of each other. A release is signed again later.
  /usr/bin/xcrun --sdk macosx swiftc -O -swift-version 5 -disable-sandbox \
    -target "$architecture-apple-macos$minimum" -module-cache-path "$work/modules" \
    ${defines[@]+"${defines[@]}"} \
    -Xlinker -adhoc_codesign \
    -module-name GHTouchID "$work"/sources/*.swift -o "$work/gh-touchid-$architecture" \
    -framework Foundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework CryptoKit \
    -framework LocalAuthentication \
    -framework LocalAuthenticationEmbeddedUI \
    -framework Security
done
mkdir -p "$(dirname "$output")"
/usr/bin/xcrun lipo -create -output "$output" "$work/gh-touchid-arm64" "$work/gh-touchid-x86_64"
