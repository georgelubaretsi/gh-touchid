enum ToolError: Error, CustomStringConvertible {
    case usage
    case authentication(String)
    case authenticationNotAnswered
    case keychain(String)
    case missingRepository
    case missingAccount(String)
    case missingApp(String)
    case noApp(owner: String, logins: [String], program: String)
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
        case let .missingAccount(login):
            return "no token is stored for the account \(login); run `gh-touchid user add \(login)` first"
        case let .missingApp(owner):
            return "no GitHub App is stored for \(owner); run `gh-touchid app create \(owner)` first"
        case let .noApp(owner, logins, program):
            let accounts = logins.isEmpty
                ? "none stored yet; add one with `gh-touchid user add <login>`"
                : "stored: \(logins.joined(separator: ", "))"
            return "no GitHub App is stored for \(owner); to act as one of your accounts: "
                + "gh-touchid as <login> \(program) … (\(accounts))"
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
      gh-touchid app create <owner> [--name <name>] [--no-open]
      gh-touchid app set <owner> --client-id <id> < private-key.pem
      gh-touchid user add <login>
      gh-touchid user remove <login>
      gh-touchid gh <arguments...>
      gh-touchid git-credential <get|store|erase>
      gh-touchid as <login> <command> [arguments...]
      gh-touchid session [--repo <owner/name>]...
      gh-touchid elevate --for <duration> [--repo <owner/name>]...
      gh-touchid status
      gh-touchid lock
      gh-touchid version

    `app create` makes a GitHub App for an owner from a manifest in your browser (--no-open prints the URL
    instead) and stores it; `app set` stores one made by hand (client ID, PKCS#1 private key on stdin). Both
    ask for Touch ID and check the key with GitHub. `gh` and Git then act as the owner's App with a
    short-lived token limited to one repository and without the workflows permission; for an owner without
    an App they refuse before asking for Touch ID.
    `user add` stores a token of one of your GitHub accounts (hidden input or stdin) once GitHub confirms
    its login; `user remove` deletes it. `as` runs a command as that account, with Touch ID on every use:
    `as <login> gh ...` directly, anything else with GH_TOUCHID_AS=<login>, which gh and Git honour.
    `gh` runs GitHub CLI with a token; `git-credential` is Git's HTTPS credential helper.
    Each use asks for Touch ID, except inside a session: `session` registers the program that ran it
    (looking past shells that only run a command or a script); its first GitHub use asks once, then it and
    everything it starts get tokens for its repositories without Touch ID until it exits, and issue-only
    tokens for other repositories your Apps are installed on (public ones ask per use). Without --repo,
    `session` takes the outermost Git repository here and those nested up to two levels below it whose
    owner has an App, and `elevate` takes the current repository.
    `elevate` lets tokens for the repositories include workflows for a while (30m, 8h, 1h30m, at most 1d).
    `status` lists stored Apps and accounts, sessions and elevations; `lock` ends sessions and elevations.
    `version` prints gh-touchid's version.
    Every use is logged to ~/Library/Logs/gh-touchid/access.log.
    """
}
