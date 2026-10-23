#!/usr/bin/env bash
# Builds what `just test` runs, in build/test/: the test build, and the builds the tests of agent identity need to meet
# other releases (tests/agents.test.ts).
#
#   scripts/test-builds.sh [--xcode PATH]
#
#   build/test/gh-touchid           the test build; its list of earlier releases has older/ and legacy/, trusted
#   build/test/older/gh-touchid     the same sources stating version 0.1.0
#   build/test/revoking/gh-touchid  the test build with older/ revoked on its list
#   build/test/legacy/gh-touchid    gh-touchid 0.4.1 (git archive v0.4.1, which needs the tag) as a test build, built
#                                   again only when the tag moves
#
# The lists pin both architectures of older/, and only arm64 of legacy/: 0.4.1's build.sh left its x86_64 slice
# unsigned, so the tests of 0.4.1 need Apple silicon.
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
older_version=0.1.0
legacy_commit="$(git -C "$root" rev-parse --verify --quiet "$legacy_tag^{commit}")" ||
  fail "needs the tag $legacy_tag in this clone"
mkdir -p "$out"

build() {
  "$root/scripts/build.sh" --testing ${xcode[@]+"${xcode[@]}"} "$@"
}

build_legacy() {
  if [ -x "$out/legacy/gh-touchid" ] && [ "$(cat "$out/legacy/commit" 2>/dev/null)" = "$legacy_commit" ]; then
    return
  fi
  local sources
  sources="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-legacy.XXXXXX")"
  git -C "$root" archive "$legacy_commit" | tar -x -C "$sources"
  rm -f "$out/legacy/commit"
  "$sources/scripts/build.sh" --output "$out/legacy/gh-touchid" --testing ${xcode[@]+"${xcode[@]}"}
  echo "$legacy_commit" > "$out/legacy/commit"
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

build_legacy &
legacy_job=$!
build --output "$out/older/gh-touchid" --testing-version "$older_version" &
older_job=$!
wait_all "$legacy_job" "$older_job"

older="arm64=$(cdhash "$out/older/gh-touchid" arm64) x86_64=$(cdhash "$out/older/gh-touchid" x86_64)"
legacy="arm64=$(cdhash "$out/legacy/gh-touchid" arm64)"
printf '%s trusted %s\n%s trusted %s\n' "$older_version" "$older" "$legacy_version" "$legacy" > "$out/known-releases"
printf '%s revoked %s\n' "$older_version" "$older" > "$out/known-releases-revoking"

build --output "$out/gh-touchid" --known-releases "$out/known-releases" &
main_job=$!
build --output "$out/revoking/gh-touchid" --known-releases "$out/known-releases-revoking" &
revoking_job=$!
wait_all "$main_job" "$revoking_job"
