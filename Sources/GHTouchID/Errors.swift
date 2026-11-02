// Every failure gh-touchid reports: its message (text mode prints `gh-touchid: <message>`), a stable snake_case code
// (`--json` prints `{"error": {"code", "message"}}`) and an exit status: 2 for wrong input, 1 for everything else.

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
    case unreadableFormat(item: String, storeAgain: String)
    case notSignedIn(String)
    case noApp(owner: String, logins: [String], program: String)
    case invalidToken
    case forbiddenCommand
    /// The command line as far as gh-touchid read it, ending with the word that names no command of gh.
    case unknownGitHubCommand(String)
    /// Where gh's list of commands was to come from.
    case gitHubCommandsUnreadable(String)
    case missingGitHubCLI(String)
    case changedGitHubCLI(String)
    case unverifiedGitHubCLI(String)
    case unsafeTerminalOutput
    case notGitTransport
    case input(String)
    case agent(String)
    case github(String)
    case refused(String)
    case readerMissing
    /// The reader App's install URL.
    case readerNotInstalled(String)
    /// How many installations the reader App has.
    case readerInstallations(Int)
    /// The permissions the reader App has, in words.
    case readerPermissions(String)
    /// The reader App's ID.
    case readerKeyRejected(Int)
    /// The stored reader's slug.
    case readerExists(String)
    case readerOpensIssue
    case invalidPrivateKey(String)
    case credentialPipeOnly
    /// The command that confirms, with `--yes`.
    case confirmationNeeded(String)
    /// The commands that do what could not be asked for.
    case inputNeeded(String)
    /// The path where gh-touchid-adapter was looked for.
    case missingAdapter(String)
    /// The operation that ran, and how its output does not fit the operation's schema.
    case outputInvalid(operation: String, problem: String)

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
        case let .unreadableFormat(item, storeAgain):
            return "the \(item) does not say a format gh-touchid can read (its Keychain description was changed?); "
                + "\(storeAgain) to store it again"
        case let .notSignedIn(owner):
            return "you are not signed in to the GitHub App for \(owner), or the sign-in has ended; "
                + "run `gh-touchid app login \(owner)`"
        case let .noApp(owner, logins, program):
            let accounts = logins.isEmpty
                ? "none stored yet; add one with `gh-touchid account add <login>`"
                : "stored: \(logins.joined(separator: ", "))"
            // Git never uses the reader: it reads public repositories without a credential
            let reader = program == "gh"
                ? "for public read-only access, store a reader with `gh-touchid reader create`; "
                : ""
            return "no GitHub App is stored for \(owner); \(reader)to act as one of your accounts: "
                + "gh-touchid as <login> -- \(program) … (\(accounts))"
        case .invalidToken:
            return "the token must contain only printable ASCII and no whitespace"
        case .forbiddenCommand:
            return "this gh command could reveal or replace the token"
        case let .unknownGitHubCommand(command):
            return "\(command) is not one of gh's own commands; gh-touchid runs only those, not extensions, aliases "
                + "or hidden commands (`gh-touchid gh --help` lists them)"
        case let .gitHubCommandsUnreadable(source):
            return "cannot read gh's list of commands from \(source), which gh-touchid needs to tell what a gh "
                + "command does; check that this gh runs"
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
        case .readerMissing:
            return "no reader is stored; run `gh-touchid reader create` for public read access, or name a repository "
                + "whose owner has an App (-R owner/name)"
        case let .readerNotInstalled(url):
            return "the reader App is not installed on its owner; install the reader: \(url)"
        case let .readerInstallations(count):
            return "the reader App has \(count) installations, not exactly one on its owner; uninstall the others "
                + "on GitHub, or run `gh-touchid reader remove`"
        case let .readerPermissions(permissions):
            return "the reader App has permissions (\(permissions)); remove them on GitHub or run "
                + "`gh-touchid reader remove`"
        case let .readerKeyRejected(appId):
            return "GitHub rejected the reader App's key (App ID \(appId)); run "
                + "`gh-touchid reader add --app-id \(appId) < key.pem` with a new key"
        case let .readerExists(slug):
            return "a reader is already stored (\(slug)); to give it a new key run "
                + "`gh-touchid reader add --app-id <id> < key.pem`, or `gh-touchid reader remove` first"
        case .readerOpensIssue:
            return "the public reader can't open issues; to open one as one of your accounts: "
                + "gh-touchid as <login> -- gh issue create …"
        case let .invalidPrivateKey(message):
            return "the private key cannot be used: \(message); pipe the App's PEM key: "
                + "gh-touchid reader add --app-id <id> < key.pem"
        case .credentialPipeOnly:
            return "`git credential get` answers only Git's own credential requests, not --json or --input; "
                + "Git runs it after `gh-touchid git setup <owner>`"
        case let .confirmationNeeded(command):
            return "this takes access away and there is no terminal to confirm it on; run `\(command)` to confirm"
        case let .inputNeeded(command):
            return "this needs an answer, and --no-input was given or there is no terminal to ask on; "
                + "run: \(command)"
        case let .outputInvalid(operation, problem):
            return "\(operation) ran, but its result does not fit its declared schema (\(problem)); this is a bug in "
                + "gh-touchid: report it with this message"
        case let .missingAdapter(path):
            return "gh-touchid rpc and mcp need gh-touchid-adapter, which is missing or not executable at \(path); "
                + "reinstall gh-touchid, or in a development build run scripts/build.sh (it writes "
                + "gh-touchid-adapter beside gh-touchid) or set GH_TOUCHID_ADAPTER"
        }
    }

    /// The stable code `--json` reports.
    var code: String {
        switch self {
        case .usage, .commandUsage: return "usage"
        case .input: return "invalid_input"
        case .invalidToken: return "invalid_token"
        case .authentication: return "authentication_failed"
        case .authenticationNotAnswered: return "approval_timed_out"
        case .screenLocked: return "screen_locked"
        case .keychain: return "keychain"
        case .missingRepository: return "missing_repository"
        case .missingAccount: return "missing_account"
        case .missingApp: return "missing_app"
        case .newerFormat: return "newer_format"
        case .unreadableFormat: return "unreadable_format"
        case .notSignedIn: return "not_signed_in"
        case .noApp: return "no_app"
        case .forbiddenCommand: return "forbidden_command"
        case .unknownGitHubCommand: return "unknown_command"
        case .gitHubCommandsUnreadable: return "gh_commands_unreadable"
        case .missingGitHubCLI: return "gh_missing"
        case .changedGitHubCLI: return "gh_changed"
        case .unverifiedGitHubCLI: return "gh_unverified"
        case .unsafeTerminalOutput: return "unsafe_terminal_output"
        case .notGitTransport: return "not_git_transport"
        case .agent: return "agent"
        case .github: return "github"
        case .refused: return "refused"
        case .readerMissing: return "reader_missing"
        case .readerNotInstalled: return "reader_not_installed"
        case .readerInstallations: return "reader_installations"
        case .readerPermissions: return "reader_permissions"
        case .readerKeyRejected: return "reader_key_rejected"
        case .readerExists: return "reader_exists"
        case .readerOpensIssue: return "reader_opens_issue"
        case .invalidPrivateKey: return "invalid_private_key"
        case .credentialPipeOnly: return "credential_pipe_only"
        case .confirmationNeeded: return "confirmation_needed"
        case .inputNeeded: return "input_needed"
        case .missingAdapter: return "adapter_missing"
        case .outputInvalid: return "output_invalid"
        }
    }

    /// 2 when the input was wrong, so that running the same thing again cannot help; 1 otherwise.
    var exitStatus: Int32 {
        switch self {
        case .usage, .commandUsage, .input, .invalidToken, .invalidPrivateKey, .confirmationNeeded, .inputNeeded,
             .unknownGitHubCommand:
            return 2
        default:
            return 1
        }
    }
}
