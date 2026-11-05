// Every failure gh-touchid reports: its message (text mode prints `gh-touchid: <message>`), a stable snake_case code
// (`--json` prints `{"error": {"code", "message"}}`) and an exit status: 2 for wrong input, 1 for everything else.
// The codes are declared once in `ErrorCode`, whose exit status and meaning `--help --json` lists for script authors
// (and docs/errors.md is generated from), so a code cannot exit with a status its documentation does not state.

/// The codes `--json` reports, in the order `--help --json` lists them.
enum ErrorCode: String, CaseIterable {
    case usage
    case invalidInput = "invalid_input"
    case invalidToken = "invalid_token"
    case authenticationFailed = "authentication_failed"
    case approvalTimedOut = "approval_timed_out"
    case screenLocked = "screen_locked"
    case keychain
    case missingRepository = "missing_repository"
    case missingAccount = "missing_account"
    case missingApp = "missing_app"
    case newerFormat = "newer_format"
    case unreadableFormat = "unreadable_format"
    case notSignedIn = "not_signed_in"
    case noApp = "no_app"
    case forbiddenCommand = "forbidden_command"
    case unknownCommand = "unknown_command"
    case ghCommandsUnreadable = "gh_commands_unreadable"
    case ghMissing = "gh_missing"
    case ghChanged = "gh_changed"
    case ghUnverified = "gh_unverified"
    case unsafeTerminalOutput = "unsafe_terminal_output"
    case notGitTransport = "not_git_transport"
    case agent
    case github
    case refused
    case readerMissing = "reader_missing"
    case readerNotInstalled = "reader_not_installed"
    case readerInstallations = "reader_installations"
    case readerPermissions = "reader_permissions"
    case readerKeyRejected = "reader_key_rejected"
    case readerExists = "reader_exists"
    case readerOpensIssue = "reader_opens_issue"
    case invalidPrivateKey = "invalid_private_key"
    case credentialPipeOnly = "credential_pipe_only"
    case confirmationNeeded = "confirmation_needed"
    case inputNeeded = "input_needed"
    case adapterMissing = "adapter_missing"
    case outputInvalid = "output_invalid"
    /// A failure that is not a `ToolError` (one the system reported), which `report` still gives a code.
    case unexpected = "error"

    /// 2 when the input was wrong, so that running the same thing again cannot help; 1 otherwise.
    var exitStatus: Int32 {
        switch self {
        case .usage, .invalidInput, .invalidToken, .invalidPrivateKey, .confirmationNeeded, .inputNeeded,
             .unknownCommand:
            return 2
        default:
            return 1
        }
    }

    /// What happened and what to do, in one sentence for script authors; the message says it for the case at hand.
    var meaning: String {
        switch self {
        case .usage:
            return "Not a gh-touchid command, or a wrong use of one; `gh-touchid help <command>` prints its usage."
        case .invalidInput:
            return "The input does not fit the command's input schema (a field missing, unknown, of the wrong type "
                + "or too large); the message names the field, and nothing was done."
        case .invalidToken:
            return "The token on stdin is not printable ASCII without whitespace; pipe the token alone."
        case .authenticationFailed:
            return "Touch ID failed or was denied, so nothing was approved; run the command again to be asked again."
        case .approvalTimedOut:
            return "Nobody answered Touch ID in time; run the command again while someone is at the Mac."
        case .screenLocked:
            return "The screen is locked, so nobody could approve; unlock it and run the command again."
        case .keychain:
            return "The Keychain refused to read or store an item; the message carries the Keychain's error."
        case .missingRepository:
            return "The command needs a repository and the current folder is not a Git repository with an origin "
                + "on github.com; run it in such a clone, or name the repository where the command takes one."
        case .missingAccount:
            return "No token is stored for the account named; store one with `gh-touchid account add <login>`."
        case .missingApp:
            return "No GitHub App is stored for the owner; make one with `gh-touchid app create <owner>`."
        case .newerFormat:
            return "A stored item was written by a newer gh-touchid, in a format this one cannot read; upgrade "
                + "gh-touchid."
        case .unreadableFormat:
            return "A stored item's Keychain description names no format gh-touchid reads (it was edited?); the "
                + "message names the command that stores it again."
        case .notSignedIn:
            return "Nobody is signed in to the owner's GitHub App, or the sign-in has ended; run "
                + "`gh-touchid app login <owner>`."
        case .noApp:
            return "The repository's owner has no GitHub App stored; the message names the other ways: one of your "
                + "accounts with `gh-touchid as <login> --`, or for gh the public reader."
        case .forbiddenCommand:
            return "The gh command could reveal or replace the token, so gh-touchid never runs it."
        case .unknownCommand:
            return "The words name none of gh's own commands (extensions, aliases and hidden commands are not run); "
                + "`gh-touchid gh --help` lists them."
        case .ghCommandsUnreadable:
            return "gh-touchid could not read gh's list of commands, which it needs to tell what a gh command does; "
                + "check that this gh runs."
        case .ghMissing:
            return "The GitHub CLI gh-touchid runs is not executable at the path the message names; reinstall "
                + "gh-touchid."
        case .ghChanged:
            return "The gh installed with gh-touchid is not the one it was built with; reinstall gh-touchid."
        case .ghUnverified:
            return "gh-touchid could not tell which code the gh it started was running, so it stopped gh before it "
                + "ran; nothing was done."
        case .unsafeTerminalOutput:
            return "`git credential get` would have written a credential to a terminal; only Git's credential pipe "
                + "gets one."
        case .notGitTransport:
            return "Something other than Git's own HTTPS transport (git-remote-https) asked for a credential, and "
                + "only that transport gets one."
        case .agent:
            return "The gh-touchid agent, which keeps sessions and elevations, failed or refused the request; the "
                + "message says why."
        case .github:
            return "GitHub refused or failed a request; the message is GitHub's answer, and running the command "
                + "again can help when the failure was temporary."
        case .refused:
            return "gh-touchid did not do what was asked (an approval not given, a callback that did not match, a "
                + "file it could not open); the message says why."
        case .readerMissing:
            return "No public reader is stored and the repository's owner has no App; run "
                + "`gh-touchid reader create`, or name a repository whose owner has one."
        case .readerNotInstalled:
            return "The reader App is not installed on its owner; install it from the URL in the message."
        case .readerInstallations:
            return "The reader App is not installed exactly once, on its owner; uninstall the others on GitHub or "
                + "run `gh-touchid reader remove`."
        case .readerPermissions:
            return "The reader App has permissions, which a reader must not; remove them on GitHub or run "
                + "`gh-touchid reader remove`."
        case .readerKeyRejected:
            return "GitHub rejected the reader App's private key; store a new one with "
                + "`gh-touchid reader add --app-id <id> < key.pem`."
        case .readerExists:
            return "A reader is already stored; give it a new key with `gh-touchid reader add`, or run "
                + "`gh-touchid reader remove` first."
        case .readerOpensIssue:
            return "The public reader cannot open issues; open one as one of your accounts with "
                + "`gh-touchid as <login> -- gh issue create`."
        case .invalidPrivateKey:
            return "The private key on stdin cannot be used; pipe the App's PEM key: "
                + "`gh-touchid reader add --app-id <id> < key.pem`."
        case .credentialPipeOnly:
            return "`git credential` answers only Git's own credential requests, not `--json` or `--input`; Git runs "
                + "it after `gh-touchid git setup <owner>`."
        case .confirmationNeeded:
            return "The command takes access away and there was no terminal to confirm on; the message gives the "
                + "command that confirms with `--yes`."
        case .inputNeeded:
            return "The command needs an answer and could not ask (`--no-input`, or no terminal); the message gives "
                + "the commands that do it without asking."
        case .adapterMissing:
            return "`rpc` and `mcp` need gh-touchid-adapter, which is missing or not executable; reinstall "
                + "gh-touchid."
        case .outputInvalid:
            return "The command ran, but its result does not fit its declared output schema; this is a bug in "
                + "gh-touchid, so report it with the message."
        case .unexpected:
            return "A failure the system reported that has no code of its own; the message says what failed."
        }
    }
}

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

    /// The stable code `--json` reports; its exit status comes with it.
    var code: ErrorCode {
        switch self {
        case .usage, .commandUsage: return .usage
        case .input: return .invalidInput
        case .invalidToken: return .invalidToken
        case .authentication: return .authenticationFailed
        case .authenticationNotAnswered: return .approvalTimedOut
        case .screenLocked: return .screenLocked
        case .keychain: return .keychain
        case .missingRepository: return .missingRepository
        case .missingAccount: return .missingAccount
        case .missingApp: return .missingApp
        case .newerFormat: return .newerFormat
        case .unreadableFormat: return .unreadableFormat
        case .notSignedIn: return .notSignedIn
        case .noApp: return .noApp
        case .forbiddenCommand: return .forbiddenCommand
        case .unknownGitHubCommand: return .unknownCommand
        case .gitHubCommandsUnreadable: return .ghCommandsUnreadable
        case .missingGitHubCLI: return .ghMissing
        case .changedGitHubCLI: return .ghChanged
        case .unverifiedGitHubCLI: return .ghUnverified
        case .unsafeTerminalOutput: return .unsafeTerminalOutput
        case .notGitTransport: return .notGitTransport
        case .agent: return .agent
        case .github: return .github
        case .refused: return .refused
        case .readerMissing: return .readerMissing
        case .readerNotInstalled: return .readerNotInstalled
        case .readerInstallations: return .readerInstallations
        case .readerPermissions: return .readerPermissions
        case .readerKeyRejected: return .readerKeyRejected
        case .readerExists: return .readerExists
        case .readerOpensIssue: return .readerOpensIssue
        case .invalidPrivateKey: return .invalidPrivateKey
        case .credentialPipeOnly: return .credentialPipeOnly
        case .confirmationNeeded: return .confirmationNeeded
        case .inputNeeded: return .inputNeeded
        case .missingAdapter: return .adapterMissing
        case .outputInvalid: return .outputInvalid
        }
    }

    var exitStatus: Int32 {
        code.exitStatus
    }
}
