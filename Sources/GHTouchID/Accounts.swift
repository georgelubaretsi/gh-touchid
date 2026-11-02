import Darwin
import Foundation

// Your own GitHub accounts: `account add <login>` stores a token of the account (GitHub must confirm the login),
// `account remove <login>` deletes it, and `as <login> [--] …` uses it, with Touch ID on every use.

/// `account add`: stores `token` for `login` once GitHub confirms the login, after Touch ID; the scopes GitHub lists
/// for it, nil when it lists none.
func addAccount(login: String, token: String) throws -> String? {
    let token = try normalizeToken(token)
    let owner = try tokenOwner(token)
    guard owner.login.lowercased() == login else {
        throw ToolError.refused(
            "this token belongs to \(printable(owner.login)), not \(login); nothing was stored"
        )
    }
    let scopes = owner.scopes.map { printable($0) }.flatMap { $0.isEmpty ? nil : $0 }
    fputs("GitHub confirms the token belongs to \(login); scopes: \(scopes ?? "none listed").\n", stderr)
    if token.hasPrefix("github_pat_") {
        fputs(
            "Warning: this is a fine-grained token; it cannot contribute to public repositories "
                + "\(login) is not a member of. A classic token can.\n",
            stderr
        )
    }
    try authenticate(.accountToken(login))
    try storeUserToken(token, login: login)
    fputs("Stored the token of \(login).\n", stderr)
    return scopes
}

/// `account remove`: deletes the token of `login`.
func removeAccount(login: String) throws {
    guard try removeUserToken(login: login) else {
        throw ToolError.missingAccount(login)
    }
    fputs("Removed the token of \(login).\n", stderr)
}

/// `as <login> [--] gh …` runs gh with that account's token; `as <login> [--] <command> …` runs the command with
/// GH_TOUCHID_AS=<login>, replacing gh-touchid, or with `capture` (`--json`) as a child whose output is captured.
func runAs(login: String, command: [String], capture: OutputCapture?) throws -> Int32 {
    guard hasUserToken(login: login) else {
        throw ToolError.missingAccount(login)
    }
    let program = command[0]
    if program == "gh" {
        return try runGitHub(Array(command.dropFirst()), account: login, capture: capture)
    }
    setenv("GH_TOUCHID_AS", login, 1)
    if let capture {
        return try runCapturedCommand(
            program,
            arguments: Array(command.dropFirst()),
            environment: ProcessInfo.processInfo.environment,
            capture: capture
        )
    }
    fflush(stdout)
    let reason = try replaceProcess(with: program, arguments: Array(command.dropFirst()), searchPath: true)
    throw ToolError.input("cannot run \(program): \(reason)")
}

/// The login and command of `as <login> [--] <command>...`, without the one `--` that may lead the command, as POSIX
/// has it: it only marks where the command starts.
func asArguments(_ arguments: [String]) throws -> (login: String, command: [String]) {
    guard let first = arguments.first else {
        throw ToolError.usage
    }
    let rest = arguments.dropFirst()
    let command = Array(rest.first == "--" ? rest.dropFirst() : rest)
    guard !command.isEmpty else {
        throw ToolError.usage
    }
    return (first, command)
}
