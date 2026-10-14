enum ToolError: Error, CustomStringConvertible {
    case usage
    case authentication(String)
    case authenticationNotAnswered
    case keychain(String)
    case missingRepository
    case missingOwnToken(String)
    case missingApp(String)
    case invalidToken
    case forbiddenCommand
    case missingGitHubCLI(String)
    case unsafeTerminalOutput
    case notGitTransport
    case input(String)
    case agent(String)
    case github(String)
    case refused(String)

    var description: String {
        switch self {
        case .usage:
            return Self.usageText
        case let .authentication(message):
            return "Touch ID failed: \(message)"
        case .authenticationNotAnswered:
            return "Touch ID was not answered"
        case let .keychain(message):
            return "Keychain error: \(message)"
        case .missingRepository:
            return "current Git repository must have an origin on github.com"
        case let .missingOwnToken(owner):
            return "no token of yours is stored for \(owner); run `gh-touchid set --owner \(owner)` first"
        case let .missingApp(owner):
            return "no GitHub App is stored for \(owner); run `gh-touchid app set \(owner) --client-id <id> < key.pem` first"
        case .invalidToken:
            return "the token must contain only printable ASCII and no whitespace"
        case .forbiddenCommand:
            return "this gh command could reveal or replace the token"
        case let .missingGitHubCLI(path):
            return "GitHub CLI is not executable at \(path)"
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

    static let usageText = """
    Usage:
      gh-touchid app set <owner> --client-id <id> < private-key.pem
      gh-touchid set [--owner <owner>]
      gh-touchid gh <arguments...>
      gh-touchid git-credential <get|store|erase>
      gh-touchid me <command> [arguments...]
      gh-touchid session [--repo <owner/name>]...
      gh-touchid elevate --for <duration> [--repo <owner/name>]...
      gh-touchid status
      gh-touchid lock

    `app set` stores the owner's GitHub App (its client ID and PKCS#1 private key, read from stdin) after
    Touch ID and checks it with GitHub. `gh` and Git then act as that App with a short-lived token limited
    to one repository and without the workflows permission.
    `set` stores your own GitHub token for an owner (the current repository's by default) from hidden input
    or stdin; `me` runs a command with it: `me gh ...` directly, anything else with GH_TOUCHID_AS=me.
    `gh` runs GitHub CLI with a token; `git-credential` is Git's HTTPS credential helper.
    Each use asks for Touch ID, except inside a session: `session` registers the process that ran it; the
    first use of a listed repository from that process or its children asks once, then the rest of its
    life needs no Touch ID. Without --repo, `session` and `elevate` take the current repository.
    `elevate` lets tokens for the repositories include workflows for a while (30m, 8h, 1h30m, at most 1d).
    `status` lists sessions and elevations; `lock` ends them all now.
    Every use is logged to ~/Library/Logs/gh-touchid/access.log.
    """
}
