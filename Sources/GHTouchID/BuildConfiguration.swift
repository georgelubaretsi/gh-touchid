// The Nix build replaces the placeholder with the absolute path of the GitHub CLI it pins; a development build keeps
// it and finds `gh` through GH_TOUCHID_GH or PATH instead.
let pinnedGitHubCLI = "@gh@"

/// gh-touchid's version, printed by `gh-touchid version`. The flake reads it for its package, and the release
/// workflow checks the tag against it.
let toolVersion = "0.3.0"
