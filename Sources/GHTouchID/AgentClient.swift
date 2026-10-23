import Darwin
import Foundation

// The client's side of the agent. Every reply is acted on only when the agent is a gh-touchid this one trusts
// (`identifyPeer`): this very executable, an earlier release on the built-in list, or a newer release. A revoked
// release is locked and nothing it held is carried over; anything else holding the socket is left alone. Either way
// the command goes on without a session, so each use asks for Touch ID.

/// What keeps the agent from being used for the rest of this command, once found; said on stderr once.
private(set) var agentProblem: String?

private func reportAgentProblem(_ problem: String) {
    guard agentProblem == nil else {
        return
    }
    agentProblem = problem
    fputs("gh-touchid: \(problem)\n", stderr)
}

/// Leaves alone the program holding the agent's socket that is not a gh-touchid this one trusts: says so on stderr
/// and in the access log, once per command.
private func reportUntrustedHolder(_ holder: String, _ peer: PeerIdentity) {
    guard agentProblem == nil else {
        return
    }
    let socket = (agentSocketPath as NSString).lastPathComponent
    appendAccessLog("refused the agent at \(socket) held by \(holder): \(peer.reason)")
    reportAgentProblem(
        "\(holder) holds \(socket) but is not a gh-touchid this one trusts (\(peer.reason)); "
            + "no session applies, so each use asks for Touch ID"
    )
}

/// `request` with the protocol and version every request to the agent carries.
private func versioned(_ request: [String: Any]) -> [String: Any] {
    request.merging(["protocol": agentProtocol, "version": toolVersion]) { _, new in new }
}

/// Whether `reply` is the agent's refusal of a request in a protocol it does not speak.
private func isProtocolRefusal(_ reply: [String: Any]) -> Bool {
    reply["error"] as? String == "protocol"
}

private func reportProtocolRefusal(_ reply: [String: Any]) {
    let version = printable(reply["version"] as? String ?? "unknown", limit: 40)
    reportAgentProblem(
        "the background program (gh-touchid \(version)) does not speak protocol \(agentProtocol); "
            + "no session applies, so each use asks for Touch ID"
    )
}

/// The agent's reply to `request`; nil when no agent this one trusts answers.
func agentRequest(_ request: [String: Any]) -> [String: Any]? {
    agentRequest(request, takingOver: true)
}

private func agentRequest(_ request: [String: Any], takingOver: Bool) -> [String: Any]? {
    guard agentProblem == nil else {
        return nil
    }
    switch exchange(agentSocketPath, versioned(request), accepts: \.isTrusted) {
    case let .answered(reply, _):
        guard !isProtocolRefusal(reply) else {
            reportProtocolRefusal(reply)
            return nil
        }
        return reply
    case .absent, .failed:
        return nil
    case let .rejected(.revoked(version), holder) where takingOver:
        takeOverRevokedAgent(version: version, holder: holder)
        return agentRequest(request, takingOver: false)
    case let .rejected(peer, holder):
        reportUntrustedHolder(holder, peer)
        return nil
    }
}

/// Starts an agent unless one this gh-touchid trusts already answers.
func ensureAgent() throws {
    if agentRequest(["op": "status"]) != nil {
        return
    }
    if let agentProblem {
        throw ToolError.agent(agentProblem)
    }
    try startAgent()
}

/// Starts an agent and waits until one this gh-touchid trusts answers. An agent started while another still holds
/// the socket (a revoked one on its way out) leaves at once; then it is started again.
private func startAgent() throws {
    try ensureSessionDirectory()
    var started = try spawnAgent()
    for _ in 0 ..< 50 {
        switch exchange(agentSocketPath, versioned(["op": "status"]), accepts: \.isTrusted) {
        case let .answered(reply, _):
            guard !isProtocolRefusal(reply) else {
                reportProtocolRefusal(reply)
                throw ToolError.agent(agentProblem ?? "the agent does not speak this gh-touchid's protocol")
            }
            return
        case let .rejected(peer, holder) where !peer.isRevoked:
            reportUntrustedHolder(holder, peer)
            throw ToolError.agent(agentProblem ?? "\(holder) holds the agent's socket")
        case .absent:
            var status: Int32 = 0
            if waitpid(started, &status, WNOHANG) == started {
                started = try spawnAgent()
            }
        default:
            break
        }
        usleep(100_000)
    }
    throw ToolError.agent("the agent did not start")
}

/// Start the agent as its own session, detached from the terminal, with no inherited input, output or environment.
private func spawnAgent() throws -> pid_t {
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
    var inherited = ["GH_TOUCHID_TEST_DIR=\(testDirectory)"]
    if let requirement = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_PEER_REQUIREMENT"] {
        inherited.append("GH_TOUCHID_TEST_PEER_REQUIREMENT=\(requirement)")
    }
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
    return pid
}

/// A revoked release holds agent.sock: lock it, so that nothing goes on its word any more. Nothing it held is carried
/// over, neither sessions nor elevations: a revoked release's account of them is not to be trusted, and a session is
/// registered only by a program inside it. Until each runs `gh-touchid session` again, its uses ask for Touch ID.
/// Clients that meet it at once each send it `lock`; the first ends it.
private func takeOverRevokedAgent(version: String, holder: String) {
    let revoked: (PeerIdentity) -> Bool = { $0.isRevoked }
    if case .answered = exchange(agentSocketPath, versioned(["op": "lock"]), accepts: revoked) {
        appendAccessLog("revoked agent locked: gh-touchid \(version) at \(holder)")
    }
    for _ in 0 ..< 50 {
        guard let fd = connectSocket(agentSocketPath, timeoutSeconds: 1) else {
            break
        }
        let code = examinePeer(fd)
        close(fd)
        guard case let .decided(peer) = code, peer.isRevoked else {
            break
        }
        usleep(100_000)
    }
    fputs(
        "gh-touchid: the background program of gh-touchid \(version) was revoked and has been stopped, ending its "
            + "sessions; run `gh-touchid session` again in each program to approve it once.\n",
        stderr
    )
}

/// Whether tokens for `repository` include workflows now: elevated in the agent, or in any agent of 0.4.0/0.4.1 on
/// the built-in list as trusted. An elevation is the repository's, whichever session (or none) a use goes through, as
/// it was in those releases; `status` lists them the same way.
func isElevated(_ repository: String) -> Bool {
    if agentRequest(["op": "check", "repo": repository])?["elevated"] as? Bool == true {
        return true
    }
    return legacySockets().contains { socket in
        legacyRequest(socket, ["op": "check", "repo": repository], accepts: isOlderRelease)?.0["elevated"] as? Bool
            == true
    }
}

/// Ends every session and elevation: in the agent (one this gh-touchid trusts, or a revoked one) and in every agent
/// of 0.4.0/0.4.1 on the built-in list. Whether any agent was locked.
func lockAgents() -> Bool {
    var locked = false
    let lockable: (PeerIdentity) -> Bool = { $0.isTrusted || $0.isRevoked }
    switch exchange(agentSocketPath, versioned(["op": "lock"]), accepts: lockable) {
    case let .answered(reply, _):
        if isProtocolRefusal(reply) {
            reportProtocolRefusal(reply)
        } else {
            locked = reply["ok"] as? Bool == true
        }
    case let .rejected(peer, holder):
        reportUntrustedHolder(holder, peer)
    case .absent, .failed:
        break
    }
    for socket in legacySockets() where legacyRequest(socket, ["op": "lock"], accepts: isLegacyRelease) != nil {
        locked = true
    }
    return locked
}

/// Sessions and elevations, of the agent and of every agent of 0.4.0/0.4.1 on the built-in list.
func agentStatus() -> (sessions: [SessionInfo], elevations: [Elevation]) {
    let reply = agentRequest(["op": "status"])
    var sessions = (reply?["sessions"] as? [Any] ?? []).compactMap(SessionInfo.init)
    var elevations = (reply?["elevations"] as? [Any] ?? []).compactMap { Elevation($0, legacy: nil) }
    for socket in legacySockets() {
        guard case let (held, legacy)? = legacyRequest(socket, ["op": "status"], accepts: isLegacyRelease) else {
            continue
        }
        sessions += (held["sessions"] as? [Any] ?? []).compactMap(SessionInfo.init).map { session in
            var session = session
            session.legacy = legacy
            return session
        }
        elevations += (held["elevations"] as? [Any] ?? []).compactMap { Elevation($0, legacy: legacy) }
    }
    return (sessions, elevations)
}

/// An elevation as an agent reports it.
struct Elevation {
    let repository: String
    let until: Date
    /// The agent of 0.4.0/0.4.1 that holds it; nil for the agent's own.
    let legacy: LegacyAgent?

    init?(_ message: Any?, legacy: LegacyAgent?) {
        guard let message = message as? [String: Any],
              let repository = message["repo"] as? String,
              let until = message["until"] as? Double else {
            return nil
        }
        self.repository = repository
        self.until = Date(timeIntervalSince1970: until)
        self.legacy = legacy
    }
}

// Moving off 0.4.0 and 0.4.1, whose agents listen at sockets named after their executable's path and speak no
// protocol version: builds that share agent.sock also ask them for approved sessions, and `lock` and `status` reach
// them. This transition code can be deleted once 0.4.0 and 0.4.1 leave the built-in list.

/// An agent of 0.4.0 or 0.4.1 on the built-in list.
struct LegacyAgent {
    let socket: String
    let version: String
    let revoked: Bool

    /// How `status` marks what it holds.
    var marker: String {
        "gh-touchid \(version)\(revoked ? ", revoked" : "")"
    }
}

private func isOlderRelease(_ peer: PeerIdentity) -> Bool {
    if case .older = peer {
        return true
    }
    return false
}

private func isLegacyRelease(_ peer: PeerIdentity) -> Bool {
    switch peer {
    case .older, .revoked:
        return true
    case .same, .newer, .untrusted:
        return false
    }
}

/// The sockets of agents named after their executable's path (0.4.0, 0.4.1 and development builds), in builds that
/// share agent.sock.
private func legacySockets() -> [String] {
    guard sharesAgentSocket, let names = try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory) else {
        return []
    }
    return names.filter { name in
        name.count == 27 && name.hasPrefix("agent-") && name.hasSuffix(".sock")
            && name.dropFirst(6).prefix(16).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }.sorted().map { (sessionDirectory as NSString).appendingPathComponent($0) }
}

/// `request`, exactly as 0.4.1 sends it, to the agent at `socket` when `accepts` takes it, with that agent.
private func legacyRequest(
    _ socket: String,
    _ request: [String: Any],
    accepts: (PeerIdentity) -> Bool
) -> ([String: Any], LegacyAgent)? {
    guard case let .answered(reply, peer) = exchange(socket, request, accepts: accepts) else {
        return nil
    }
    switch peer {
    case let .older(version):
        return (reply, LegacyAgent(socket: socket, version: version, revoked: false))
    case let .revoked(version):
        return (reply, LegacyAgent(socket: socket, version: version, revoked: true))
    case .same, .newer, .untrusted:
        return nil
    }
}

/// The approved session of an agent of 0.4.0/0.4.1 on the built-in list (trusted, not revoked) that lists
/// `repository` and decides for this process; pending ones are left to that release.
func legacyApprovedSession(covering repository: String) -> SessionInfo? {
    for socket in legacySockets() {
        let request: [String: Any] = ["op": "check", "repo": repository]
        guard case let (reply, legacy)? = legacyRequest(socket, request, accepts: isOlderRelease),
              var session = SessionInfo(reply["session"]), session.approved,
              reply["covers"] as? Bool == true else {
            continue
        }
        session.legacy = legacy
        return session
    }
    return nil
}
