// Release and Nix builds replace the placeholders (scripts/build.sh --gh, --gh-sha256, --gh-cdhash) with the GitHub
// CLI they ship and its SHA-256: an absolute path (Nix), or a path relative to the folder of gh-touchid's own
// executable with symlinks resolved (a release: ../libexec/gh-touchid/gh). gh-touchid runs only that gh, and only
// while its SHA-256 matches. A release also pins the cdhash of each architecture of GitHub's gh (`arm64=…,x86_64=…`),
// which the code the kernel loads must have before gh runs with a token; the Nix build pins none, its gh being in the
// read-only store. A development build keeps the placeholders and finds `gh` through GH_TOUCHID_GH or PATH instead.
let pinnedGitHubCLI = "@gh@"
let pinnedGitHubCLISHA256 = "@gh-sha256@"
let pinnedGitHubCLICDHashes = "@gh-cdhashes@"

// A release replaces this placeholder (scripts/build.sh --known-releases release/known-releases) with the earlier
// releases it knows by the cdhash of each architecture of their signed executable: entries separated by `;`, each
// `VERSION STATUS arm64=CDHASH,x86_64=CDHASH`, STATUS being `trusted` or `revoked` and CDHASH 40 lowercase hex digits.
// A value still starting with `@`, as in development builds and the Nix build from source, is an empty list.
let knownReleaseList = "@known-releases@"

// The designated requirement of every release: gh-touchid's identifier, signed with a Developer ID of its team. A
// peer that satisfies it and states a newer version than this one is trusted as a later release. The release workflow
// (scripts/check-tarball.sh) checks that each Developer ID signed tarball satisfies it, so it must change together
// with the identifier or the team that scripts/sign.sh signs with.
let releaseCodeRequirement = #"identifier "com.lubaretsi.gh-touchid" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "84L9Y3U6ZS""#

/// gh-touchid's version, printed by `gh-touchid version`. The flake reads it for its package, and the release
/// workflow checks the tag against it.
let toolVersion = "0.4.2"
