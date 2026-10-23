import Darwin
import Foundation

// Your own GitHub accounts: `account add <login>` stores a token of the account (GitHub must confirm the login),
// `account remove <login>` deletes it, and `as <login> [--] …` uses it, with Touch ID on every use.

/// `account add <login>` or `account remove <login>`.
func accountCommand(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 2, ["add", "remove"].contains(arguments[0]) else {
        throw ToolError.usage
    }
    guard let login = validOwner(arguments[1]) else {
        throw ToolError.input("account \(arguments[0]) takes the login of one of your GitHub accounts")
    }
    if arguments[0] == "remove" {
        guard try removeUserToken(login: login) else {
            throw ToolError.missingAccount(login)
        }
        fputs("Removed the token of \(login).\n", stderr)
        return 0
    }

    let token = try readToken()
    let owner = try tokenOwner(token)
    guard owner.login.lowercased() == login else {
        throw ToolError.refused(
            "this token belongs to \(printable(owner.login)), not \(login); nothing was stored"
        )
    }
    let scopes = owner.scopes.map { printable($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "none listed"
    fputs("GitHub confirms the token belongs to \(login); scopes: \(scopes).\n", stderr)
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
    return 0
}

/// `as <login> [--] gh …` runs gh with that account's token; `as <login> [--] <command> …` runs the command with
/// GH_TOUCHID_AS=<login>. The `--` is optional, as POSIX has it: it only marks where the command starts.
func runAs(_ arguments: [String]) throws -> Int32 {
    guard let first = arguments.first else {
        throw ToolError.usage
    }
    let command = Array(dropSeparator(arguments.dropFirst()))
    guard !command.isEmpty else {
        throw ToolError.usage
    }
    guard let login = validOwner(first) else {
        throw ToolError.input("as takes the login of one of your GitHub accounts")
    }
    guard hasUserToken(login: login) else {
        throw ToolError.missingAccount(login)
    }
    let program = command[0]
    if program == "gh" {
        return try runGitHub(Array(command.dropFirst()), account: login)
    }
    setenv("GH_TOUCHID_AS", login, 1)
    fflush(stdout)
    var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    execvp(program, &argv)
    let reason = String(cString: strerror(errno))
    argv.forEach { free($0) }
    throw ToolError.input("cannot run \(program): \(reason)")
}

/// The command after the login, without the one `--` that may lead it.
private func dropSeparator(_ rest: ArraySlice<String>) -> ArraySlice<String> {
    rest.first == "--" ? rest.dropFirst() : rest
}
