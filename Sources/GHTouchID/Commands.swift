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

    switch command {
    case "help", "--help", "-h":
        print(ToolError.usageText)
        return 0
    case "version", "--version":
        guard rest.isEmpty else {
            throw ToolError.usage
        }
        print(toolVersion)
        return 0
    case "app":
        return try appCommand(rest)
    case "user":
        return try userCommand(rest)
    case "gh":
        return try runGitHub(rest, account: actingAccount())
    case "git-setup":
        return try gitSetup(rest)
    case "git-credential":
        return try gitCredential(rest)
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
        let locked = agentRequest(["op": "lock"]) != nil
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

/// `app create <owner> [--name <name>] [--no-open]`, or `app set <owner> --client-id <id>` with the PKCS#1 key on
/// stdin.
private func appCommand(_ arguments: [String]) throws -> Int32 {
    guard arguments.count >= 2, let owner = validOwner(arguments[1]) else {
        throw ToolError.usage
    }
    switch arguments[0] {
    case "create":
        var options = Array(arguments.dropFirst(2))
        let open = !options.contains("--no-open")
        options.removeAll { $0 == "--no-open" }
        let names = try parseOptions(options, allowed: ["--name"])["--name"] ?? ["\(owner)-agent"]
        guard names.count == 1, let name = names.first, !name.isEmpty, printable(name, limit: 100) == name else {
            throw ToolError.input("--name takes one App name")
        }
        return try createApp(owner: owner, name: name, openBrowser: open)
    case "set":
        return try setApp(owner: owner, Array(arguments.dropFirst(2)))
    default:
        throw ToolError.usage
    }
}

private func setApp(owner: String, _ arguments: [String]) throws -> Int32 {
    let options = try parseOptions(arguments, allowed: ["--client-id"])
    guard let values = options["--client-id"], values.count == 1,
          let clientId = values.first, !clientId.isEmpty,
          clientId.unicodeScalars.allSatisfy({ (0x21 ... 0x7E).contains($0.value) }) else {
        throw ToolError.input("app set needs --client-id with the App's client ID")
    }
    guard isatty(STDIN_FILENO) == 0 else {
        throw ToolError.input("pipe the App's private key in: gh-touchid app set \(owner) --client-id \(clientId) < key.pem")
    }
    let pem = try readStandardInputText().trimmingCharacters(in: .whitespacesAndNewlines)
    let key = try rsaPrivateKey(pem: pem)
    try authenticate(.appKey(owner: owner))
    let app = try verifyAppKey(clientId: clientId, key: key)
    try storeAppCredentials(AppCredentials(clientId: clientId, privateKey: pem), owner: owner, slug: app.slug)
    fputs("Stored the key of the GitHub App \(app.name) for \(owner); GitHub accepted it.\n", stderr)
    // Git compares a URL's owner case-sensitively: write it as GitHub does
    try offerGitSetup(owner: app.owner.flatMap { $0.lowercased() == owner ? $0 : nil } ?? owner)
    return 0
}

/// gh with a token from the owner's App, or with the token of `account`.
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
    return 0
}

/// `elevate --for <duration> [--repo <owner/name>]...`: App tokens for these repositories include workflows.
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
    print("Apps (owners): \(owners.isEmpty ? "none" : owners.joined(separator: ", "))")
    print("Accounts: \(logins.isEmpty ? "none" : logins.joined(separator: ", "))")
    gitStatus(owners: owners).forEach { print($0) }
    let reply = agentRequest(["op": "status"])
    let sessions = (reply?["sessions"] as? [Any] ?? []).compactMap(SessionInfo.init)
    let elevations = reply?["elevations"] as? [[String: Any]] ?? []
    if sessions.isEmpty && elevations.isEmpty {
        print("No sessions or elevations.")
        return 0
    }
    if !sessions.isEmpty {
        print("Sessions:")
        for session in sessions {
            let state = session.approved ? "approved" : "pending "
            print(
                "  \(state)  \(session.label) in \(displayFolder(session.folder)) "
                    + "(started \(clockTime(session.started))): \(session.repositories.joined(separator: ", "))"
            )
        }
    }
    if !elevations.isEmpty {
        print("Elevated (tokens include workflows):")
        for elevation in elevations {
            let repository = elevation["repo"] as? String ?? "?"
            let until = Date(timeIntervalSince1970: elevation["until"] as? Double ?? 0)
            print("  \(repository)  until \(localTime(until))")
        }
    }
    return 0
}
