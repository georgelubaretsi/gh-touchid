// The Nix build replaces the placeholder with the absolute path of the GitHub CLI it pins; a development build keeps
// it and finds `gh` through GH_TOUCHID_GH or PATH instead.
let pinnedGitHubCLI = "@gh@"
