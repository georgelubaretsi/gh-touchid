import Darwin
import Foundation
import LocalAuthentication
import Security

private let keychainService = "com.lubaretsi.gh-touchid"


private enum ToolError: Error, CustomStringConvertible {
    case usage
    case authentication(String)
    case keychain(String)
    case missingRepository
    case missingToken(String)
    case invalidToken
    case forbiddenCommand
    case missingGitHubCLI(String)
    case unsafeTerminalOutput
    case input(String)
    case session(String)

    var description: String {
        switch self {
        case .usage:
            return Self.usageText
        case let .authentication(message):
            return "Touch ID failed: \(message)"
        case let .keychain(message):
            return "Keychain error: \(message)"
        case .missingRepository:
            return "current Git repository must have an origin on github.com"
        case let .missingToken(repository):
            return "no token is stored for \(repository); run `gh-touchid set` first"
        case .invalidToken:
            return "the token must contain only printable ASCII and no whitespace"
        case .forbiddenCommand:
            return "this authentication command could expose or replace the stored token"
        case let .missingGitHubCLI(path):
            return "GitHub CLI is not executable at \(path)"
        case .unsafeTerminalOutput:
            return "refusing to emit a Git credential to a terminal"
        case let .input(message):
            return "input error: \(message)"
        case let .session(message):
            return "unlock error: \(message)"
        }
    }

    static let usageText = """
    Usage:
      gh-touchid set
      gh-touchid gh <arguments...>
      gh-touchid git-credential <get|store|erase>
      gh-touchid unlock --for <duration> [--repo <owner/name>]... [--all] [--until-screen-lock]
      gh-touchid status
      gh-touchid lock

    `set` reads a GitHub token from hidden input or stdin.
    `gh` runs GitHub CLI with the stored token after Touch ID.
    `git-credential` implements Git's HTTPS credential-helper protocol.
    `unlock` asks for Touch ID once, then lets `gh` and Git use the named repositories' tokens
    without asking again until the time runs out (30m, 8h, 1h30m, at most 1d). Without --repo it
    unlocks the current repository; --all unlocks every stored one.
    `status` lists what is unlocked and until when; `lock` ends every unlock now.
    Each use during an unlock is logged to ~/Library/Logs/gh-touchid/access.log.
    """
}

private final class AuthenticationResult: @unchecked Sendable {
    var success = false
    var error: Error?
}

private func authenticate(reason: String) throws {
    let context = LAContext()
    context.localizedFallbackTitle = ""
    context.touchIDAuthenticationAllowableReuseDuration = 0

    var availabilityError: NSError?
    guard context.canEvaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        error: &availabilityError
    ) else {
        throw ToolError.authentication(
            availabilityError?.localizedDescription ?? "biometrics are unavailable"
        )
    }

    let result = AuthenticationResult()
    let semaphore = DispatchSemaphore(value: 0)

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
    ) { success, error in
        result.success = success
        result.error = error
        semaphore.signal()
    }

    semaphore.wait()
    guard result.success else {
        throw ToolError.authentication(
            result.error?.localizedDescription ?? "authentication was denied"
        )
    }
}

private func keychainError(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
        return "\(message) (\(status))"
    }
    return "OSStatus \(status)"
}

private func repositoryIdentifier() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "remote", "get-url", "origin"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        throw ToolError.missingRepository
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0,
          let raw = String(data: data, encoding: .utf8) else {
        throw ToolError.missingRepository
    }

    let remote = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let path: String
    if remote.hasPrefix("git@github.com:") {
        path = String(remote.dropFirst("git@github.com:".count))
    } else if let url = URL(string: remote),
              url.host?.lowercased() == "github.com" {
        path = url.path
    } else {
        throw ToolError.missingRepository
    }

    guard let repository = validRepository(path) else {
        throw ToolError.missingRepository
    }
    return repository
}

/// `owner/name` with a trailing `.git` and surrounding slashes removed, or nil when it is not one.
private func validRepository(_ raw: String) -> String? {
    var repository = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if repository.hasSuffix(".git") {
        repository.removeLast(4)
    }

    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard components.count == 2,
          components.allSatisfy({ !$0.isEmpty }),
          components.joined().unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return nil
    }
    return repository
}

private func commandSummary(_ arguments: [String]) -> String {
    let summary = arguments
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    return String(summary.prefix(180))
}

private func isForbiddenGitHubCommand(_ arguments: [String]) -> Bool {
    if arguments.contains("--show-token") {
        return true
    }
    if let command = arguments.first, ["alias", "extension"].contains(command) {
        return true
    }
    guard arguments.count >= 2, arguments[0] == "auth" else {
        return false
    }
    return [
        "login",
        "logout",
        "refresh",
        "setup-git",
        "switch",
        "token",
    ].contains(arguments[1])
}

private func normalizeToken(_ raw: String) throws -> String {
    var token = raw
    while token.last == "\n" || token.last == "\r" {
        token.removeLast()
    }

    let pasteStart = "\u{1B}[200~"
    let pasteEnd = "\u{1B}[201~"
    if token.hasPrefix(pasteStart), token.hasSuffix(pasteEnd) {
        token.removeFirst(pasteStart.count)
        token.removeLast(pasteEnd.count)
    }

    guard !token.isEmpty,
          token.unicodeScalars.allSatisfy({ (0x21 ... 0x7E).contains($0.value) }) else {
        throw ToolError.invalidToken
    }
    return token
}

private func storeToken(_ token: String, repository: String) throws {
    guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
        throw ToolError.invalidToken
    }

    guard let data = token.data(using: .utf8) else {
        throw ToolError.invalidToken
    }

    let lookup: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: repository,
    ]

    let update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrLabel as String: "gh-touchid \(repository)",
    ]

    let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw ToolError.keychain(keychainError(updateStatus))
    }

    var add = lookup
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "gh-touchid \(repository)"
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    add[kSecAttrSynchronizable as String] = false

    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw ToolError.keychain(keychainError(addStatus))
    }
}

private func loadToken(repository: String) throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: repository,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        throw ToolError.missingToken(repository)
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(keychainError(status))
    }
    guard let data = item as? Data,
          let token = String(data: data, encoding: .utf8),
          !token.isEmpty else {
        throw ToolError.keychain("stored token is not valid UTF-8")
    }
    return token
}

/// Every repository a token is stored for (attributes only; no token is read).
private func storedRepositories() throws -> [String] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]

    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound {
        return []
    }
    guard status == errSecSuccess, let list = items as? [[String: Any]] else {
        throw ToolError.keychain(keychainError(status))
    }
    return list.compactMap { $0[kSecAttrAccount as String] as? String }.compactMap(validRepository)
}

private func readToken() throws -> String {
    if isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8) else {
            throw ToolError.input("stdin is not valid UTF-8")
        }
        return try normalizeToken(token)
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw ToolError.input("cannot read terminal settings")
    }

    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
        throw ToolError.input("cannot disable terminal echo")
    }

    defer {
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        fputs("\n", stderr)
    }

    fputs("GitHub PAT: ", stderr)
    fflush(stderr)
    guard let token = readLine(strippingNewline: true) else {
        throw ToolError.input("no token was provided")
    }
    return try normalizeToken(token)
}

private func githubCLI() throws -> (URL, [String]) {
    let environment = ProcessInfo.processInfo.environment
    if let configured = environment["GH_TOUCHID_GH"] {
        guard configured.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configured) else {
            throw ToolError.missingGitHubCLI(configured)
        }
        return (URL(fileURLWithPath: configured), [])
    }

    return (URL(fileURLWithPath: "/usr/bin/env"), ["gh"])
}

@discardableResult
private func runGitHubCLI(arguments: [String], token: String) throws -> Int32 {
    let (executable, prefix) = try githubCLI()
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

private func withToken(
    repository: String,
    reason: String,
    _ body: (String) throws -> Int32
) throws -> Int32 {
    // during an unlock (`gh-touchid unlock`) the agent hands the token over without another Touch ID
    if let token = sessionToken(repository: repository) {
        return try body(token)
    }
    try authenticate(reason: reason)
    let token = try loadToken(repository: repository)
    return try body(token)
}

private func discardStandardInput() {
    _ = FileHandle.standardInput.readDataToEndOfFile()
}

// MARK: - Unlocking for a while
//
// `unlock` asks for Touch ID once, reads the named repositories' tokens from the Keychain and hands them to a small
// background agent, which keeps them in memory only and answers on a socket in the user's private temporary directory
// until each one's time runs out. While a repository is unlocked, `gh` and `git-credential get` ask the agent before
// asking for Touch ID. Any process running as the user can obtain an unlocked token; that is what unlocking means. The
// agent logs every request with the process chain that made it, and exits when nothing is left unlocked.

private let longestUnlock: TimeInterval = 24 * 60 * 60

/// `30m`, `8h`, `1h30m`, `1d`: at most one day.
private func parseDuration(_ text: String) throws -> TimeInterval {
    let pattern = #"^(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?$"#
    let range = NSRange(text.startIndex..., in: text)
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: range) else {
        throw ToolError.input("--for takes a duration like 30m, 8h, 1h30m or 1d")
    }
    func part(_ index: Int) -> Double {
        guard let range = Range(match.range(at: index), in: text) else {
            return 0
        }
        return Double(text[range]) ?? 0
    }
    let seconds = part(1) * 86400 + part(2) * 3600 + part(3) * 60
    guard seconds > 0 else {
        throw ToolError.input("--for takes a duration like 30m, 8h, 1h30m or 1d")
    }
    guard seconds <= longestUnlock else {
        throw ToolError.input("the longest unlock is 1d")
    }
    return seconds
}

private func durationText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let parts = [(minutes / 1440, "d"), (minutes % 1440 / 60, "h"), (minutes % 60, "m")]
    return parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined()
}

private func localTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func repositoryList(_ repositories: [String]) -> String {
    let shown = repositories.prefix(3).joined(separator: ", ")
    return repositories.count > 3 ? "\(shown) and \(repositories.count - 3) more" : shown
}

/// The user's own temporary directory from the system, not $TMPDIR, which development shells change.
private let sessionDirectory: String = {
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let base = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    return (base as NSString).appendingPathComponent("gh-touchid")
}()

private let sessionSocketPath = (sessionDirectory as NSString).appendingPathComponent("agent.sock")

private let accessLogPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/gh-touchid/access.log")

private func ensureSessionDirectory() throws {
    if mkdir(sessionDirectory, 0o700) != 0 && errno != EEXIST {
        throw ToolError.session("cannot create \(sessionDirectory)")
    }
    var status = stat()
    guard lstat(sessionDirectory, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(),
          status.st_mode & 0o077 == 0 else {
        throw ToolError.session("\(sessionDirectory) must be a private directory owned by you")
    }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw ToolError.session("socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in bytes.enumerated() {
            raw[index] = byte
        }
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

private func withSocketAddress<T>(
    _ address: inout sockaddr_un,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func configureSocket(_ fd: Int32, timeoutSeconds: Int) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else {
            return true
        }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base + offset, raw.count - offset)
            if written <= 0 {
                return false
            }
            offset += written
        }
        return true
    }
}

/// One newline-terminated message, at most 64 KiB.
private func readMessage(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 65536 {
        let count = read(fd, &byte, 1)
        if count <= 0 {
            return nil
        }
        if byte == 0x0A {
            return data
        }
        data.append(byte)
    }
    return nil
}

private func sendMessage(_ fd: Int32, _ message: [String: Any]) -> Bool {
    guard let body = try? JSONSerialization.data(withJSONObject: message) else {
        return false
    }
    return writeAll(fd, body + Data([0x0A]))
}

/// Ask the running agent; nil when no agent answers as this user.
private func agentRequest(_ request: [String: Any]) -> [String: Any]? {
    guard var address = try? socketAddress(sessionSocketPath) else {
        return nil
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return nil
    }
    defer { close(fd) }
    configureSocket(fd, timeoutSeconds: 5)
    guard withSocketAddress(&address, { connect(fd, $0, $1) }) == 0 else {
        return nil
    }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
          sendMessage(fd, request),
          let line = readMessage(fd),
          let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        return nil
    }
    return reply
}

private func sessionToken(repository: String) -> String? {
    guard let reply = agentRequest(["op": "get", "repo": repository]),
          let token = reply["token"] as? String,
          !token.isEmpty else {
        return nil
    }
    return token
}

private func appendAccessLog(_ message: String) {
    let directory = (accessLogPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let stamp = ISO8601DateFormatter.string(
        from: Date(),
        timeZone: .current,
        formatOptions: [.withInternetDateTime]
    )
    let fd = open(accessLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else {
        return
    }
    defer { close(fd) }
    _ = writeAll(fd, Data("\(stamp) \(message)\n".utf8))
}

private func processPath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : "?"
}

private func parentProcess(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        return nil
    }
    return pid_t(info.pbi_ppid)
}

/// `gh-touchid[812] < git[810] < zsh[790] < bun[700]`: who asked, and who started it.
private func processChain(_ pid: pid_t) -> String {
    var parts: [String] = []
    var current: pid_t? = pid
    while let process = current, process > 1, parts.count < 6 {
        parts.append("\((processPath(process) as NSString).lastPathComponent)[\(process)]")
        current = parentProcess(process)
    }
    return parts.isEmpty ? "unknown process" : parts.joined(separator: " < ")
}

/// The peer of a local socket (`LOCAL_PEERPID` at level `SOL_LOCAL`, from sys/un.h).
private func peerProcess(_ fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, 0, 0x002, &pid, &length) == 0 else {
        return nil
    }
    return pid
}

private final class UnlockAgent: @unchecked Sendable {
    private struct Grant {
        let token: String
        let expires: Date
        let untilScreenLock: Bool
    }

    private var grants: [String: Grant] = [:]
    private var sources: [DispatchSourceProtocol] = []
    private let listener: Int32
    private let started = Date()

    init(listener: Int32) {
        self.listener = listener
    }

    func start() {
        let accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        accepting.setEventHandler { [self] in
            let client = accept(listener, nil, nil)
            if client >= 0 {
                handle(client)
                close(client)
            }
        }
        accepting.resume()

        let ticking = DispatchSource.makeTimerSource(queue: .main)
        ticking.schedule(deadline: .now() + 1, repeating: 1)
        ticking.setEventHandler { [self] in expire() }
        ticking.resume()

        signal(SIGHUP, SIG_IGN)
        sources = [accepting, ticking]
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let stopping = DispatchSource.makeSignalSource(signal: number, queue: .main)
            stopping.setEventHandler { [self] in finish("stopped by signal \(number)") }
            stopping.resume()
            sources.append(stopping)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [self] _ in screenLocked() }
    }

    private func handle(_ client: Int32) {
        configureSocket(client, timeoutSeconds: 2)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            return
        }
        let who = peerProcess(client).map(processChain) ?? "unknown process"
        guard let line = readMessage(client),
              let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let operation = request["op"] as? String else {
            _ = sendMessage(client, ["error": "bad request"])
            return
        }

        switch operation {
        case "get":
            let repository = request["repo"] as? String ?? ""
            if let grant = grants[repository], grant.expires > Date() {
                _ = sendMessage(client, ["token": grant.token])
                appendAccessLog("granted \(repository) to \(who)")
            } else {
                _ = sendMessage(client, ["error": "not unlocked"])
                appendAccessLog("refused \(repository) to \(who): not unlocked")
            }

        case "add":
            let entries = request["entries"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let repository = entry["repo"] as? String, validRepository(repository) == repository,
                      let token = entry["token"] as? String, !token.isEmpty,
                      let seconds = entry["seconds"] as? Double, seconds > 0, seconds <= longestUnlock else {
                    continue
                }
                let untilScreenLock = entry["untilScreenLock"] as? Bool ?? false
                let expires = Date().addingTimeInterval(seconds)
                grants[repository] = Grant(token: token, expires: expires, untilScreenLock: untilScreenLock)
                let lockNote = untilScreenLock ? " or screen lock" : ""
                appendAccessLog("unlocked \(repository) until \(localTime(expires))\(lockNote) by \(who)")
            }
            _ = sendMessage(client, ["ok": true])

        case "status":
            let entries = grants.map { repository, grant -> [String: Any] in
                [
                    "repo": repository,
                    "expires": grant.expires.timeIntervalSince1970,
                    "untilScreenLock": grant.untilScreenLock,
                ]
            }
            _ = sendMessage(client, ["entries": entries])

        case "lock":
            _ = sendMessage(client, ["ok": true])
            finish("locked by \(who)")

        default:
            _ = sendMessage(client, ["error": "unknown request"])
        }
    }

    private func expire() {
        let now = Date()
        for (repository, grant) in grants where grant.expires <= now {
            grants.removeValue(forKey: repository)
            appendAccessLog("expired \(repository)")
        }
        // a fresh agent waits a little for the unlock that started it
        if grants.isEmpty && now.timeIntervalSince(started) > 30 {
            finish("nothing left unlocked")
        }
    }

    private func screenLocked() {
        for (repository, grant) in grants where grant.untilScreenLock {
            grants.removeValue(forKey: repository)
            appendAccessLog("locked \(repository): the screen locked")
        }
        if grants.isEmpty {
            finish("the screen locked")
        }
    }

    private func finish(_ reason: String) -> Never {
        appendAccessLog("agent stopped: \(reason)")
        unlink(sessionSocketPath)
        exit(0)
    }
}

private func runAgent() throws -> Never {
    try ensureSessionDirectory()
    if agentRequest(["op": "status"]) != nil {
        exit(0) // another agent is already serving
    }
    unlink(sessionSocketPath)
    var address = try socketAddress(sessionSocketPath)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else {
        throw ToolError.session("cannot create a socket")
    }
    let previous = umask(0o077)
    let bound = withSocketAddress(&address) { bind(listener, $0, $1) }
    umask(previous)
    guard bound == 0, listen(listener, 16) == 0 else {
        throw ToolError.session("cannot listen on \(sessionSocketPath)")
    }

    let agent = UnlockAgent(listener: listener)
    agent.start()
    appendAccessLog("agent started")
    // keeps the main run loop alive for the screen-lock notification; work arrives on the main queue
    let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
    RunLoop.main.add(keepAlive, forMode: .default)
    while true {
        RunLoop.main.run(until: .distantFuture)
    }
}

/// Start the agent as its own session, detached from the terminal, with no inherited input, output or environment.
private func spawnAgent() throws {
    guard let executable = Bundle.main.executablePath else {
        throw ToolError.session("cannot find gh-touchid's own executable")
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("agent"), nil]
    defer { argv.forEach { free($0) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment)
    guard status == 0 else {
        throw ToolError.session("cannot start the agent: \(String(cString: strerror(status)))")
    }
}

private func ensureAgent() throws {
    if agentRequest(["op": "status"]) != nil {
        return
    }
    try ensureSessionDirectory()
    try spawnAgent()
    for _ in 0 ..< 50 {
        if agentRequest(["op": "status"]) != nil {
            return
        }
        usleep(100_000)
    }
    throw ToolError.session("the agent did not start")
}

private func unlock(_ arguments: [String]) throws -> Int32 {
    var duration: TimeInterval?
    var repositories: [String] = []
    var all = false
    var untilScreenLock = false
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--for":
            guard index + 1 < arguments.count else {
                throw ToolError.usage
            }
            duration = try parseDuration(arguments[index + 1])
            index += 2
        case "--repo":
            guard index + 1 < arguments.count, let repository = validRepository(arguments[index + 1]) else {
                throw ToolError.input("--repo takes owner/name")
            }
            repositories.append(repository)
            index += 2
        case "--all":
            all = true
            index += 1
        case "--until-screen-lock":
            untilScreenLock = true
            index += 1
        default:
            throw ToolError.usage
        }
    }
    guard let seconds = duration else {
        throw ToolError.input("unlock needs --for, for example --for 8h (at most 1d)")
    }
    if all {
        repositories += try storedRepositories()
    }
    if repositories.isEmpty {
        repositories = [try repositoryIdentifier()]
    }
    repositories = Array(Set(repositories)).sorted()

    try authenticate(reason: "Unlock GitHub access for \(repositoryList(repositories)) for \(durationText(seconds))")
    let entries: [[String: Any]] = try repositories.map { repository in
        [
            "repo": repository,
            "token": try loadToken(repository: repository),
            "seconds": seconds,
            "untilScreenLock": untilScreenLock,
        ]
    }
    try ensureAgent()
    guard let reply = agentRequest(["op": "add", "entries": entries]), reply["ok"] as? Bool == true else {
        throw ToolError.session("the agent did not accept the unlock")
    }
    let lockNote = untilScreenLock ? " or until the screen locks" : ""
    let until = localTime(Date().addingTimeInterval(seconds))
    fputs("Unlocked \(repositories.joined(separator: ", ")) until \(until)\(lockNote).\n", stderr)
    return 0
}

private func status() -> Int32 {
    guard let reply = agentRequest(["op": "status"]),
          let entries = reply["entries"] as? [[String: Any]],
          !entries.isEmpty else {
        print("Nothing is unlocked.")
        return 0
    }
    for entry in entries.sorted(by: { ($0["repo"] as? String ?? "") < ($1["repo"] as? String ?? "") }) {
        let repository = entry["repo"] as? String ?? "?"
        let expires = Date(timeIntervalSince1970: entry["expires"] as? Double ?? 0)
        let lockNote = entry["untilScreenLock"] as? Bool == true ? " or screen lock" : ""
        print("\(repository)  until \(localTime(expires))\(lockNote)")
    }
    return 0
}

private func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw ToolError.usage
    }

    switch command {
    case "help", "--help", "-h":
        print(ToolError.usageText)
        return 0

    case "set":
        guard arguments.count == 1 else {
            throw ToolError.usage
        }
        let repository = try repositoryIdentifier()
        try authenticate(reason: "Store GitHub token for \(repository)")
        let token = try readToken()
        try storeToken(token, repository: repository)
        fputs("Stored GitHub token for \(repository) in macOS Keychain.\n", stderr)
        return 0

    case "gh":
        let repository = try repositoryIdentifier()
        let ghArguments = Array(arguments.dropFirst())
        guard !isForbiddenGitHubCommand(ghArguments) else {
            throw ToolError.forbiddenCommand
        }
        let summary = commandSummary(["gh"] + ghArguments)
        return try withToken(
            repository: repository,
            reason: "Run \(summary) for \(repository)"
        ) { token in
            try runGitHubCLI(arguments: ghArguments, token: token)
        }

    case "git-credential":
        guard arguments.count == 2 else {
            throw ToolError.usage
        }
        let repository = try repositoryIdentifier()
        let operation = arguments[1]
        switch operation {
        case "get":
            guard isatty(STDOUT_FILENO) == 0 else {
                throw ToolError.unsafeTerminalOutput
            }
            return try withToken(
                repository: repository,
                reason: "Authenticate Git for \(repository)"
            ) { token in
                try runGitHubCLI(
                    arguments: ["auth", "git-credential", "get"],
                    token: token
                )
            }
        case "store", "erase":
            discardStandardInput()
            return 0
        default:
            throw ToolError.usage
        }

    case "unlock":
        return try unlock(Array(arguments.dropFirst()))

    case "status":
        guard arguments.count == 1 else {
            throw ToolError.usage
        }
        return status()

    case "lock":
        guard arguments.count == 1 else {
            throw ToolError.usage
        }
        print(agentRequest(["op": "lock"]) == nil ? "Nothing was unlocked." : "Locked: nothing is unlocked.")
        return 0

    case "agent":
        guard arguments.count == 1 else {
            throw ToolError.usage
        }
        try runAgent()

    default:
        throw ToolError.usage
    }
}

do {
    let status = try run()
    exit(status)
} catch ToolError.usage {
    fputs("\(ToolError.usageText)\n", stderr)
    exit(2)
} catch {
    fputs("gh-touchid: \(error)\n", stderr)
    exit(1)
}
