import Darwin
import Foundation

// The daemon (`gh-touchid agent`) remembers sessions and elevations; it holds no secrets. A session is the process
// that ran `gh-touchid session` (the daemon takes it from the socket peer, never from the message), named by pid and
// start time. A pending session is approved with Touch ID by the first client inside it that needs a token; after
// that, every process inside it gets tokens for its repositories (and issue-only tokens for others) without Touch ID
// until it exits. Clients mint the tokens themselves; the daemon only answers which session decides a caller's request
// and whether a repository is elevated. Sessions nest: an inner session never shadows an outer one that lists the
// repository asked for.
//
// `register`, `check`, `status` and `lock` are answered for any peer running as this user; `begin-approval`,
// `approve`, `deny` and `elevate` only for a peer running this very executable.

/// How long one client may hold the approval dialog of a session before another may show it.
let approvalWindow: TimeInterval = touchIDTimeout

private struct Session {
    let id: String
    let pid: pid_t
    let start: ProcessStart
    let program: String
    let folder: String
    let repositories: [String]
    var approved = false
    var approvingUntil: Date?

    var label: String {
        "\(program)[\(pid)]"
    }

    func message(now: Date) -> [String: Any] {
        [
            "id": id,
            "pid": Int(pid),
            "program": program,
            "folder": folder,
            "repos": repositories,
            "started": start.date.timeIntervalSince1970,
            "state": approved ? "approved" : "pending",
            "approving": (approvingUntil ?? .distantPast) > now,
        ]
    }
}

private final class SessionAgent: @unchecked Sendable {
    private var sessions: [pid_t: Session] = [:]
    private var elevations: [String: Date] = [:]
    private var sources: [DispatchSourceProtocol] = []
    private let listener: Int32
    private let executable: String
    private let started = Date()

    init(listener: Int32, executable: String) {
        self.listener = listener
        self.executable = executable
    }

    func start() {
        let accepting = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        accepting.setEventHandler { [self] in
            let client = accept(listener, nil, nil)
            if client >= 0 {
                handle(client)
                close(client)
            }
        }
        accepting.resume()

        let ticking = DispatchSource.makeTimerSource(queue: .main)
        ticking.schedule(deadline: .now() + 5, repeating: 5)
        ticking.setEventHandler { [self] in tick() }
        ticking.resume()

        signal(SIGHUP, SIG_IGN)
        sources = [accepting, ticking]
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let stopping = DispatchSource.makeSignalSource(signal: number, queue: .main)
            stopping.setEventHandler { [self] in finish("stopped by signal \(number)") }
            stopping.resume()
            sources.append(stopping)
        }
    }

    private func handle(_ client: Int32) {
        configureSocket(client, timeoutSeconds: 2)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), let peer = peerProcess(client) else {
            return
        }
        let who = processChain(peer)
        guard let line = readMessage(client),
              let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let operation = request["op"] as? String else {
            _ = sendMessage(client, ["error": "bad request"])
            return
        }

        let reply: [String: Any]
        switch operation {
        case "register":
            reply = register(request, peer: peer, who: who)
        case "check":
            reply = check(request, peer: peer)
        case "status":
            reply = status()
        case "lock":
            _ = sendMessage(client, ["ok": true])
            finish("locked by \(who)")
        case "begin-approval", "approve", "deny", "elevate":
            guard executablePath(peer) == executable else {
                appendAccessLog("refused \(operation) to \(who): not this gh-touchid executable")
                reply = ["error": "only \(executable) may \(operation)"]
                break
            }
            switch operation {
            case "begin-approval":
                reply = beginApproval(request, peer: peer)
            case "approve":
                reply = approve(request, peer: peer, who: who)
            case "deny":
                reply = deny(request, peer: peer)
            default:
                reply = elevate(request, who: who)
            }
        default:
            reply = ["error": "unknown request"]
        }
        _ = sendMessage(client, reply)
    }

    private func register(_ request: [String: Any], peer: pid_t, who: String) -> [String: Any] {
        let repositories = normalizedRepositories(request["repos"])
        guard !repositories.isEmpty else {
            return ["error": "a session needs at least one owner/name repository"]
        }
        // the session is whoever started `gh-touchid session`
        guard let root = parentProcess(peer), root > 1, let start = processStart(root) else {
            return ["error": "the caller has no parent process to register"]
        }
        let now = Date()
        if let existing = sessions[root], existing.start == start, existing.repositories == repositories {
            let state = existing.approved ? "approved" : "pending"
            appendAccessLog("session \(existing.label) registered again (\(state)) by \(who)")
            return ["session": existing.message(now: now)]
        }
        let session = Session(
            id: UUID().uuidString,
            pid: root,
            start: start,
            program: processName(root),
            folder: folder(request["folder"]),
            repositories: repositories
        )
        sessions[root] = session
        appendAccessLog(
            "session registered: \(session.label) in \(session.folder) for "
                + "\(repositories.joined(separator: ", ")) (pending) by \(who)"
        )
        return ["session": session.message(now: now)]
    }

    /// `check {repo}`: the session that decides the caller's request for `repo`; `check {session}`: that session, while
    /// it is live and at or above the caller (how a client waits for another one's approval dialog). `covers` says
    /// whether the session lists `repo`.
    private func check(_ request: [String: Any], peer: pid_t) -> [String: Any] {
        let repository = (request["repo"] as? String).flatMap(validRepository)?.lowercased()
        var reply: [String: Any] = ["elevated": repository.map(isElevated) ?? false]
        let session = request["session"] != nil
            ? sessionAbove(peer, id: request["session"])
            : deciding(repository, for: peer)
        if let session {
            reply["session"] = session.message(now: Date())
            reply["covers"] = repository.map { session.repositories.contains($0) } ?? false
        }
        return reply
    }

    private func beginApproval(_ request: [String: Any], peer: pid_t) -> [String: Any] {
        guard var session = sessionAbove(peer, id: request["session"]) else {
            return ["error": "no such session above the caller"]
        }
        if session.approved {
            return ["state": "approved"]
        }
        let now = Date()
        if let until = session.approvingUntil, until > now {
            return ["lease": false]
        }
        session.approvingUntil = now.addingTimeInterval(approvalWindow)
        sessions[session.pid] = session
        return ["lease": true]
    }

    private func approve(_ request: [String: Any], peer: pid_t, who: String) -> [String: Any] {
        guard var session = sessionAbove(peer, id: request["session"]) else {
            return ["error": "no such session above the caller"]
        }
        session.approved = true
        session.approvingUntil = nil
        sessions[session.pid] = session
        appendAccessLog(
            "session approved: \(session.label) for \(session.repositories.joined(separator: ", ")) by \(who)"
        )
        return ["ok": true]
    }

    private func deny(_ request: [String: Any], peer: pid_t) -> [String: Any] {
        guard var session = sessionAbove(peer, id: request["session"]) else {
            return ["error": "no such session above the caller"]
        }
        session.approvingUntil = nil
        sessions[session.pid] = session
        let reason = printable(request["reason"] as? String ?? "no reason")
        appendAccessLog("session not approved: \(session.label): \(reason)")
        return ["ok": true]
    }

    private func elevate(_ request: [String: Any], who: String) -> [String: Any] {
        let repositories = normalizedRepositories(request["repos"])
        guard !repositories.isEmpty,
              let seconds = request["seconds"] as? Double, seconds > 0, seconds <= longestElevation else {
            return ["error": "elevate needs repositories and at most 1d"]
        }
        let until = Date().addingTimeInterval(seconds)
        for repository in repositories {
            elevations[repository] = until
            appendAccessLog("elevated \(repository) until \(localTime(until)) by \(who)")
        }
        return ["ok": true]
    }

    private func status() -> [String: Any] {
        let now = Date()
        dropEnded(now: now)
        return [
            "sessions": sessions.values.sorted { $0.pid < $1.pid }.map { $0.message(now: now) },
            "elevations": elevations.sorted { $0.key < $1.key }.map { repository, until -> [String: Any] in
                ["repo": repository, "until": until.timeIntervalSince1970]
            },
        ]
    }

    /// Among the live sessions at or above `pid`: the nearest approved one that lists `repository`, else the nearest
    /// pending one that lists it, else the nearest approved one, else the nearest pending one.
    private func deciding(_ repository: String?, for pid: pid_t) -> Session? {
        let live = lineage(pid).compactMap { ancestor -> Session? in
            guard let session = sessions[ancestor], processStart(ancestor) == session.start else {
                return nil
            }
            return session
        }
        let listing = live.filter { session in repository.map { session.repositories.contains($0) } ?? false }
        return listing.first(where: \.approved) ?? listing.first ?? live.first(where: \.approved) ?? live.first
    }

    /// The session with `id`, when it is live and at or above `pid`.
    private func sessionAbove(_ pid: pid_t, id: Any?) -> Session? {
        guard let id = id as? String,
              let session = sessions.values.first(where: { $0.id == id }),
              lineage(pid).contains(session.pid),
              processStart(session.pid) == session.start else {
            return nil
        }
        return session
    }

    private func isElevated(_ repository: String) -> Bool {
        (elevations[repository] ?? .distantPast) > Date()
    }

    private func tick() {
        let now = Date()
        dropEnded(now: now)
        // a fresh agent waits a little for the request that started it
        if sessions.isEmpty && elevations.isEmpty && now.timeIntervalSince(started) > 30 {
            finish("nothing left")
        }
    }

    /// Forgets sessions whose root process is gone and elevations that ran out.
    private func dropEnded(now: Date) {
        for (pid, session) in sessions where processStart(pid) != session.start {
            sessions.removeValue(forKey: pid)
            appendAccessLog("session ended: \(session.label) (\(session.repositories.joined(separator: ", ")))")
        }
        for (repository, until) in elevations where until <= now {
            elevations.removeValue(forKey: repository)
            appendAccessLog("elevation expired: \(repository)")
        }
    }

    private func finish(_ reason: String) -> Never {
        appendAccessLog("agent stopped: \(reason)")
        unlink(agentSocketPath)
        exit(0)
    }
}

/// Valid `owner/name` repositories, lowercase, unique and sorted.
private func normalizedRepositories(_ value: Any?) -> [String] {
    let names = (value as? [String] ?? []).compactMap(validRepository).map { $0.lowercased() }
    return Array(Set(names)).sorted()
}

/// The folder a session reports for itself, when it is an existing directory; it is shown in dialogs.
private func folder(_ value: Any?) -> String {
    var isDirectory: ObjCBool = false
    guard let path = value as? String, path.hasPrefix("/"), printable(path, limit: 300) == path,
          FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return "an unknown folder"
    }
    return path
}

func runAgent() throws -> Never {
    guard let executable = ownExecutablePath else {
        throw ToolError.agent("cannot find gh-touchid's own executable")
    }
    try ensureSessionDirectory()
    if agentRequest(["op": "status"]) != nil {
        exit(0) // another agent is already serving
    }
    unlink(agentSocketPath)
    var address = try socketAddress(agentSocketPath)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else {
        throw ToolError.agent("cannot create a socket")
    }
    let previous = umask(0o077)
    let bound = withSocketAddress(&address) { bind(listener, $0, $1) }
    umask(previous)
    guard bound == 0, listen(listener, 16) == 0 else {
        throw ToolError.agent("cannot listen on \(agentSocketPath)")
    }

    let agent = SessionAgent(listener: listener, executable: executable)
    agent.start()
    appendAccessLog("agent started")
    dispatchMain()
}

/// Start the agent as its own session, detached from the terminal, with no inherited input, output or environment.
private func spawnAgent() throws {
    guard let executable = ownExecutablePath else {
        throw ToolError.agent("cannot find gh-touchid's own executable")
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("agent"), nil]
    defer { argv.forEach { free($0) } }
#if GH_TOUCHID_TESTING
    let inherited = ["GH_TOUCHID_TEST_DIR=\(testDirectory)"]
#else
    let inherited: [String] = []
#endif
    var environment: [UnsafeMutablePointer<CChar>?] = inherited.map { strdup($0) } + [nil]
    defer { environment.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment)
    guard status == 0 else {
        throw ToolError.agent("cannot start the agent: \(String(cString: strerror(status)))")
    }
}

func ensureAgent() throws {
    if agentRequest(["op": "status"]) != nil {
        return
    }
    try ensureSessionDirectory()
    try spawnAgent()
    for _ in 0 ..< 50 {
        if agentRequest(["op": "status"]) != nil {
            return
        }
        usleep(100_000)
    }
    throw ToolError.agent("the agent did not start")
}
