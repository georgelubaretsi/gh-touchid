import Darwin
import Foundation

// `gh-touchid rpc` and `gh-touchid mcp` run a separate program, gh-touchid-adapter, in place of this process. The
// adapter speaks JSON-RPC and the MCP SDK (third-party code the core does not link) and runs this executable once per
// call with `--json --input -`, so every approval still comes from the core's own Touch ID. It holds no secrets and the
// agent does not trust it. A release finds it beside the pinned gh, in libexec/gh-touchid/ of the installation; only a
// development or test build lets GH_TOUCHID_ADAPTER pick it, as only those let GH_TOUCHID_GH pick gh.

/// The adapter's path relative to the real folder of gh-touchid's own executable in an installation: the tarball,
/// Homebrew's Cellar and the Nix packages all keep it there.
private let installedAdapter = "../libexec/gh-touchid/gh-touchid-adapter"

/// Replaces this process with gh-touchid-adapter in `mode` (`rpc` or `mcp`), telling it where this executable is.
/// Returns only by throwing: a usage error for another mode or any further argument, or `missingAdapter` when the
/// adapter is not there or cannot run.
func runAdapter(mode: String, arguments: [String]) throws -> Never {
    guard ["rpc", "mcp"].contains(mode), arguments.isEmpty else {
        throw ToolError.usage
    }
    let adapter = adapterPath()
    guard adapter.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: adapter),
          let core = ownRealExecutablePath else {
        throw ToolError.missingAdapter(adapter)
    }
    _ = try replaceProcess(with: adapter, arguments: [mode, "--core", core], searchPath: false)
    throw ToolError.missingAdapter(adapter)
}

/// Where the adapter is: in a release, `installedAdapter` from the real folder of this executable; in a development
/// or test build, GH_TOUCHID_ADAPTER when set (refused unless it is an absolute path), else gh-touchid-adapter beside
/// this executable, where scripts/build.sh writes it.
private func adapterPath() -> String {
    let folder = ownRealExecutablePath.map { ($0 as NSString).deletingLastPathComponent } ?? "/"
    guard pinnedGitHubCLI.hasPrefix("@") else {
        return resolved(installedAdapter, from: folder)
    }
    if let configured = ProcessInfo.processInfo.environment["GH_TOUCHID_ADAPTER"] {
        return configured
    }
    return (folder as NSString).appendingPathComponent("gh-touchid-adapter")
}

/// `relative` joined to `folder` as written, each `..` taking one component off, the way `pinnedGitHubCLIPath` joins
/// the pinned gh, so that the path named is the installed one even where it is a link.
private func resolved(_ relative: String, from folder: String) -> String {
    var components = (folder as NSString).pathComponents
    for part in relative.split(separator: "/") where part != "." {
        if part == ".." {
            if components.count > 1 {
                components.removeLast()
            }
        } else {
            components.append(String(part))
        }
    }
    return NSString.path(withComponents: components)
}
