import Foundation

// `status`, which reads names only (no secret), and `setup`, which does what is missing for each owner: the App, the
// sign-in, Git, and the public reader. Without a terminal, or with --no-input, `setup` does only what needs no browser
// (Git) and fails listing the commands for the rest.

private let problemSchema = Schema.nullable(.string(description: "What keeps gh-touchid from reading the item."))
private let nullableText = Schema.nullable(.string())

/// `status`.
let statusOperation = Operation(
    name: "status",
    words: ["status"],
    title: "What is stored and set up",
    description: "`status` lists stored Apps with who is signed in to each, your accounts, the public reader, "
        + "whether Git goes through this gh-touchid for each owner, which `gh` comes first on PATH (and how to put "
        + "this gh-touchid's first), whether another gh is signed in, and sessions and elevations. It reads no "
        + "secret.",
    example: "gh-touchid status --json",
    positional: [],
    input: objectSchema([]),
    output: objectSchema([
        ("apps", .array(objectSchema([
            ("owner", ownerSchema),
            ("login", .nullable(.string(description: "Who is signed in to the owner's App."))),
            ("problem", problemSchema),
        ], required: ["owner", "login", "problem"]), description: "Owners with a stored App.")),
        ("accounts", .array(objectSchema([
            ("login", ownerSchema),
            ("problem", problemSchema),
        ], required: ["login", "problem"]), description: "Your accounts with a stored token.")),
        ("reader", .nullable(objectSchema([
            ("app", .string(description: "The reader App's slug.")),
            ("owner", .string(description: "The account it is installed on.")),
            ("problem", .string(description: "What keeps gh-touchid from reading the item.")),
        ], required: ["app", "owner"], description: "The public reader, null when none is stored."))),
        ("git", .array(objectSchema([
            ("owner", .string(description: "The owner, as the Git configuration writes it.")),
            ("asked", .nullable(.array(.string(), description: "The credential helpers Git asks; null when Git "
                + "cannot be asked."))),
            ("fixes", .array(.string(), description: "Commands that make Git ask this gh-touchid alone.")),
        ], required: ["owner", "asked", "fixes"]), description: "Git, for each owner with a stored App.")),
        ("gh", objectSchema([
            ("first", nullableText),
            ("wrapper", nullableText),
            ("is_wrapper", .boolean()),
            ("path_folder", nullableText),
            ("alias_command", nullableText),
            ("signed_in", .nullable(.string(description: "The login another gh is signed in as (\"\" when it "
                + "cannot be told)."))),
        ], required: ["first", "wrapper", "is_wrapper", "path_folder", "alias_command", "signed_in"],
        description: "The gh first on PATH, this installation's wrapper, and the fix when it is not first.")),
        ("agent", .nullable(.string(description: "What keeps the agent from being used."))),
        ("sessions", .array(objectSchema([
            ("program", .string()),
            ("pid", .integer()),
            ("folder", .string()),
            ("repositories", .array(.string())),
            ("started", .string(description: "ISO 8601.")),
            ("approved", .boolean()),
            ("holder", .nullable(.string(description: "The older gh-touchid whose agent holds it.")))
        ], required: ["program", "pid", "folder", "repositories", "started", "approved", "holder"]))),
        ("elevations", .array(objectSchema([
            ("repository", .string()),
            ("until", .string(description: "ISO 8601.")),
            ("holder", .nullable(.string(description: "The older gh-touchid whose agent holds it.")))
        ], required: ["repository", "until", "holder"]))),
    ], required: ["apps", "accounts", "reader", "git", "gh", "agent", "sessions", "elevations"]),
    annotations: Annotations(readOnly: true, destructive: false, idempotent: true, openWorld: false),
    run: { _, _ in try currentStatus() },
    text: statusText
)

/// Stored Apps and accounts (names only, no secret is read), the reader, whether Git and gh go through this
/// gh-touchid, then sessions and elevations.
private func currentStatus() throws -> [String: Any] {
    let owners = try storedAppOwners()
    let apps = owners.map { owner -> [String: Any] in
        let problem = formatProblem(.app(owner: owner)) ?? formatProblem(.signIn(owner: owner))
        return [
            "owner": owner,
            "login": problem == nil ? nullable(signedInLogin(owner: owner)) : NSNull(),
            "problem": nullable(problem),
        ]
    }
    let accounts = try storedUserLogins().map { login -> [String: Any] in
        ["login": login, "problem": nullable(formatProblem(.account(login: login)))]
    }
    let git = owners.map { ownerGitStatus($0).output }
    let gh = gitHubCLIStatus()
    let (sessions, elevations) = agentStatus()
    let format = ISO8601DateFormatter()
    return [
        "apps": apps,
        "accounts": accounts,
        "reader": nullable(readerStatus()),
        "git": git,
        "gh": gh,
        "agent": nullable(agentProblem),
        "sessions": sessions.map { session -> [String: Any] in
            [
                "program": session.program,
                "pid": session.pid,
                "folder": session.folder,
                "repositories": session.repositories,
                "started": format.string(from: session.started),
                "approved": session.approved,
                "holder": nullable(session.legacy?.marker),
            ]
        },
        "elevations": elevations.map { elevation -> [String: Any] in
            [
                "repository": elevation.repository,
                "until": format.string(from: elevation.until),
                "holder": nullable(elevation.legacy?.marker),
            ]
        },
    ]
}

/// The text `status` prints, from its output.
private func statusText(_ output: [String: Any]) -> String {
    var lines: [String] = []
    let apps = (output["apps"] as? [[String: Any]] ?? []).map { app -> String in
        let owner = app["owner"] as? String ?? ""
        if let problem = app["problem"] as? String {
            return "\(owner) (\(problem))"
        }
        let signedIn = (app["login"] as? String).map { "signed in as \($0)" }
        return "\(owner) (\(signedIn ?? "not signed in: gh-touchid app login \(owner)"))"
    }
    let accounts = (output["accounts"] as? [[String: Any]] ?? []).map { account -> String in
        let login = account["login"] as? String ?? ""
        return (account["problem"] as? String).map { "\(login) (\($0))" } ?? login
    }
    lines.append("Apps (owners): \(apps.isEmpty ? "none" : apps.joined(separator: ", "))")
    lines.append("Accounts: \(accounts.isEmpty ? "none" : accounts.joined(separator: ", "))")
    if let reader = output["reader"] as? [String: Any] {
        let problem = (reader["problem"] as? String).map { " (\($0))" } ?? ""
        lines.append("Reader: \(reader["app"] as? String ?? "") on \(reader["owner"] as? String ?? "")\(problem)")
    } else {
        lines.append("Reader: none")
    }
    lines += (output["git"] as? [[String: Any]] ?? []).map(OwnerGitStatus.line)
    lines += gitHubCLIStatusLines(output["gh"] as? [String: Any] ?? [:])
    if let problem = output["agent"] as? String {
        lines.append("Agent: \(problem).")
    }
    let sessions = output["sessions"] as? [[String: Any]] ?? []
    let elevations = output["elevations"] as? [[String: Any]] ?? []
    if sessions.isEmpty && elevations.isEmpty {
        lines.append("No sessions or elevations.")
        return lines.joined(separator: "\n")
    }
    let format = ISO8601DateFormatter()
    func date(_ value: Any?) -> Date {
        (value as? String).flatMap(format.date) ?? Date(timeIntervalSince1970: 0)
    }
    func holder(_ value: Any?) -> String {
        (value as? String).map { " (\($0))" } ?? ""
    }
    if !sessions.isEmpty {
        lines.append("Sessions:")
        for session in sessions {
            let state = session["approved"] as? Bool == true ? "approved" : "pending "
            let label = "\(session["program"] as? String ?? "")[\(session["pid"] as? Int ?? 0)]"
            let folder = displayFolder(session["folder"] as? String ?? "")
            let repositories = (session["repositories"] as? [String] ?? []).joined(separator: ", ")
            lines.append(
                "  \(state)  \(label) in \(folder) (started \(clockTime(date(session["started"])))): "
                    + "\(repositories)\(holder(session["holder"]))"
            )
        }
    }
    if !elevations.isEmpty {
        lines.append("Elevated (tokens include workflows):")
        for elevation in elevations {
            let repository = elevation["repository"] as? String ?? ""
            lines.append("  \(repository)  until \(localTime(date(elevation["until"])))\(holder(elevation["holder"]))")
        }
    }
    return lines.joined(separator: "\n")
}

/// `setup`.
let setupOperation = Operation(
    name: "setup",
    words: ["setup"],
    title: "Set up what is missing",
    description: "`setup` does what is missing for each owner named (by default each owner with a stored App): "
        + "creates its App, signs you in, sets up Git; then stores the public reader unless one is stored, and "
        + "says whether this gh-touchid's gh comes first on PATH. Without a terminal, or with --no-input, it does "
        + "only what needs no browser (Git) and fails listing the commands for the rest.",
    example: "gh-touchid setup acme",
    positional: ["owners"],
    input: objectSchema([
        ("owners", .array(ownerSchema, description: "The owners; by default each owner with a stored App.")),
    ]),
    output: objectSchema([
        ("steps", .array(objectSchema([
            ("step", .string(enumValues: ["gh_path", "app", "sign_in", "git", "reader"])),
            ("owner", .string()),
            ("state", .string(enumValues: ["done", "already", "needed"])),
            ("command", .string(description: "What to run for a step that is needed.")),
        ], required: ["step", "state"]))),
    ], required: ["steps"]),
    annotations: Annotations(readOnly: false, destructive: false, idempotent: true, openWorld: true),
    run: { context, input in try setUp(owners: input["owners"] as? [String], context: context) },
    text: { output in
        (output["steps"] as? [[String: Any]] ?? []).map { step -> String in
            let state = (step["state"] as? String ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
            let owner = (step["owner"] as? String).map { " \($0)" } ?? ""
            let command = (step["command"] as? String).map { ": \($0)" } ?? ""
            return "\(state)\(step["step"] as? String ?? "")\(owner)\(command)"
        }.joined(separator: "\n")
    }
)

/// The steps of `setup`, each done, already done, or needed with its command.
private func setUp(owners named: [String]?, context: OperationContext) throws -> [String: Any] {
    var steps: [[String: Any]] = []
    var needed: [String] = []
    func record(_ step: String, _ owner: String?, _ state: String, command: String? = nil) {
        var entry: [String: Any] = ["step": step, "state": state]
        entry["owner"] = owner
        entry["command"] = command
        steps.append(entry)
    }
    func run(_ name: String, _ input: [String: Any]) throws {
        guard let found = operation(named: name) else {
            throw ToolError.input("this gh-touchid has no \(name)")
        }
        _ = try found.run(context, input)
    }
    let interactive = !context.noInput

    // advice only: a shell profile is the user's to change
    let gh = gitHubCLIOnPath()
    if gh.wrapper != nil {
        if gh.isWrapper {
            record("gh_path", nil, "already")
        } else {
            record("gh_path", nil, "needed", command: "export PATH=\"\(gh.folder ?? ""):$PATH\"")
        }
    }

    for typed in try named ?? storedAppOwners() {
        guard let owner = validOwner(typed) else {
            throw ToolError.input("owners takes GitHub account names")
        }
        var hasApp = hasAppCredentials(owner: owner)
        if hasApp {
            record("app", owner, "already")
        } else if interactive {
            context.progress("Creating the GitHub App for \(owner).")
            try run("app_create", ["owner": typed, "git_setup": false])
            record("app", owner, "done")
            hasApp = true
        } else {
            let command = "gh-touchid app create \(typed)"
            record("app", owner, "needed", command: command)
            needed.append(command)
        }
        if hasApp {
            if signedInLogin(owner: owner) != nil {
                record("sign_in", owner, "already")
            } else if interactive {
                context.progress("Signing in to the GitHub App for \(owner).")
                try run("app_login", ["owner": typed])
                record("sign_in", owner, "done")
            } else {
                let command = "gh-touchid app login \(typed)"
                record("sign_in", owner, "needed", command: command)
                needed.append(command)
            }
        }
        if ownerGitStatus(owner).isThisOnly {
            record("git", owner, "already")
        } else {
            _ = try setUpGit(owner: typed)
            record("git", owner, "done")
        }
    }

    if hasReader() {
        record("reader", nil, "already")
    } else if interactive {
        context.progress("Creating the public reader.")
        try run("reader_create", [:])
        record("reader", nil, "done")
    } else {
        let command = "gh-touchid reader create"
        record("reader", nil, "needed", command: command)
        needed.append(command)
    }
    guard needed.isEmpty else {
        throw ToolError.inputNeeded(needed.joined(separator: "; "))
    }
    return ["steps": steps]
}
