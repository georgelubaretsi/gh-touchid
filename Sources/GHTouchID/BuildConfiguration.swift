// Release and Nix builds replace the placeholders (scripts/build.sh --gh, --gh-sha256) with the GitHub CLI they ship
// and its SHA-256: an absolute path (Nix), or a path relative to the folder of gh-touchid's own executable with
// symlinks resolved (a release: ../libexec/gh-touchid/gh). gh-touchid runs only that gh, and only while its SHA-256
// matches. A development build keeps the placeholders and finds `gh` through GH_TOUCHID_GH or PATH instead.
let pinnedGitHubCLI = "@gh@"
let pinnedGitHubCLISHA256 = "@gh-sha256@"

/// gh-touchid's version, printed by `gh-touchid version`. The flake reads it for its package, and the release
/// workflow checks the tag against it.
let toolVersion = "0.3.0"
