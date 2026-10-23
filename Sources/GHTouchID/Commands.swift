import Darwin
import Foundation

func run() throws -> Int32 {
#if GH_TOUCHID_TESTING
    if let directory = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_RENDER"] {
        return try renderPrompts(into: directory)
    }
#endif
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw ToolError.usage
    }
    let rest = Array(arguments.dropFirst())

    if ["help", "--help", "-h"].contains(command) {
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
        return try dispatch(command, rest)
    } catch ToolError.usage where Usage.of(command) != nil {
        throw ToolError.commandUsage(command)
    }
}

private func dispatch(_ command: String, _ rest: [String]) throws -> Int32 {
    switch command {
    case "version", "--version":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        print(toolVersion)
        return 0
    case "app":
        return try appCommand(rest)
    case "account":
        return try accountCommand(rest)
    case "gh":
        return try runGitHub(rest, account: actingAccount())
    case "git":
        return try gitCommand(rest)
    case "as":
        return try runAs(rest)
    case "session":
        return try registerSession(rest)
    case "elevate":
        return try elevate(rest)
    case "status":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        return try showStatus()
    case "lock":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        let locked = lockAgents()
        print(locked ? "Locked: every session approval and elevation has ended." : "Nothing was active.")
        return 0
    case "agent":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        try runAgent()
    default:
        throw ToolError.usage
    }
}

/// `git setup <owner>` or `git credential <get|store|erase>`.
private func gitCommand(_ arguments: [String]) throws -> Int32 {
    switch arguments.first {
    case "setup":
        return try gitSetup(Array(arguments.dropFirst()))
    case "credential":
        return try gitCredential(Array(arguments.dropFirst()))
    default:
        throw ToolError.usage
    }
}

/// `app create <owner> [--name <name>] [--no-open]`, `app set <owner> --client-id <id> [--no-open]` with the client
/// secret on stdin (or typed, hidden), or `app login <owner> [--no-open]`.
private func appCommand(_ arguments: [String]) throws -> Int32 {
    guard arguments.count >= 2, let owner = validOwner(arguments[1]) else {
        throw ToolError.usage
    }
    var options = Array(arguments.dropFirst(2))
    let open = !options.contains("--no-open")
    options.removeAll { $0 == "--no-open" }
    switch arguments[0] {
    case "create":
        let names = try parseOptions(options, allowed: ["--name"])["--name"] ?? ["\(owner)-touchid"]
        guard names.count == 1, let name = names.first, !name.isEmpty, printable(name, limit: 100) == name else {
            throw ToolError.input("--name takes one App name")
        }
        return try createApp(owner: owner, name: name, openBrowser: open)
    case "set":
        return try setApp(owner: owner, options, openBrowser: open)
    case "login":
        guard options.isEmpty else {
            throw ToolError.usage
        }
        return try appLogin(owner: owner, openBrowser: open)
    default:
        throw ToolError.usage
    }
}

/// An App made by hand: its client ID, and its client secret from stdin or hidden input. It must list the callback
/// URL; the sign-in that follows is what checks the secret, and one Touch ID stores both.
private func setApp(owner: String, _ arguments: [String], openBrowser: Bool) throws -> Int32 {
    let options = try parseOptions(arguments, allowed: ["--client-id"])
    guard let values = options["--client-id"], values.count == 1,
          let clientId = values.first, !clientId.isEmpty,
          clientId.unicodeScalars.allSatisfy({ (0x21 ... 0x7E).contains($0.value) }) else {
        throw ToolError.input("app set needs --client-id with the App's client ID")
    }
    let app = AppCredentials(clientId: clientId, clientSecret: try readToken(prompt: "Client secret: "))
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
    try offerGitSetup(owner: owner)
    return 0
}

/// gh with a token narrowed from your sign-in to the owner's App, or with the token of `account`.
func runGitHub(_ arguments: [String], account: String?) throws -> Int32 {
    guard !isForbiddenGitHubCommand(arguments) else {
        let command = commandSummary(["gh"] + arguments.prefix(2))
        appendAccessLog("refused \(command) to \(processChain(getpid())): \(ToolError.forbiddenCommand)")
        throw ToolError.forbiddenCommand
    }
    let repository: String?
    do {
        // an account's token is not limited to the repository named in the dialog: no guessing which one gh acts on
        repository = try requestedRepository(arguments, exact: account != nil)
    } catch ToolError.missingRepository where account != nil {
        repository = nil // an account needs no repository, as in `gh api user` outside one
    }
    let cli = try gitHubCLI()
    let authorization = try authorizeUse(
        repository: repository,
        use: ghUse(arguments),
        account: account,
        forGit: false
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
    return try runGitHubCLI(cli, arguments: arguments, token: credential.token, relay: relay)
}

/// Git's credential-helper protocol; only Git's HTTP transport is answered.
private func gitCredential(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 1 else {
        throw ToolError.usage
    }
    switch arguments[0] {
    case "get":
        guard isatty(STDOUT_FILENO) == 0 else {
            throw ToolError.unsafeTerminalOutput
        }
        guard calledByGitTransport() else {
            appendAccessLog("refused a Git credential to \(processChain(getpid())): \(ToolError.notGitTransport)")
            throw ToolError.notGitTransport
        }
        let request = readCredentialRequest()
        guard isGitHubCredentialRequest(protocol: request["protocol"], host: request["host"]) else {
            return 0
        }
        let account = try actingAccount()
        let repository: String?
        if let path = request["path"], !path.isEmpty {
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
            forGit: true
        )
        let credential = try issueCredential(authorization)
        var lines = ["username=\(credential.username)", "password=\(credential.token)"]
        if let expires = credential.expires {
            lines.append("password_expiry_utc=\(Int(expires.timeIntervalSince1970))")
        }
        print(lines.joined(separator: "\n"))
        return 0
    case "store", "erase":
        discardStandardInput()
        return 0
    default:
        throw ToolError.usage
    }
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

/// `session [--repo <owner/name>]...`: registers the program that ran this command, for the repositories named or
/// those of the workspace here.
private func registerSession(_ arguments: [String]) throws -> Int32 {
    let options = try parseOptions(arguments, allowed: ["--repo"])
    let repositories = options["--repo"] == nil ? try workspaceRepositories() : try repositoriesOption(options)
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
    return 0
}

/// `elevate --for <duration> [--repo <owner/name>]...`: tokens for these repositories include workflows.
private func elevate(_ arguments: [String]) throws -> Int32 {
    let options = try parseOptions(arguments, allowed: ["--for", "--repo"])
    guard let durations = options["--for"], durations.count == 1 else {
        throw ToolError.input("elevate needs --for, for example --for 30m (at most 1d)")
    }
    let seconds = try parseDuration(durations[0])
    let repositories = try repositoriesOption(options)
    try authenticate(.elevation(repositories: repositories, seconds: seconds, by: requester()))
    try ensureAgent()
    let reply = agentRequest(["op": "elevate", "repos": repositories, "seconds": seconds])
    guard reply?["ok"] as? Bool == true else {
        throw ToolError.agent(reply?["error"] as? String ?? "the agent did not accept the elevation")
    }
    let until = localTime(Date().addingTimeInterval(seconds))
    fputs("Elevated \(repositories.joined(separator: ", ")) until \(until): their tokens include workflows.\n", stderr)
    return 0
}

/// Stored Apps and accounts (names only, no secret is read), whether Git and gh go through this gh-touchid, then
/// sessions and elevations.
private func showStatus() throws -> Int32 {
    let owners = try storedAppOwners()
    let logins = try storedUserLogins()
    let apps = owners.map { owner -> String in
        if let problem = formatProblem(.app(owner: owner)) ?? formatProblem(.signIn(owner: owner)) {
            return "\(owner) (\(problem))"
        }
        let signedIn = signedInLogin(owner: owner).map { "signed in as \($0)" }
        return "\(owner) (\(signedIn ?? "not signed in: gh-touchid app login \(owner)"))"
    }
    let accounts = logins.map { login in
        formatProblem(.account(login: login)).map { "\(login) (\($0))" } ?? login
    }
    print("Apps (owners): \(apps.isEmpty ? "none" : apps.joined(separator: ", "))")
    print("Accounts: \(accounts.isEmpty ? "none" : accounts.joined(separator: ", "))")
    gitStatus(owners: owners).forEach { print($0) }
    let (sessions, elevations) = agentStatus()
    if let agentProblem {
        print("Agent: \(agentProblem).")
    }
    if sessions.isEmpty && elevations.isEmpty {
        print("No sessions or elevations.")
        return 0
    }
    if !sessions.isEmpty {
        print("Sessions:")
        for session in sessions {
            let state = session.approved ? "approved" : "pending "
            let holder = session.legacy.map { " (\($0.marker))" } ?? ""
            print(
                "  \(state)  \(session.label) in \(displayFolder(session.folder)) "
                    + "(started \(clockTime(session.started))): "
                    + "\(session.repositories.joined(separator: ", "))\(holder)"
            )
        }
    }
    if !elevations.isEmpty {
        print("Elevated (tokens include workflows):")
        for elevation in elevations {
            let holder = elevation.legacy.map { " (\($0.marker))" } ?? ""
            print("  \(elevation.repository)  until \(localTime(elevation.until))\(holder)")
        }
    }
    return 0
}
