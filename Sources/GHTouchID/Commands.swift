import Darwin
import Foundation

// The command line: global flags, help, and dispatch to the operations, then the declarations of every operation but
// the reader's (ReaderCommands.swift) and `status`/`setup` (Status.swift), with what they run. `gh`, `as` and
// `git credential` build their input by hand, since their arguments are another program's.

/// Runs the command line and returns the exit status; errors are reported here.
func runCommandLine() -> Int32 {
    var json = false
    do {
#if GH_TOUCHID_TESTING
        if let directory = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_RENDER"] {
            return try renderPrompts(into: directory)
        }
#endif
        let (options, arguments) = try splitGlobalOptions(Array(CommandLine.arguments.dropFirst()))
        json = options.json
        return try runCommand(arguments, options: options)
    } catch {
        return report(error, json: json)
    }
}

private func runCommand(_ arguments: [String], options: GlobalOptions) throws -> Int32 {
    guard let command = arguments.first else {
        throw ToolError.usage
    }
    let rest = Array(arguments.dropFirst())

    if ["help", "--help", "-h"].contains(command) {
        if options.json {
            guard rest.isEmpty, options.input == nil else {
                throw ToolError.usage
            }
            print(jsonLine(toolsDocument()))
            return 0
        }
        guard rest.count <= 1 else {
            throw ToolError.usage
        }
        guard let name = rest.first else {
            print(Usage.all)
            return 0
        }
        guard let text = Usage.of(name) else {
            throw ToolError.usage
        }
        print(text)
        return 0
    }
    // `<command> --help`; everything after `gh` is GitHub CLI's, its `--help` included
    if command != "gh", let first = rest.first, ["--help", "-h"].contains(first), let text = Usage.of(command) {
        print(text)
        return 0
    }
    do {
        return try dispatch(command == "--version" ? ["version"] + rest : arguments, options: options)
    } catch ToolError.usage where Usage.of(command) != nil {
        throw ToolError.commandUsage(command)
    }
}

private func dispatch(_ arguments: [String], options: GlobalOptions) throws -> Int32 {
    let command = arguments[0]
    let rest = Array(arguments.dropFirst())
    switch command {
    case "agent":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        try runAgent()
    case "rpc", "mcp":
        try runAdapter(mode: command, arguments: rest)
    default:
        break
    }
    guard let match = matchOperation(arguments) else {
        throw ToolError.usage
    }
    let (operation, after) = match
    if let source = options.input {
        guard after.isEmpty else {
            throw ToolError.usage
        }
        return try perform(operation, input: try readInputDocument(source), options: options, fromCommandLine: false)
    }
    let input: [String: Any]
    switch operation.name {
    case "gh":
        input = ["argv": after]
    case "as":
        let (login, command) = try asArguments(after)
        input = ["login": login, "argv": command]
    case "git_credential":
        input = try gitCredentialInput(after, json: options.json)
    default:
        input = try commandLineInput(operation, after)
    }
    return try perform(operation, input: input, options: options, fromCommandLine: true)
}

/// Synopses that are not made from the declaration: the commands whose arguments are another program's.
let commandSynopses = [
    "gh": "gh-touchid gh <arguments...>",
    "as": "gh-touchid as <login> [--] <command> [arguments...]",
    "git_credential": "gh-touchid git credential <get|store|erase>",
]

// MARK: Schemas

/// A GitHub account name.
let ownerSchema = Schema.string(pattern: "^[A-Za-z0-9._-]{1,100}$", description: "A GitHub user or organization.")

/// An object schema from `(name, schema)` pairs.
func objectSchema(
    _ properties: [(String, Schema)],
    required: [String] = [],
    description: String = ""
) -> Schema {
    .object(properties: properties.map { (name: $0.0, schema: $0.1) }, required: required, description: description)
}

private let openBrowserSchema = Schema.boolean(
    description: "Open the browser (default true); false prints the address instead."
)
private let gitSetupSchema = Schema.boolean(
    description: "Set up Git for the owner afterwards. Without it, a terminal is asked; otherwise Git is left as is."
)
private let repositoriesSchema = Schema.array(
    .string(pattern: "^[^/\\s]+/[^/\\s]+$", description: "owner/name"),
    description: "Repositories; without them, those of the working folder."
)
private let folderSchema = Schema.string(description: "The folder to run in; by default the current one.")
private let streamsOutput: [(String, Schema)] = [
    ("exit_code", .integer(description: "The command's exit status (128 plus the signal that ended it).")),
    ("stdout", .string(description: "Its standard output, when at most 1 MiB.")),
    ("stdout_file", .string(description: "The 0600 file holding its standard output, when larger.")),
    ("stderr", .string(description: "Its standard error, when at most 1 MiB.")),
    ("stderr_file", .string(description: "The 0600 file holding its standard error, when larger.")),
]
private let emptyObject = objectSchema([])

/// `value`, or JSON null.
func nullable(_ value: Any?) -> Any {
    value ?? NSNull()
}

/// The owner as typed (Git compares it case-sensitively) and lowercase (as items are stored).
private func owners(_ input: [String: Any], _ field: String = "owner") throws -> (typed: String, stored: String) {
    let typed = input[field] as? String ?? ""
    guard let stored = validOwner(typed) else {
        throw ToolError.input("\(field) takes a GitHub account name")
    }
    return (typed, stored)
}

/// Runs in `input["cwd"]` when it names a folder.
private func enterFolder(_ input: [String: Any]) throws {
    guard let folder = input["cwd"] as? String else {
        return
    }
    guard chdir(folder) == 0 else {
        throw ToolError.input("cannot run in \(printable(folder)): \(String(cString: strerror(errno)))")
    }
}

// MARK: Operations

/// Every operation declared here and in Status.swift.
let commandOperations: [Operation] = [
    Operation(
        name: "app_create",
        words: ["app", "create"],
        title: "Create an owner's GitHub App",
        description: "`app create` makes a private GitHub App for an owner from a manifest in your browser (named "
            + "<owner>-touchid unless --name says otherwise), signs you in to it and opens its installation page "
            + "(--no-open prints the first URL instead). It asks for Touch ID before storing anything.",
        example: "gh-touchid app create acme --name acme-agents",
        positional: ["owner"],
        input: objectSchema([
            ("owner", ownerSchema),
            ("name", .string(pattern: "^[^\\x00-\\x1F\\x7F]{1,100}$", description: "The App's name.")),
            ("open_browser", openBrowserSchema),
            ("git_setup", gitSetupSchema),
        ], required: ["owner"]),
        output: objectSchema([
            ("owner", ownerSchema),
            ("app", .string(description: "The App's slug.")),
            ("app_id", .integer(description: "The App's ID.")),
            ("login", .string(description: "Who is signed in to it.")),
            ("install_url", .string(description: "Where to install it.")),
            ("git_setup", .boolean(description: "Whether Git was set up for the owner.")),
        ], required: ["owner", "app", "app_id", "login", "install_url", "git_setup"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { context, input in
            let owner = try owners(input)
            let name = input["name"] as? String ?? "\(owner.stored)-touchid"
            let created = try createApp(
                owner: owner.stored,
                name: name,
                openBrowser: input["open_browser"] as? Bool ?? true
            )
            guard let login = created.login else {
                throw ToldError(error: .notSignedIn(owner.stored))
            }
            let git = try offerGitSetup(
                owner: owner.typed,
                choice: input["git_setup"] as? Bool,
                noInput: context.noInput,
                json: context.json
            )
            return [
                "owner": owner.stored,
                "app": created.slug,
                "app_id": created.appId,
                "login": login,
                "install_url": created.installURL,
                "git_setup": git,
            ]
        },
        text: { _ in nil }
    ),
    Operation(
        name: "app_add",
        words: ["app", "add"],
        title: "Add an App made by hand",
        description: "`app add` takes an App made by hand: its client ID, and its client secret on stdin or at a "
            + "hidden prompt; it must list the callback URL http://127.0.0.1:47911/callback. It signs you in to it "
            + "and asks for Touch ID before storing both.",
        example: "gh-touchid app add acme --client-id Iv23liAbCdEf < client-secret",
        positional: ["owner"],
        input: objectSchema([
            ("owner", ownerSchema),
            ("client_id", .string(pattern: "^[!-~]+$", description: "The App's client ID.")),
            ("client_secret", .string(secret: true, description: "The App's client secret.")),
            ("open_browser", openBrowserSchema),
            ("git_setup", gitSetupSchema),
        ], required: ["owner", "client_id", "client_secret"]),
        output: objectSchema([
            ("owner", ownerSchema),
            ("app", .nullable(.string(description: "The App's slug, when it is installed where you can see."))),
            ("login", .string(description: "Who is signed in to it.")),
            ("git_setup", .boolean(description: "Whether Git was set up for the owner.")),
        ], required: ["owner", "app", "login", "git_setup"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { context, input in
            let owner = try owners(input)
            let app = AppCredentials(
                clientId: input["client_id"] as? String ?? "",
                clientSecret: try normalizeToken(input["client_secret"] as? String ?? "")
            )
            let open = input["open_browser"] as? Bool ?? true
            let (slug, login) = try addApp(app, owner: owner.stored, openBrowser: open)
            let git = try offerGitSetup(
                owner: owner.typed,
                choice: input["git_setup"] as? Bool,
                noInput: context.noInput,
                json: context.json
            )
            return ["owner": owner.stored, "app": nullable(slug), "login": login, "git_setup": git]
        },
        text: { _ in nil }
    ),
    Operation(
        name: "app_login",
        words: ["app", "login"],
        title: "Sign in to an owner's App again",
        description: "`app login` signs you in to the owner's App again, as when the sign-in has ended.",
        example: "gh-touchid app login acme",
        positional: ["owner"],
        input: objectSchema([("owner", ownerSchema), ("open_browser", openBrowserSchema)], required: ["owner"]),
        output: objectSchema([
            ("owner", ownerSchema),
            ("login", .string(description: "Who is signed in.")),
        ], required: ["owner", "login"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: true, openWorld: true),
        run: { _, input in
            let owner = try owners(input)
            let login = try appLogin(owner: owner.stored, openBrowser: input["open_browser"] as? Bool ?? true)
            return ["owner": owner.stored, "login": login]
        },
        text: { _ in nil }
    ),
    Operation(
        name: "app_remove",
        words: ["app", "remove"],
        title: "Remove an owner's App",
        description: "`app remove` deletes the owner's App and your sign-in from this Mac and the owner's Git "
            + "entries, ends the sign-in's grant on GitHub, and prints where to delete the App on GitHub. It asks "
            + "on a terminal; elsewhere --yes confirms.",
        example: "gh-touchid app remove acme --yes",
        positional: ["owner"],
        input: objectSchema([
            ("owner", ownerSchema),
            ("yes", .boolean(description: "Confirm without asking.")),
        ], required: ["owner"]),
        output: objectSchema([
            ("owner", ownerSchema),
            ("removed", objectSchema([
                ("app", .boolean(description: "The App's item was deleted.")),
                ("sign_in", .boolean(description: "The sign-in's item was deleted.")),
                ("git", .boolean(description: "The owner's Git entries were removed.")),
            ], required: ["app", "sign_in", "git"])),
            ("delete_url", .nullable(.string(description: "Where to delete the App on GitHub."))),
        ], required: ["owner", "removed", "delete_url"]),
        annotations: Annotations(readOnly: false, destructive: true, idempotent: true, openWorld: true),
        run: { context, input in
            try removeApp(owner: try owners(input).stored, yes: input["yes"] as? Bool ?? false, context: context)
        },
        text: { _ in nil }
    ),
    Operation(
        name: "account_add",
        words: ["account", "add"],
        title: "Store a token of one of your accounts",
        description: "`account add` stores a token of one of your GitHub accounts (hidden input or stdin) once "
            + "GitHub confirms its login, after Touch ID. `as` uses it.",
        example: "gh-touchid account add alice < token",
        positional: ["login"],
        input: objectSchema([
            ("login", ownerSchema),
            ("token", .string(secret: true, description: "A token of the account.")),
        ], required: ["login", "token"]),
        output: objectSchema([
            ("login", ownerSchema),
            ("scopes", .nullable(.string(description: "The scopes GitHub lists for the token."))),
        ], required: ["login", "scopes"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { _, input in
            let login = try owners(input, "login").stored
            let scopes = try addAccount(login: login, token: input["token"] as? String ?? "")
            return ["login": login, "scopes": nullable(scopes)]
        },
        text: { _ in nil }
    ),
    Operation(
        name: "account_remove",
        words: ["account", "remove"],
        title: "Delete a stored account token",
        description: "`account remove` deletes the stored token of one of your accounts.",
        example: "gh-touchid account remove alice",
        positional: ["login"],
        input: objectSchema([("login", ownerSchema)], required: ["login"]),
        output: objectSchema([
            ("login", ownerSchema),
            ("removed", .boolean(description: "Always true: a missing token is an error.")),
        ], required: ["login", "removed"]),
        annotations: Annotations(readOnly: false, destructive: true, idempotent: true, openWorld: false),
        run: { _, input in
            let login = try owners(input, "login").stored
            try removeAccount(login: login)
            return ["login": login, "removed": true]
        },
        text: { _ in nil }
    ),
    Operation(
        name: "gh",
        words: ["gh"],
        title: "Run GitHub CLI with a narrowed token",
        description: "`gh` runs GitHub CLI with a token for one repository: the one named with -R/--repo, for "
            + "`gh api` the one its endpoint names, else GH_REPO, else the current repository's origin. The token "
            + "acts as you through the owner's App and lacks the workflows permission unless the repository is "
            + "elevated; outside a session, each use asks for Touch ID. With no repository, or for an owner "
            + "without an App, it uses the public reader when one is stored (no Touch ID, public data only), and "
            + "otherwise refuses before asking. Everything after `gh` goes to GitHub CLI: `gh-touchid gh --help` "
            + "is its help. With --json, its output is captured.",
        example: "gh-touchid gh -R acme/widgets pr list",
        positional: [],
        input: objectSchema([
            ("argv", .array(.string(), description: "GitHub CLI's arguments.")),
            ("cwd", folderSchema),
            ("stdin", .string(description: "GitHub CLI's standard input (with --json); by default none.")),
        ], required: ["argv"]),
        output: objectSchema(streamsOutput, required: ["exit_code"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { context, input in
            try enterFolder(input)
            let capture = try outputCapture(input, json: context.json)
            let status = try runGitHub(input["argv"] as? [String] ?? [], account: actingAccount(), capture: capture)
            return streamsResult(status, capture)
        },
        text: { _ in nil }
    ),
    Operation(
        name: "git_setup",
        words: ["git", "setup"],
        title: "Make Git ask gh-touchid for an owner",
        description: "`git setup` makes this gh-touchid the only credential helper Git asks for the owner's "
            + "repositories, in your global Git configuration (write the owner as in your remotes' URLs).",
        example: "gh-touchid git setup acme",
        positional: ["owner"],
        input: objectSchema([("owner", ownerSchema)], required: ["owner"]),
        output: objectSchema([
            ("owner", ownerSchema),
            ("file", .string(description: "The configuration file written.")),
            ("helper", .string(description: "The helper entry naming this gh-touchid.")),
            ("entries", .array(.string(), description: "The section's entries as written.")),
            ("kept", .integer(minimum: 0, description: "How many other settings of the section were kept.")),
            ("notes", .array(.string(), description: "Advice about what may still change these entries.")),
        ], required: ["owner", "file", "helper", "entries", "kept", "notes"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: true, openWorld: false),
        run: { _, input in
            _ = try owners(input)
            return try setUpGit(owner: input["owner"] as? String ?? "").output
        },
        text: GitSetupResult.text
    ),
    Operation(
        name: "git_credential",
        words: ["git", "credential"],
        title: "Git's credential helper",
        description: "`git credential` is the helper `git setup` names; it answers only Git's HTTPS transport, "
            + "in Git's key=value form, never to a terminal, --json or --input.",
        example: "gh-touchid git credential get",
        positional: [],
        input: objectSchema([
            ("action", .string(enumValues: ["get", "store", "erase"], description: "What Git asks.")),
            ("protocol", .string(description: "The URL's scheme.")),
            ("host", .string(description: "The URL's host.")),
            ("path", .string(description: "The URL's path: owner/name.git.")),
            ("username", .string(description: "The user name Git has.")),
        ], required: ["action", "protocol", "host"]),
        output: objectSchema([
            ("username", .string(description: "Who the token acts as.")),
            ("password", .string(secret: true, description: "The token.")),
            ("password_expiry_utc", .integer(description: "When the token expires, in Unix seconds.")),
        ]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { _, input in try answerGitCredential(input) },
        text: { output in
            guard let username = output["username"] as? String, let password = output["password"] as? String else {
                return nil
            }
            var lines = ["username=\(username)", "password=\(password)"]
            if let expires = output["password_expiry_utc"] as? Int {
                lines.append("password_expiry_utc=\(expires)")
            }
            return lines.joined(separator: "\n")
        }
    ),
    Operation(
        name: "as",
        words: ["as"],
        title: "Run a command as one of your accounts",
        description: "`as` runs a command as one of your stored accounts, with Touch ID on every use, sessions "
            + "included: `as <login> gh ...` runs GitHub CLI with that account's token, anything else runs with "
            + "GH_TOUCHID_AS=<login>, which gh and Git honour. The `--` before the command is optional. With "
            + "--json, its output is captured.",
        example: "gh-touchid as alice -- gh issue create -R octo-org/hello-world",
        positional: [],
        input: objectSchema([
            ("login", ownerSchema),
            ("argv", .array(.string(), description: "The command and its arguments.")),
            ("cwd", folderSchema),
            ("stdin", .string(description: "The command's standard input (with --json); by default none.")),
        ], required: ["login", "argv"]),
        output: objectSchema(streamsOutput, required: ["exit_code"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { context, input in
            let login = try owners(input, "login").stored
            guard let command = input["argv"] as? [String], !command.isEmpty else {
                throw ToolError.input("argv: names no command")
            }
            try enterFolder(input)
            let capture = try outputCapture(input, json: context.json)
            let status = try runAs(login: login, command: command, capture: capture)
            return streamsResult(status, capture)
        },
        text: { _ in nil }
    ),
    Operation(
        name: "session",
        words: ["session"],
        title: "Register the calling program as a session",
        description: "`session` registers the program that ran it (looking past shells that only run a command or "
            + "a script). Its first GitHub use asks for Touch ID once; then it and everything it starts get tokens "
            + "for its repositories without Touch ID until it exits, and issue-only tokens for other repositories "
            + "your Apps are installed on (public ones ask per use). Without --repo it takes the outermost Git "
            + "repository here and those nested up to two levels below it whose owner has an App.",
        example: "gh-touchid session --repo acme/widgets",
        positional: [],
        input: objectSchema([("repos", repositoriesSchema), ("cwd", folderSchema)]),
        output: objectSchema([
            ("program", .string(description: "The registered program, as program[pid].")),
            ("repositories", .array(.string(), description: "The session's repositories.")),
            ("state", .string(enumValues: ["approved", "pending"], description: "Whether it is approved yet.")),
        ], required: ["program", "repositories", "state"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: false),
        run: { _, input in
            try enterFolder(input)
            return try registerSession(repositories: input["repos"] as? [String])
        },
        text: { _ in nil }
    ),
    Operation(
        name: "elevate",
        words: ["elevate"],
        title: "Let tokens include workflows for a while",
        description: "`elevate` lets tokens for the repositories (without --repo, the current one) include the "
            + "workflows permission for a while: 30m, 8h, 1h30m, at most 1d. It asks for Touch ID.",
        example: "gh-touchid elevate --for 30m --repo acme/widgets",
        positional: [],
        input: objectSchema([
            ("for", .string(pattern: "^(\\d+d)?(\\d+h)?(\\d+m)?$", description: "How long: 30m, 8h, 1h30m, 1d.")),
            ("repos", repositoriesSchema),
            ("cwd", folderSchema),
        ], required: ["for"]),
        output: objectSchema([
            ("repositories", .array(.string(), description: "The elevated repositories.")),
            ("until", .string(description: "When the elevation ends, ISO 8601.")),
        ], required: ["repositories", "until"]),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: true, openWorld: false),
        run: { _, input in
            try enterFolder(input)
            return try elevate(duration: input["for"] as? String ?? "", repositories: input["repos"] as? [String])
        },
        text: { _ in nil }
    ),
    statusOperation,
    setupOperation,
    Operation(
        name: "lock",
        words: ["lock"],
        title: "End every session approval and elevation",
        description: "`lock` ends every session approval and elevation now.",
        example: "gh-touchid lock",
        positional: [],
        input: emptyObject,
        output: objectSchema([
            ("locked", .boolean(description: "Whether anything was active."))
        ], required: ["locked"]),
        annotations: Annotations(readOnly: false, destructive: true, idempotent: true, openWorld: false),
        run: { _, _ in ["locked": lockAgents()] },
        text: { output in
            output["locked"] as? Bool == true
                ? "Locked: every session approval and elevation has ended."
                : "Nothing was active."
        }
    ),
    Operation(
        name: "version",
        words: ["version"],
        title: "gh-touchid's version",
        description: "`version` prints gh-touchid's version.",
        example: "gh-touchid version",
        positional: [],
        input: emptyObject,
        output: objectSchema([("version", .string(description: "The version."))], required: ["version"]),
        annotations: Annotations(readOnly: true, destructive: false, idempotent: true, openWorld: false),
        run: { _, _ in ["version": toolVersion] },
        text: { $0["version"] as? String }
    ),
]

// MARK: What the operations run

/// The output of `gh` and `as`: the exit status, and with `capture` what the command wrote.
private func streamsResult(_ status: Int32, _ capture: OutputCapture?) -> [String: Any] {
    var output: [String: Any] = capture?.result() ?? [:]
    output["exit_code"] = Int(status)
    return output
}

/// With `--json`, where a child's streams go: stdin from the input's `stdin` (else gh-touchid's own, unless `--input
/// -` took it), stdout and stderr into files. Nil without `--json`, when the child shares gh-touchid's streams.
private func outputCapture(_ input: [String: Any], json: Bool) throws -> OutputCapture? {
    let stdin = input["stdin"] as? String
    guard json else {
        guard stdin == nil else {
            throw ToolError.input("stdin is passed on only with --json")
        }
        return nil
    }
    return try OutputCapture(input: stdin.map { Data($0.utf8) }, inheritInput: !inputReadFromStandardInput)
}

/// An App made by hand: its client ID and secret. It must list the callback URL; the sign-in that follows is what
/// checks the secret, and one Touch ID stores both. The App's slug (nil when it is installed nowhere you can see)
/// and the login signed in.
private func addApp(_ app: AppCredentials, owner: String, openBrowser: Bool) throws -> (String?, String) {
    let server = try LocalServer(port: callbackPort)
    let request = try signInRequest(app: app)
    fputs(
        "The App must list \(callbackURL) as a callback URL. To sign in to it, open \(request.url) and choose "
            + "Authorize (waiting up to 15 minutes).\n",
        stderr
    )
    if openBrowser {
        openInBrowser(request.url)
    }
    let (signIn, browser) = try awaitSignIn(
        request,
        app: app,
        owner: owner,
        server: server,
        deadline: Date().addingTimeInterval(signInTimeout)
    )
    defer { close(browser) }
    let slug = installedAppSlug(token: signIn.accessToken)
    do {
        try authenticate(.signIn(signIn.login, owner: owner, app: slug, storesApp: true))
    } catch {
        respond(browser, status: 200, text: "Nothing was stored: \(error)")
        throw error
    }
    do {
        try storeSignedIn(signIn, app: app, slug: slug, owner: owner)
    } catch {
        respond(browser, status: 200, text: "\(error)")
        throw error
    }
    respond(browser, status: 200, text: "Signed in as \(signIn.login). You can close this tab.")
    appendAccessLog("stored the \(owner) App\(slug.map { " \($0)" } ?? "") and signed in as \(signIn.login)")
    fputs("Stored \(appWords(slug, owner: owner)) for \(owner) and signed you in to it as \(signIn.login).\n", stderr)
    if slug == nil {
        fputs("It is not installed anywhere you can see yet: install it on \(owner) from its settings page.\n", stderr)
    }
    return (slug, signIn.login)
}

/// `app remove`: after confirmation, reads and deletes the owner's App and sign-in items in one hold of the owner's
/// sign-in lock (so the grant ended below is the one of the pair deleted), ends that grant on GitHub, best effort, and
/// only then removes the owner's Git entries: once the items are gone, nothing else could end the grant.
private func removeApp(owner: String, yes: Bool, context: OperationContext) throws -> [String: Any] {
    let slug = appSlug(owner: owner)
    guard hasAppCredentials(owner: owner) || hasSignIn(owner: owner) else {
        throw ToolError.missingApp(owner)
    }
    if !yes {
        let command = "gh-touchid app remove \(owner) --yes"
        guard !context.noInput, isatty(STDERR_FILENO) != 0 else {
            throw ToolError.confirmationNeeded(command)
        }
        let question = "Remove \(appWords(slug, owner: owner)) and your sign-in for \(owner) from this Mac? [y/N] "
        guard let answer = askInTerminal(question) else {
            throw ToolError.confirmationNeeded(command)
        }
        guard ["y", "yes"].contains(answer.lowercased()) else {
            throw ToolError.refused("nothing was removed")
        }
    }
    let removed = try withSignInLock(owner: owner) {
        () -> (app: Bool, signIn: Bool, grant: (AppCredentials, SignIn)?) in
        let app = try? loadAppCredentials(owner: owner)
        let signIn = try? loadSignIn(owner: owner)
        let removedApp = try removeAppCredentials(owner: owner)
        let removedSignIn = try removeSignIn(owner: owner)
        return (removedApp, removedSignIn, app.flatMap { app in signIn.map { (app, $0) } })
    }
    appendAccessLog("removed the \(owner) App\(slug.map { " \($0)" } ?? "") and its sign-in")
    if case let (app, signIn)? = removed.grant {
        do {
            try revokeGrant(app: app, accessToken: signIn.accessToken)
            appendAccessLog("ended the grant of \(signIn.login) to the \(owner) App")
        } catch {
            appendAccessLog("could not end the grant of \(signIn.login) to the \(owner) App: \(error)")
            fputs("gh-touchid: could not end your sign-in's grant on GitHub: \(error)\n", stderr)
        }
    }
    let git: Bool
    do {
        git = try removeGitSetup(owner: owner)
    } catch {
        throw ToolError.refused(
            "removed \(appWords(slug, owner: owner)) and your sign-in for \(owner), but not its Git entries in your "
                + "global Git configuration (\(error)); remove them with "
                + "`git config --global --remove-section credential.https://github.com/\(owner)`"
        )
    }
    var deleteURL: String?
    if let slug, let web = try? webBaseURL() {
        let settings = (try? isOrganization(owner)) == true ? "organizations/\(owner)/settings" : "settings"
        deleteURL = "\(web)/\(settings)/apps/\(slug)/advanced"
    }
    fputs(
        "Removed \(appWords(slug, owner: owner)) and your sign-in for \(owner)\(git ? ", and its Git entries" : "")."
            + (deleteURL.map { " To delete the App on GitHub: \($0)" } ?? "") + "\n",
        stderr
    )
    return [
        "owner": owner,
        "removed": ["app": removed.app, "sign_in": removed.signIn, "git": git],
        "delete_url": nullable(deleteURL),
    ]
}

/// gh with a token narrowed from your sign-in to the owner's App, with the reader's, or with the token of `account`;
/// with `capture`, gh's streams are its files. gh's exit status.
func runGitHub(_ arguments: [String], account: String?, capture: OutputCapture? = nil) throws -> Int32 {
    guard !isForbiddenGitHubCommand(arguments) else {
        let command = commandSummary(["gh"] + arguments.prefix(2))
        appendAccessLog("refused \(command) to \(processChain(getpid())): \(ToolError.forbiddenCommand)")
        throw ToolError.forbiddenCommand
    }
    let repository: String?
    do {
        // an account's token is not limited to the repository named in the dialog: no guessing which one gh acts on
        repository = try requestedRepository(arguments, exact: account != nil)
    } catch ToolError.missingRepository {
        repository = nil // an account or the reader needs no repository, as in `gh api user` outside one
    }
    let cli = try gitHubCLI()
    let authorization = try authorizeUse(
        repository: repository,
        use: ghUse(arguments),
        account: account,
        forGit: false,
        arguments: arguments
    )
    // from the mint until the revoke, a signal is remembered or passed on to gh instead of ending gh-touchid
    let relay = SignalRelay()
    defer { relay.remove() }
    let credential = try issueCredential(authorization)
    defer { revokeAfterUse(credential, repository: authorization.target) }
    if let number = relay.received {
        fputs("gh-touchid: stopped by signal \(number) before gh started\n", stderr)
        return 128 + number
    }
    return try runGitHubCLI(cli, arguments: arguments, token: credential.token, relay: relay, capture: capture)
}

/// Whether this `git credential get` came from Git itself, in Git's key=value form, checked before its request was
/// read; only then is a credential answered.
private var credentialRequestFromGit = false

/// The input of `git credential <get|store|erase>` from Git's key=value request on stdin. `get` is answered only
/// to Git's HTTPS transport and never to a terminal; with `--json` it is refused before stdin is read.
private func gitCredentialInput(_ arguments: [String], json: Bool) throws -> [String: Any] {
    guard arguments.count == 1, ["get", "store", "erase"].contains(arguments[0]) else {
        throw ToolError.usage
    }
    let action = arguments[0]
    if action == "get" {
        guard !json else {
            throw ToolError.credentialPipeOnly
        }
        guard isatty(STDOUT_FILENO) == 0 else {
            throw ToolError.unsafeTerminalOutput
        }
        guard calledByGitTransport() else {
            appendAccessLog("refused a Git credential to \(processChain(getpid())): \(ToolError.notGitTransport)")
            throw ToolError.notGitTransport
        }
        credentialRequestFromGit = true
    }
    let request = readCredentialRequest()
    if action != "get" {
        discardStandardInput()
    }
    var input: [String: Any] = [
        "action": action,
        "protocol": request["protocol"] ?? "",
        "host": request["host"] ?? "",
    ]
    for key in ["path", "username"] {
        if let value = request[key] {
            input[key] = value
        }
    }
    return input
}

/// Git's credential-helper protocol: a credential for `get`, nothing for `store` and `erase`, nor for a host other
/// than GitHub.
private func answerGitCredential(_ request: [String: Any]) throws -> [String: Any] {
    guard request["action"] as? String == "get" else {
        return [:]
    }
    guard credentialRequestFromGit else {
        throw ToolError.credentialPipeOnly
    }
    guard isGitHubCredentialRequest(protocol: request["protocol"] as? String, host: request["host"] as? String) else {
        return [:]
    }
    let account = try actingAccount()
    let repository: String?
    if let path = request["path"] as? String, !path.isEmpty {
        guard let named = validRepository(path) else {
            throw ToolError.input("cannot tell the GitHub repository from the path \(printable(path))")
        }
        repository = named
    } else {
        do {
            repository = try repositoryIdentifier()
        } catch ToolError.missingRepository where account != nil {
            repository = nil
        }
    }
    let authorization = try authorizeUse(
        repository: repository,
        use: gitUse(),
        account: account,
        forGit: true,
        arguments: nil
    )
    let credential = try issueCredential(authorization)
    var output: [String: Any] = ["username": credential.username, "password": credential.token]
    if let expires = credential.expires {
        output["password_expiry_utc"] = Int(expires.timeIntervalSince1970)
    }
    return output
}

/// Whether the nearest ancestor that is not a shell is Git's HTTP transport, as when Git fetches or pushes;
/// `git credential fill` and anything else that asks directly are not.
private func calledByGitTransport() -> Bool {
    for ancestor in lineage(getppid()) {
        let name = processName(ancestor)
        if shellNames.contains(name) {
            continue
        }
        return name == "git-remote-http" || name == "git-remote-https"
    }
    return false
}

/// Git's `key=value` request lines, up to a blank line or the end of input.
private func readCredentialRequest() -> [String: String] {
    var request: [String: String] = [:]
    while let line = readLine(strippingNewline: true), !line.isEmpty {
        guard let separator = line.firstIndex(of: "=") else {
            continue
        }
        request[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    return request
}

/// `session`: registers the program that ran this command, for `repositories` or those of the workspace here.
private func registerSession(repositories named: [String]?) throws -> [String: Any] {
    let repositories = try named.map { try repositoriesOption(["--repo": $0]) } ?? workspaceRepositories()
    try ensureAgent()
    let request: [String: Any] = [
        "op": "register",
        "repos": repositories,
        "folder": FileManager.default.currentDirectoryPath,
    ]
    guard let reply = agentRequest(request) else {
        throw ToolError.agent("the agent did not answer")
    }
    guard let session = SessionInfo(reply["session"]) else {
        throw ToolError.agent(reply["error"] as? String ?? "the agent did not register the session")
    }
    let state = session.approved ? "approved" : "pending; its first GitHub use asks for Touch ID"
    fputs(
        "Session \(session.label) in \(displayFolder(session.folder)) for "
            + "\(session.repositories.joined(separator: ", ")): \(state).\n",
        stderr
    )
    // The session only helps the programs whose Git and gh come here; say so now rather than at their first use.
    for warning in sessionWarnings(repositories: session.repositories) {
        fputs("Warning: \(warning)\n", stderr)
    }
    return [
        "program": session.label,
        "repositories": session.repositories,
        "state": session.approved ? "approved" : "pending",
    ]
}

/// `elevate`: tokens for these repositories (by default the current one) include workflows for `duration`.
private func elevate(duration: String, repositories named: [String]?) throws -> [String: Any] {
    let seconds = try parseDuration(duration)
    let repositories = try repositoriesOption(named.map { ["--repo": $0] } ?? [:])
    try authenticate(.elevation(repositories: repositories, seconds: seconds, by: requester()))
    try ensureAgent()
    let reply = agentRequest(["op": "elevate", "repos": repositories, "seconds": seconds])
    guard reply?["ok"] as? Bool == true else {
        throw ToolError.agent(reply?["error"] as? String ?? "the agent did not accept the elevation")
    }
    let until = Date().addingTimeInterval(seconds)
    fputs(
        "Elevated \(repositories.joined(separator: ", ")) until \(localTime(until)): their tokens include workflows.\n",
        stderr
    )
    return ["repositories": repositories, "until": ISO8601DateFormatter().string(from: until)]
}
