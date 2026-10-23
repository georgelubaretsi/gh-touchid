#!/usr/bin/env bash
# Signs gh-touchid in a release tarball with a Developer ID and the hardened runtime, has Apple notarize it, and
# repacks the tarball and its .sha256 in place with scripts/pack.sh. Only bin/gh-touchid changes: every other file,
# GitHub's gh above all (its SHA-256 and cdhashes are pinned inside gh-touchid), is checked to come out byte for byte
# and mode for mode as it went in. The release workflow runs it on tags only.
#
#   scripts/sign.sh TARBALL [--work FOLDER]
#   scripts/sign.sh TARBALL --ad-hoc
#
# From the environment (not with --ad-hoc):
#   MACOS_CERTIFICATE_P12_BASE64  the Developer ID Application certificate and its private key: a .p12, in base64
#   MACOS_CERTIFICATE_PASSWORD    the .p12's password
#   NOTARY_KEY_ID                 an App Store Connect API team key for notarytool: its key ID,
#   NOTARY_ISSUER_ID              its issuer ID,
#   NOTARY_KEY_P8                 and the text of its .p8 file
#
# The certificate goes into a temporary keychain in FOLDER (which must not exist yet; default a new temporary folder),
# deleted with the key files when the script exits.
#
# --ad-hoc signs with the ad-hoc identity and the hardened runtime instead, and skips notarization: it checks the
# repack and the hardened runtime on a Mac without the certificate. Its tarball is not for release.
set -euo pipefail

# gh-touchid's code signing identifier. With a Developer ID, the Keychain trusts gh-touchid by it and the team, so
# Always Allow lasts across updates.
identifier=com.lubaretsi.gh-touchid
# Apple's "Developer ID Certification Authority" G2 intermediate, which issues Developer ID certificates and is not
# among macOS's root certificates: https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer, by its SHA-256.
intermediate_url=https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
intermediate_sha256=f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a

fail() {
  echo "sign.sh: $*" >&2
  exit 1
}

tarball=
work=
ad_hoc=
while [ $# -gt 0 ]; do
  case "$1" in
    --work)
      [ $# -ge 2 ] || fail "--work needs a value"
      work=$2
      shift 2
      ;;
    --ad-hoc)
      ad_hoc=1
      shift
      ;;
    -*) fail "unknown argument: $1" ;;
    *)
      [ -z "$tarball" ] || fail "one tarball only"
      tarball=$1
      shift
      ;;
  esac
done
[ -n "$tarball" ] || fail "usage: scripts/sign.sh TARBALL [--work FOLDER | --ad-hoc]"
[ -z "$ad_hoc" ] || [ -z "$work" ] || fail "--ad-hoc takes no --work"
name="$(basename "$tarball" .tar.gz)"
[[ "$name" =~ ^gh-touchid-[0-9A-Za-z.+-]+-macos$ ]] || fail "not a release tarball: $tarball"
output="$(cd "$(dirname "$tarball")" && pwd)"
tarball="$output/$name.tar.gz"
[ -f "$tarball" ] || fail "no such tarball: $tarball"
(cd "$output" && /usr/bin/shasum -a 256 -c "$name.tar.gz.sha256") || fail "$tarball does not match its .sha256"
if [ -z "$ad_hoc" ]; then
  for variable in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_P8; do
    [ -n "${!variable:-}" ] || fail "$variable is not set"
  done
fi

keychain=
cleanup() {
  [ -z "$keychain" ] || /usr/bin/security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work"
}
if [ -n "$work" ]; then
  mkdir -m 700 "$work" || fail "--work must name a folder that does not exist yet: $work"
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/gh-touchid-sign.XXXXXX")"
fi
trap cleanup EXIT
work="$(cd "$work" && pwd -P)"

# Each path, its mode, and the SHA-256 of each file but bin/gh-touchid, the one file signing changes.
manifest() {
  (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r path; do
    hash=-
    if [ -f "$path" ] && [ "$path" != ./bin/gh-touchid ]; then
      hash="$(/usr/bin/shasum -a 256 < "$path")"
      hash="${hash%% *}"
    fi
    printf '%s %s %s\n' "$(/usr/bin/stat -f %Sp "$path")" "$hash" "$path"
  done)
}

# The binary signed with the identifier and the hardened runtime, in both slices; with a Developer ID, by the team
# TEAM, through Apple's chain, with a secure timestamp.
check_signature() {
  local binary=$1 team=$2 architecture info
  /usr/bin/codesign --verify --strict --all-architectures --verbose=2 "$binary"
  for architecture in arm64 x86_64; do
    info="$(/usr/bin/codesign -d -vv --arch "$architecture" "$binary" 2>&1)"
    echo "$info"
    grep -qxF "Identifier=$identifier" <<< "$info" || fail "the $architecture slice is not signed as $identifier"
    grep -qE '^CodeDirectory .* flags=0x[0-9a-f]+\(([a-z-]+,)*runtime(,[a-z-]+)*\)' <<< "$info" ||
      fail "the $architecture slice is signed without the hardened runtime"
    if [ -z "$team" ]; then
      grep -qxF 'Signature=adhoc' <<< "$info" || fail "the $architecture slice is not signed ad hoc"
      continue
    fi
    grep -qxF "TeamIdentifier=$team" <<< "$info" || fail "the $architecture slice is not signed by the team $team"
    grep -q '^Authority=Developer ID Application: ' <<< "$info" ||
      fail "the $architecture slice is not signed with a Developer ID Application certificate"
    grep -qxF 'Authority=Apple Root CA' <<< "$info" || fail "the $architecture slice's signature does not chain to Apple"
    grep -q '^Timestamp=' <<< "$info" || fail "the $architecture slice's signature has no secure timestamp"
  done
}

mkdir "$work/original" "$work/stage" "$work/repacked"
tar -xzf "$tarball" -C "$work/original"
tar -xzf "$tarball" -C "$work/stage"
[ -d "$work/stage/$name" ] || fail "$tarball holds no $name/"
binary="$work/stage/$name/bin/gh-touchid"
[ -f "$binary" ] || fail "$tarball holds no $name/bin/gh-touchid"

team=
if [ -n "$ad_hoc" ]; then
  /usr/bin/codesign --force --options runtime --identifier "$identifier" --sign - "$binary"
else
  # A keychain of its own, with a random password, for the certificate and the Developer ID intermediate.
  keychain="$work/signing.keychain-db"
  password="$(/usr/bin/openssl rand -hex 32)"
  /usr/bin/security create-keychain -p "$password" "$keychain"
  /usr/bin/security set-keychain-settings -lut 3600 "$keychain"
  /usr/bin/security unlock-keychain -p "$password" "$keychain"
  (umask 077 && printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | tr -d ' \t\r\n' | /usr/bin/base64 -d > "$work/certificate.p12")
  /usr/bin/security import "$work/certificate.p12" -k "$keychain" -f pkcs12 -P "$MACOS_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign
  rm -f "$work/certificate.p12"
  curl -fsSL --proto '=https' --retry 3 -o "$work/intermediate.cer" "$intermediate_url"
  downloaded="$(/usr/bin/shasum -a 256 "$work/intermediate.cer")"
  [ "${downloaded%% *}" = "$intermediate_sha256" ] ||
    fail "$intermediate_url has SHA-256 ${downloaded%% *}, not $intermediate_sha256"
  # The .p12 may carry the intermediate already, and importing a certificate the keychain holds fails. (The listing
  # is read whole first: with pipefail, grep -q leaving early could fail the pipe.)
  held="$(/usr/bin/security find-certificate -a -Z "$keychain")"
  if ! grep -qi "^SHA-256 hash: $intermediate_sha256\$" <<< "$held"; then
    /usr/bin/security import "$work/intermediate.cer" -k "$keychain" -f x509
  fi
  # codesign may use the key without a dialog; then the keychain joins the search list, for codesign to find it.
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null
  searched=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    searched+=("${line%\"}")
  done < <(/usr/bin/security list-keychains -d user)
  /usr/bin/security list-keychains -d user -s "$keychain" ${searched[@]+"${searched[@]}"}

  identities="$(/usr/bin/security find-identity -v -p codesigning "$keychain")"
  pattern='^ *[0-9]+\) ([0-9A-F]{40}) "Developer ID Application: .* \(([0-9A-Z]{10})\)"$'
  identity=
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      [ -z "$identity" ] || fail "the certificate holds more than one Developer ID Application identity"
      identity="${BASH_REMATCH[1]}"
      team="${BASH_REMATCH[2]}"
    fi
  done <<< "$identities"
  [ -n "$identity" ] || fail "no valid Developer ID Application identity in the certificate: $identities"
  echo "sign.sh: signing with $identity, team $team"
  /usr/bin/codesign --force --options runtime --timestamp --identifier "$identifier" --keychain "$keychain" \
    --sign "$identity" "$binary"
fi
check_signature "$binary" "$team"

if [ -z "$ad_hoc" ]; then
  (umask 077 && printf '%s\n' "$NOTARY_KEY_P8" > "$work/notary-key.p8")
  notary=(--key "$work/notary-key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  /usr/bin/ditto -c -k --keepParent "$binary" "$work/gh-touchid.zip"
  # notarytool's own exit status says nothing of the verdict; its JSON does.
  /usr/bin/xcrun notarytool submit "$work/gh-touchid.zip" "${notary[@]}" --wait --timeout 1h --output-format json \
    > "$work/submission.json" || true
  cat "$work/submission.json"
  submission="$(/usr/bin/plutil -extract id raw -o - "$work/submission.json" 2>/dev/null)" || submission=
  status="$(/usr/bin/plutil -extract status raw -o - "$work/submission.json" 2>/dev/null)" || status=
  [ -n "$submission" ] || fail "notarytool returned no submission"
  /usr/bin/xcrun notarytool log "$submission" "${notary[@]}" || true
  [ "$status" = Accepted ] || fail "Apple's notary service answered $status for submission $submission"
  rm -f "$work/notary-key.p8"
  # A bare executable cannot have its ticket stapled; Gatekeeper looks the ticket up online, as here.
  for attempt in 1 2 3 4 5 6; do
    if /usr/bin/codesign --verify --check-notarization -R=notarized --verbose=2 "$binary"; then
      break
    fi
    [ "$attempt" -lt 6 ] || fail "the notarization ticket is not available online"
    sleep 10
  done
fi

# The tarball and its .sha256 written again, then unpacked to check what changed and the signature as shipped.
"$(cd "$(dirname "$0")" && pwd)/pack.sh" "$work/stage/$name" "$output"
tar -xzf "$tarball" -C "$work/repacked"
manifest "$work/original/$name" > "$work/original.manifest"
manifest "$work/repacked/$name" > "$work/repacked.manifest"
diff -u "$work/original.manifest" "$work/repacked.manifest" ||
  fail "the repacked tarball differs from the original in more than bin/gh-touchid's contents"
check_signature "$work/repacked/$name/bin/gh-touchid" "$team"
cat "$output/$name.tar.gz.sha256"
