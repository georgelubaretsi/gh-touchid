enum ToolError: Error, CustomStringConvertible {
    /// A wrong use: `commandUsage` when it is one command's.
    case usage
    case commandUsage(String)
    case authentication(String)
    case authenticationNotAnswered
    case screenLocked
    case keychain(String)
    case missingRepository
    case missingAccount(String)
    case missingApp(String)
    case newerFormat(item: String, format: Int)
    case notSignedIn(String)
    case noApp(owner: String, logins: [String], program: String)
    case invalidToken
    case forbiddenCommand
    case missingGitHubCLI(String)
    case changedGitHubCLI(String)
    case unverifiedGitHubCLI(String)
    case unsafeTerminalOutput
    case notGitTransport
    case input(String)
    case agent(String)
    case github(String)
    case refused(String)

    var description: String {
        switch self {
        case .usage:
            return Usage.all
        case let .commandUsage(command):
            return Usage.of(command) ?? Usage.all
        case let .authentication(message):
            return "Touch ID failed: \(message)"
        case .authenticationNotAnswered:
            return "Touch ID was not answered"
        case .screenLocked:
            return "the screen is locked, so nobody could approve this; unlock it and run the command again"
        case let .keychain(message):
            return "Keychain error: \(message)"
        case .missingRepository:
            return "current Git repository must have an origin on github.com"
        case let .missingAccount(login):
            return "no token is stored for the account \(login); run `gh-touchid account add \(login)` first"
        case let .missingApp(owner):
            return "no GitHub App is stored for \(owner); run `gh-touchid app create \(owner)` first"
        case let .newerFormat(item, format):
            return "the \(item) was stored by a newer gh-touchid, in format \(format) (this one reads up to "
                + "format \(itemFormat)); upgrade gh-touchid"
        case let .notSignedIn(owner):
            return "you are not signed in to the GitHub App for \(owner), or the sign-in has ended; "
                + "run `gh-touchid app login \(owner)`"
        case let .noApp(owner, logins, program):
            let accounts = logins.isEmpty
                ? "none stored yet; add one with `gh-touchid account add <login>`"
                : "stored: \(logins.joined(separator: ", "))"
            return "no GitHub App is stored for \(owner); to act as one of your accounts: "
                + "gh-touchid as <login> -- \(program) … (\(accounts))"
        case .invalidToken:
            return "the token must contain only printable ASCII and no whitespace"
        case .forbiddenCommand:
            return "this gh command could reveal or replace the token"
        case let .missingGitHubCLI(path):
            return "GitHub CLI is not executable at \(path)"
        case let .changedGitHubCLI(path):
            return "the gh next to gh-touchid was changed; reinstall gh-touchid "
                + "(\(path) is not the gh it was built with)"
        case let .unverifiedGitHubCLI(path):
            return "cannot tell which code the gh at \(path) started with; it was stopped before it ran"
        case .unsafeTerminalOutput:
            return "refusing to emit a Git credential to a terminal"
        case .notGitTransport:
            return "only Git's own HTTPS transport (git-remote-https) gets a credential"
        case let .input(message):
            return "input error: \(message)"
        case let .agent(message):
            return "agent error: \(message)"
        case let .github(message):
            return message
        case let .refused(message):
            return message
        }
    }
}
