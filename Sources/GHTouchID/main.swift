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
        }
    }

    static let usageText = """
    Usage:
      gh-touchid set
      gh-touchid gh <arguments...>
      gh-touchid git-credential <get|store|erase>

    `set` reads a GitHub token from hidden input or stdin.
    `gh` runs GitHub CLI with the stored token after Touch ID.
    `git-credential` implements Git's HTTPS credential-helper protocol.
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

    var repository = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if repository.hasSuffix(".git") {
        repository.removeLast(4)
    }

    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard components.count == 2,
          components.allSatisfy({ !$0.isEmpty }),
          components.joined().unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        throw ToolError.missingRepository
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
    try authenticate(reason: reason)
    let token = try loadToken(repository: repository)
    return try body(token)
}

private func discardStandardInput() {
    _ = FileHandle.standardInput.readDataToEndOfFile()
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
