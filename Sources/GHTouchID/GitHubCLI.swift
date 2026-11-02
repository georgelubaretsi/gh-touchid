import CryptoKit
import Darwin
import Foundation

/// How to start gh: an executable and the arguments that precede gh's own. A pinned gh carries the SHA-256 its file
/// must still have and, for GitHub's gh in a release, the code directory hashes (cdhashes) of its architectures, one of
/// which the code the kernel loads must have when gh starts; a development build's gh carries neither.
struct GitHubCLI {
    let executable: URL
    let prefix: [String]
    let sha256: String?
    /// Pinned cdhash → its architecture; empty when gh is not pinned by cdhash.
    let cdhashes: [String: String]

    /// Refuses a pinned gh whose file has changed since gh-touchid was built.
    func verify() throws {
        guard let sha256 else {
            return
        }
        guard let data = try? Data(contentsOf: executable, options: .alwaysMapped) else {
            throw ToolError.missingGitHubCLI(executable.path)
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else {
            throw ToolError.changedGitHubCLI(executable.path)
        }
    }
}

/// The `gh` to run, checked: the one the build pinned (no environment variable changes it), or in a development build
/// GH_TOUCHID_GH or `gh` on PATH.
func gitHubCLI() throws -> GitHubCLI {
    if !pinnedGitHubCLI.hasPrefix("@") {
        let cli = GitHubCLI(
            executable: try pinnedGitHubCLIPath(),
            prefix: [],
            sha256: pinnedGitHubCLISHA256,
            cdhashes: pinnedCodeDirectoryHashes
        )
        guard FileManager.default.isExecutableFile(atPath: cli.executable.path) else {
            throw ToolError.missingGitHubCLI(cli.executable.path)
        }
        try cli.verify()
        return cli
    }

    if let configured = ProcessInfo.processInfo.environment["GH_TOUCHID_GH"] {
        guard configured.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configured) else {
            throw ToolError.missingGitHubCLI(configured)
        }
        return GitHubCLI(executable: URL(fileURLWithPath: configured), prefix: [], sha256: nil, cdhashes: [:])
    }
    return GitHubCLI(executable: URL(fileURLWithPath: "/usr/bin/env"), prefix: ["gh"], sha256: nil, cdhashes: [:])
}

/// `arm64=<cdhash>,x86_64=<cdhash>` as scripts/build.sh pins it, by cdhash; empty when the build pins none.
private let pinnedCodeDirectoryHashes: [String: String] = {
    guard !pinnedGitHubCLICDHashes.hasPrefix("@") else {
        return [:]
    }
    var hashes: [String: String] = [:]
    for entry in pinnedGitHubCLICDHashes.split(separator: ",") {
        let parts = entry.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            hashes[String(parts[1])] = String(parts[0])
        }
    }
    return hashes
}()

/// The pinned gh: its absolute path, or its relative path taken from the folder of gh-touchid's own executable with
/// symlinks resolved, since Homebrew links `bin/gh-touchid` from elsewhere into its Cellar. The relative path is joined
/// as written, `..` taken off that real folder, so that the path named is the installed one even if it is a link.
private func pinnedGitHubCLIPath() throws -> URL {
    if pinnedGitHubCLI.hasPrefix("/") {
        return URL(fileURLWithPath: pinnedGitHubCLI)
    }
    guard let executable = ownRealExecutablePath else {
        throw ToolError.missingGitHubCLI(pinnedGitHubCLI)
    }
    var components = ((executable as NSString).deletingLastPathComponent as NSString).pathComponents
    for part in pinnedGitHubCLI.split(separator: "/") where part != "." {
        if part == ".." {
            if components.count > 1 {
                components.removeLast()
            }
        } else {
            components.append(String(part))
        }
    }
    return URL(fileURLWithPath: NSString.path(withComponents: components))
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

/// Runs gh with `token`, in a fresh empty configuration directory, and returns its exit status. A gh pinned by cdhash
/// starts suspended, before its first instruction, and runs only once the code the kernel loaded for it (whichever
/// slice runs, natively or under Rosetta) has one of the pinned cdhashes; otherwise, or when that cannot be read, it is
/// killed unrun, so replacing the installed gh after the SHA-256 check cannot hand the token to another program.
/// `relay` passes signals on to gh once it runs; one that arrives before is passed on as it is resumed. With
/// `capture` (`--json`), gh's stdin, stdout and stderr are its files instead of gh-touchid's own.
func runGitHubCLI(
    _ cli: GitHubCLI,
    arguments: [String],
    token: String,
    relay: SignalRelay,
    capture: OutputCapture? = nil
) throws -> Int32 {
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-touchid-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    var environment = ProcessInfo.processInfo.environment
    environment["GH_CONFIG_DIR"] = configDirectory.path
    environment["GH_PAGER"] = "cat"
    environment["GH_TOKEN"] = token
    environment.removeValue(forKey: "GITHUB_TOKEN")
    environment.removeValue(forKey: "GH_ENTERPRISE_TOKEN")

#if GH_TOUCHID_TESTING
    // Test builds only: time to replace the installed gh between the SHA-256 check and the start
    if let delay = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_GH_DELAY"].flatMap(Double.init) {
        Thread.sleep(forTimeInterval: delay)
    }
#endif
    let pid = try spawn(
        cli.executable.path,
        cli.prefix + arguments,
        environment: environment,
        suspended: !cli.cdhashes.isEmpty,
        streams: try capture?.streams()
    )
    if !cli.cdhashes.isEmpty {
        let loaded = loadedCodeDirectoryHash(pid)
        guard let loaded, let architecture = cli.cdhashes[loaded] else {
            kill(pid, SIGKILL)
            _ = waitForExit(pid)
            throw loaded == nil
                ? ToolError.unverifiedGitHubCLI(cli.executable.path)
                : ToolError.changedGitHubCLI(cli.executable.path)
        }
#if GH_TOUCHID_TESTING
        fputs("GH CDHASH: \(architecture) \(loaded)\n", stderr)
#else
        _ = architecture
#endif
        relay.attach(pid)
        kill(pid, SIGCONT)
    } else {
        relay.attach(pid)
    }
    let status = waitForExit(pid)
    relay.detach()
    return status
}

/// The cdhash of the code the kernel loaded for the process `pid` (the slice that runs), as long as its signature is
/// valid; nil when either cannot be read.
private func loadedCodeDirectoryHash(_ pid: pid_t) -> String? {
    var status: UInt32 = 0
    guard csops(pid, csOpsStatus, &status, MemoryLayout<UInt32>.size) == 0, status & csValid != 0 else {
        return nil
    }
    var hash = [UInt8](repeating: 0, count: 20)
    guard csops(pid, csOpsCDHash, &hash, hash.count) == 0 else {
        return nil
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

/// Where a child's streams go when gh-touchid answers in JSON: stdin from the input's text (or gh-touchid's own stdin,
/// or nothing), stdout and stderr into 0600 files in a fresh 0700 folder under the user's temporary folder. Output of
/// at most 1 MiB comes back as text and its file is deleted; larger output stays in its file, which is named instead.
final class OutputCapture {
    private static let inlineLimit = 1 << 20
    private let directory: URL
    private let input: Data?
    private let inheritInput: Bool
    private var descriptors: [Int32] = []

    init(input: Data?, inheritInput: Bool) throws {
        self.input = input
        self.inheritInput = inheritInput
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-touchid-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        descriptors.forEach { close($0) }
    }

    /// The descriptors to put in place of the child's stdin, stdout and stderr.
    func streams() throws -> [Int32] {
        let stdin: Int32
        if let input {
            let path = directory.appendingPathComponent("stdin").path
            stdin = try openFile(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC)
            unlink(path)
            guard input.withUnsafeBytes({ write(stdin, $0.baseAddress, $0.count) }) == input.count,
                  lseek(stdin, 0, SEEK_SET) == 0 else {
                throw ToolError.refused("cannot pass the input's stdin on")
            }
        } else if inheritInput {
            stdin = dup(STDIN_FILENO)
        } else {
            stdin = try openFile("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        descriptors.append(stdin)
        for name in ["stdout", "stderr"] {
            let path = directory.appendingPathComponent(name).path
            descriptors.append(try openFile(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC))
        }
        return Array(descriptors.suffix(3))
    }

    /// `stdout` and `stderr` as text, or `stdout_file` and `stderr_file` naming the files of larger output.
    func result() -> [String: Any] {
        descriptors.forEach { close($0) }
        descriptors = []
        var output: [String: Any] = [:]
        for name in ["stdout", "stderr"] {
            let file = directory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size > Self.inlineLimit {
                output["\(name)_file"] = file.path
            } else {
                output[name] = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
                try? FileManager.default.removeItem(at: file)
            }
        }
        rmdir(directory.path) // fails, leaving it, while a large output's file is in it
        return output
    }

    private func openFile(_ path: String, _ flags: Int32) throws -> Int32 {
        let descriptor = open(path, flags, 0o600)
        guard descriptor >= 0 else {
            throw ToolError.refused("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        return descriptor
    }
}

/// Runs `program` (looked up on PATH) with `arguments` and `environment`, its streams in `capture`'s files, and
/// returns its exit status: `as <login> <command>` with `--json`. Signals to gh-touchid are passed on to it, as to gh,
/// so that a cancelled `rpc` or `mcp` call (SIGTERM to the core) ends the command too rather than leaving it running.
func runCapturedCommand(
    _ program: String,
    arguments: [String],
    environment: [String: String],
    capture: OutputCapture
) throws -> Int32 {
    let relay = SignalRelay()
    defer { relay.remove() }
    let pid = try spawn(
        program,
        arguments,
        environment: environment,
        suspended: false,
        streams: try capture.streams(),
        searchPath: true
    )
    relay.attach(pid)
    let status = waitForExit(pid)
    relay.detach()
    return status
}
