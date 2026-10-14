import Darwin
import Foundation

/// The `gh` to run: the one pinned at build time, or in a development build GH_TOUCHID_GH or `gh` on PATH.
private func gitHubCLI() throws -> (URL, [String]) {
    if pinnedGitHubCLI.hasPrefix("/") {
        guard FileManager.default.isExecutableFile(atPath: pinnedGitHubCLI) else {
            throw ToolError.missingGitHubCLI(pinnedGitHubCLI)
        }
        return (URL(fileURLWithPath: pinnedGitHubCLI), [])
    }

    if let configured = ProcessInfo.processInfo.environment["GH_TOUCHID_GH"] {
        guard configured.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configured) else {
            throw ToolError.missingGitHubCLI(configured)
        }
        return (URL(fileURLWithPath: configured), [])
    }
    return (URL(fileURLWithPath: "/usr/bin/env"), ["gh"])
}

/// Commands that would print the token, store it elsewhere, or run code gh-touchid does not know about.
func isForbiddenGitHubCommand(_ arguments: [String]) -> Bool {
    if arguments.contains(where: { $0 == "--show-token" || $0.hasPrefix("--show-token=") }) {
        return true
    }
    guard let command = arguments.first else {
        return false
    }
    if ["alias", "extension", "extensions", "ext"].contains(command) {
        return true
    }
    guard command == "auth" else {
        return false
    }
    guard arguments.count >= 2, arguments[1] == "status" else {
        return true
    }
    // `-t` is `auth status --show-token`, also inside a group of short flags such as `-at`
    return arguments.dropFirst(2).contains { argument in
        argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains("t")
    }
}

/// Runs gh with `token`, in a fresh empty configuration directory, and returns its exit status.
func runGitHubCLI(arguments: [String], token: String) throws -> Int32 {
    let (executable, prefix) = try gitHubCLI()
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-touchid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let process = Process()
    process.executableURL = executable
    process.arguments = prefix + arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    var environment = ProcessInfo.processInfo.environment
    environment["GH_CONFIG_DIR"] = configDirectory.path
    environment["GH_PAGER"] = "cat"
    environment["GH_TOKEN"] = token
    environment.removeValue(forKey: "GITHUB_TOKEN")
    environment.removeValue(forKey: "GH_ENTERPRISE_TOKEN")
    process.environment = environment

    // Ctrl-C, Ctrl-\ and a closing terminal reach gh too; gh-touchid outlives it so the token can be revoked.
    // A handler, unlike SIG_IGN, is reset to the default in gh itself.
    let terminalSignals = [SIGINT, SIGQUIT, SIGHUP]
    for number in terminalSignals {
        signal(number) { _ in }
    }
    defer {
        for number in terminalSignals {
            signal(number, SIG_DFL)
        }
    }

    do {
        try process.run()
    } catch {
        throw ToolError.missingGitHubCLI(executable.path)
    }
    process.waitUntilExit()

    if process.terminationReason == .uncaughtSignal {
        return 128 + process.terminationStatus
    }
    return process.terminationStatus
}
