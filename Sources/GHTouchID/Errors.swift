enum ToolError: Error, CustomStringConvertible {
    case usage
    case authentication(String)
    case authenticationNotAnswered
    case screenLocked
    case keychain(String)
    case missingRepository
    case missingAccount(String)
    case missingApp(String)
    case legacyApp(owner: String, slug: String?)
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
            return Self.usageText
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
            return "no token is stored for the account \(login); run `gh-touchid user add \(login)` first"
        case let .missingApp(owner):
            return "no GitHub App is stored for \(owner); run `gh-touchid app create \(owner)` first"
        case let .legacyApp(owner, slug):
            let old = slug.map { "the old App \($0) (delete it in its settings on GitHub, under Advanced)" }
                ?? "the old App"
            return "the App stored for \(owner) comes from gh-touchid 0.3 or earlier, which acted as the App's bot; "
                + "run `gh-touchid app create \(owner)` to make one that acts as you, then remove \(old)"
        case let .notSignedIn(owner):
            return "you are not signed in to the GitHub App for \(owner), or the sign-in has ended; "
                + "run `gh-touchid app login \(owner)`"
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

    static let usageText = """
    Usage:
      gh-touchid app create <owner> [--name <name>] [--no-open]
      gh-touchid app set <owner> --client-id <id> [--no-open] < client-secret
      gh-touchid app login <owner> [--no-open]
      gh-touchid user add <login>
      gh-touchid user remove <login>
      gh-touchid gh <arguments...>
      gh-touchid git-setup <owner>
      gh-touchid git-credential <get|store|erase>
      gh-touchid as <login> <command> [arguments...]
      gh-touchid session [--repo <owner/name>]...
      gh-touchid elevate --for <duration> [--repo <owner/name>]...
      gh-touchid status
      gh-touchid lock
      gh-touchid version

    `app create` makes a GitHub App for an owner from a manifest in your browser, signs you in to it and opens
    its installation page (--no-open prints the URLs instead); `app set` takes an App made by hand (client ID,
    client secret on stdin or hidden input; it must list the callback URL http://127.0.0.1:47911/callback) and
    signs you in; `app login` signs you in again. Each asks for Touch ID before storing anything. `gh` and Git
    then act as you, through the owner's App, with a token limited to one repository and without the
    workflows permission; for an owner without an App they refuse before asking for Touch ID.
    `user add` stores a token of one of your GitHub accounts (hidden input or stdin) once GitHub confirms
    its login; `user remove` deletes it. `as` runs a command as that account, with Touch ID on every use:
    `as <login> gh ...` directly, anything else with GH_TOUCHID_AS=<login>, which gh and Git honour.
    `gh` runs GitHub CLI with a token; `git-credential` is Git's HTTPS credential helper, and `git-setup`
    makes it the only one Git asks for the owner's repositories (in your global Git configuration; write
    the owner as in your remotes' URLs).
    Each use asks for Touch ID, except inside a session: `session` registers the program that ran it
    (looking past shells that only run a command or a script); its first GitHub use asks once, then it and
    everything it starts get tokens for its repositories without Touch ID until it exits, and issue-only
    tokens for other repositories your Apps are installed on (public ones ask per use). Without --repo,
    `session` takes the outermost Git repository here and those nested up to two levels below it whose
    owner has an App, and `elevate` takes the current repository.
    `elevate` lets tokens for the repositories include workflows for a while (30m, 8h, 1h30m, at most 1d).
    `status` lists stored Apps and accounts, whether Git (per owner) goes through this gh-touchid, which `gh`
    is first on PATH (with how to put this gh-touchid's first) and whether another gh is signed in, sessions
    and elevations; `lock` ends sessions and elevations.
    `version` prints gh-touchid's version.
    Every use is logged to ~/Library/Logs/gh-touchid/access.log.
    """
}
