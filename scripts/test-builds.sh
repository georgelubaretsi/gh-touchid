#!/usr/bin/env bash
# Builds what `just test` runs, in build/test/: the test build, and the builds the tests of agent identity need to meet
# other releases (tests/agents.test.ts).
#
#   scripts/test-builds.sh [--xcode PATH]
#
#   build/test/gh-touchid           the test build; its list of earlier releases has older/, previous/ and legacy/
#   build/test/gh-touchid-adapter   gh-touchid-adapter, which the tests of rpc and mcp name in GH_TOUCHID_ADAPTER
#   build/test/older/gh-touchid     the same sources stating version 0.1.0
#   build/test/revoking/gh-touchid  the test build with older/ revoked on its list
#   build/test/later/gh-touchid     the same sources stating version 9.0.0: a later release to 0.4.2
#   build/test/previous/gh-touchid  gh-touchid 0.4.2 (git archive v0.4.2), the last release of agent protocol 1, as a
#                                   test build, built again only when the tag moves
#   build/test/legacy/gh-touchid    gh-touchid 0.4.1 (git archive v0.4.1, which needs the tag) as a test build, built
#                                   again only when the tag moves
#   build/test/pinned-gh            a link to GitHub's gh as release/gh.json pins it (scripts/pinned-gh.sh path): the
#                                   tests use it as the judge of what gh does with a command line
#
# The lists pin both architectures of older/ and previous/, and only arm64 of legacy/: 0.4.1's build.sh left its
# x86_64 slice unsigned, so the tests of 0.4.1 need Apple silicon.
set -euo pipefail

fail() {
  echo "test-builds.sh: $*" >&2
  exit 1
}

xcode=()
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --xcode ] || fail "usage: scripts/test-builds.sh [--xcode PATH]"
  xcode=(--xcode "$2")
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/test"
legacy_tag=v0.4.1
legacy_version=0.4.1
previous_tag=v0.4.2
previous_version=0.4.2
older_version=0.1.0
later_version=9.0.0
legacy_commit="$(git -C "$root" rev-parse --verify --quiet "$legacy_tag^{commit}")" ||
  fail "needs the tag $legacy_tag in this clone"
previous_commit="$(git -C "$root" rev-parse --verify --quiet "$previous_tag^{commit}")" ||
  fail "needs the tag $previous_tag in this clone"
mkdir -p "$out"
pinned_gh="$("$root/scripts/pinned-gh.sh" path)"
ln -sfn "$pinned_gh" "$out/pinned-gh"

build() {
  "$root/scripts/build.sh" --testing ${xcode[@]+"${xcode[@]}"} "$@"
}

# A release's sources at COMMIT, built as a test build into build/test/FOLDER; kept while the commit stays the same.
build_tagged() {
  local folder=$1 commit=$2
  if [ -x "$out/$folder/gh-touchid" ] && [ "$(cat "$out/$folder/commit" 2>/dev/null)" = "$commit" ]; then
    return
  fi
  local sources
  sources="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-$folder.XXXXXX")"
  git -C "$root" archive "$commit" | tar -x -C "$sources"
  rm -f "$out/$folder/commit"
  "$sources/scripts/build.sh" --output "$out/$folder/gh-touchid" --testing ${xcode[@]+"${xcode[@]}"}
  echo "$commit" > "$out/$folder/commit"
  rm -rf "$sources"
}

# The cdhash of one architecture of a build.
cdhash() {
  local hash
  hash="$(/usr/bin/codesign -d -vvv --arch "$2" "$1" 2>&1 | sed -n 's/^CDHash=//p')"
  [[ "$hash" =~ ^[0-9a-f]{40}$ ]] || fail "cannot read the $2 cdhash of $1"
  echo "$hash"
}

# Waits for every job; fails when any did.
wait_all() {
  local pid status=0
  for pid in "$@"; do
    wait "$pid" || status=1
  done
  [ "$status" -eq 0 ] || fail "a build failed"
}

build_tagged legacy "$legacy_commit" &
legacy_job=$!
build_tagged previous "$previous_commit" &
previous_job=$!
build --output "$out/older/gh-touchid" --testing-version "$older_version" --no-adapter &
older_job=$!
wait_all "$legacy_job" "$previous_job" "$older_job"

older="arm64=$(cdhash "$out/older/gh-touchid" arm64) x86_64=$(cdhash "$out/older/gh-touchid" x86_64)"
previous="arm64=$(cdhash "$out/previous/gh-touchid" arm64) x86_64=$(cdhash "$out/previous/gh-touchid" x86_64)"
legacy="arm64=$(cdhash "$out/legacy/gh-touchid" arm64)"
printf '%s trusted %s\n%s trusted %s\n%s trusted %s\n' "$older_version" "$older" "$previous_version" "$previous" \
  "$legacy_version" "$legacy" > "$out/known-releases"
printf '%s revoked %s\n' "$older_version" "$older" > "$out/known-releases-revoking"

# Only the test build has an adapter: SwiftPM builds one at a time in .build/, and one is all the tests need.
build --output "$out/gh-touchid" --known-releases "$out/known-releases" &
main_job=$!
build --output "$out/revoking/gh-touchid" --known-releases "$out/known-releases-revoking" --no-adapter &
revoking_job=$!
build --output "$out/later/gh-touchid" --testing-version "$later_version" --no-adapter &
later_job=$!
wait_all "$main_job" "$revoking_job" "$later_job"
