import Darwin
import Foundation

/// How to start gh: an executable and the arguments that precede gh's own.
struct GitHubCLI {
    let executable: URL
    let prefix: [String]
}

/// The `gh` to run: the one pinned at build time, or in a development build GH_TOUCHID_GH or `gh` on PATH.
func gitHubCLI() throws -> GitHubCLI {
    if pinnedGitHubCLI.hasPrefix("/") {
        guard FileManager.default.isExecutableFile(atPath: pinnedGitHubCLI) else {
            throw ToolError.missingGitHubCLI(pinnedGitHubCLI)
        }
        return GitHubCLI(executable: URL(fileURLWithPath: pinnedGitHubCLI), prefix: [])
    }

    if let configured = ProcessInfo.processInfo.environment["GH_TOUCHID_GH"] {
        guard configured.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configured) else {
            throw ToolError.missingGitHubCLI(configured)
        }
        return GitHubCLI(executable: URL(fileURLWithPath: configured), prefix: [])
    }
    return GitHubCLI(executable: URL(fileURLWithPath: "/usr/bin/env"), prefix: ["gh"])
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

/// While it exists, SIGINT, SIGQUIT, SIGHUP and SIGTERM no longer end gh-touchid, so that it can revoke the token it
/// minted: one that arrives before gh starts is remembered (and gh is not started), one that arrives while gh runs is
/// passed on to it. Signals reach this object through dispatch sources, outside any signal handler. SIGPIPE is
/// survived too, so a closed stderr cannot end gh-touchid before the revoke.
final class SignalRelay: @unchecked Sendable {
    private static let relayed = [SIGINT, SIGQUIT, SIGHUP, SIGTERM]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "gh-touchid.signals")
    private var sources: [DispatchSourceSignal] = []
    private var child: pid_t = 0
    private var pending: Int32?

    init() {
        // handlers rather than SIG_IGN, which gh would inherit; gh starts with the default actions again
        signal(SIGPIPE) { _ in }
        for number in Self.relayed {
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in relay(number) }
            source.resume()
            sources.append(source)
        }
    }

    /// The first signal that arrived while gh was not running.
    var received: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// gh now runs as `pid`; a signal that arrived just before it started is passed on now.
    func attach(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        child = pid
        if let number = pending {
            kill(pid, number)
        }
    }

    /// gh has exited; later signals are only remembered.
    func detach() {
        lock.lock()
        defer { lock.unlock() }
        child = 0
    }

    /// Restores the default actions.
    func remove() {
        for source in sources {
            source.cancel()
        }
        for number in Self.relayed + [SIGPIPE] {
            signal(number, SIG_DFL)
        }
    }

    private func relay(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if child > 0 {
            kill(child, number)
        } else if pending == nil {
            pending = number
        }
    }
}

/// Runs gh with `token`, in a fresh empty configuration directory, and returns its exit status. `relay` passes
/// signals on to gh while it runs.
func runGitHubCLI(_ cli: GitHubCLI, arguments: [String], token: String, relay: SignalRelay) throws -> Int32 {
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-touchid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let process = Process()
    process.executableURL = cli.executable
    process.arguments = cli.prefix + arguments
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

    do {
        try process.run()
    } catch {
        throw ToolError.missingGitHubCLI(cli.executable.path)
    }
    relay.attach(process.processIdentifier)
    process.waitUntilExit()
    relay.detach()

    if process.terminationReason == .uncaughtSignal {
        return 128 + process.terminationStatus
    }
    return process.terminationStatus
}
