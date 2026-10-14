import Darwin
import Foundation

// Who gets a token for repository R, decided by the client that needs it:
// 1. GH_TOUCHID_AS=me: Touch ID for this use, then your own token for R's owner.
// 2. Inside an approved session that lists R: a token from the App without Touch ID.
// 3. Inside a pending session that lists R: one Touch ID approves the session, then as 2.
// 4. Anything else: Touch ID naming the command and who asked, then one token from the App.
// App tokens include `workflows` only if R is elevated when the token is minted, which is after any dialog.
// Every outcome is logged with the process chain.

struct GitHubCredential {
    let token: String
    /// When an App token expires; nil for your own token, which is neither revoked nor expires here.
    let expires: Date?
}

/// A session as the daemon reports it.
struct SessionInfo {
    let id: String
    let pid: Int
    let program: String
    let folder: String
    let repositories: [String]
    let started: Date
    let approved: Bool
    let approving: Bool

    init?(_ message: Any?) {
        guard let message = message as? [String: Any],
              let id = message["id"] as? String,
              let pid = message["pid"] as? Int,
              let program = message["program"] as? String,
              let folder = message["folder"] as? String,
              let repositories = message["repos"] as? [String],
              let started = message["started"] as? Double,
              let state = message["state"] as? String else {
            return nil
        }
        self.id = id
        self.pid = pid
        self.program = program
        self.folder = folder
        self.repositories = repositories
        self.started = Date(timeIntervalSince1970: started)
        approved = state == "approved"
        approving = message["approving"] as? Bool ?? false
    }

    var label: String {
        "\(program)[\(pid)]"
    }

    func covers(_ repository: String) -> Bool {
        repositories.contains(repository.lowercased())
    }
}

/// Whether the caller asked to act as you (GH_TOUCHID_AS=me) rather than as the owner's App.
func actingAsOwner() throws -> Bool {
    guard let value = ProcessInfo.processInfo.environment["GH_TOUCHID_AS"], !value.isEmpty else {
        return false
    }
    guard value == "me" else {
        throw ToolError.input("GH_TOUCHID_AS takes only `me`")
    }
    return true
}

/// A use of a repository that Touch ID or a session allowed; the token is issued separately, right after.
struct Authorization {
    let repository: String
    let asOwner: Bool
    /// `you`, `session prog[pid]` or `once`, for the log.
    let grant: String
    let chain: String
}

/// Touch ID or session approval for one use of `repository` by `command` (shown in Touch ID dialogs).
func authorizeUse(repository: String, command: String, asOwner: Bool) throws -> Authorization {
    let chain = processChain(getpid())
    do {
        if asOwner {
            try authenticate(reason: "run \(command) as you on \(repository)")
            return Authorization(repository: repository, asOwner: true, grant: "you", chain: chain)
        }

        let grant: String
        if let session = SessionInfo(agentRequest(["op": "check", "repo": repository])?["session"]),
           session.covers(repository) {
            if !session.approved {
                try awaitApproval(of: session)
            }
            grant = "session \(session.label)"
        } else {
            try authenticate(
                reason: "use GitHub for \(repository): \(command) (asked by \(processChain(getppid())))"
            )
            grant = "once"
        }
        return Authorization(repository: repository, asOwner: false, grant: grant, chain: chain)
    } catch {
        appendAccessLog("refused \(repository) to \(chain): \(error)")
        throw error
    }
}

/// The token for an authorized use: your own, or a new one from the App.
func issueCredential(_ authorization: Authorization) throws -> GitHubCredential {
    let repository = authorization.repository
    do {
        if authorization.asOwner {
            let token = try loadOwnToken(owner: ownerAccount(repository))
            appendAccessLog("granted \(repository) (you) to \(authorization.chain)")
            return GitHubCredential(token: token, expires: nil)
        }
        // asked now, not before the dialog: an elevation that ran out or was locked meanwhile no longer counts
        let elevated = agentRequest(["op": "check", "repo": repository])?["elevated"] as? Bool == true
        let token = try mintInstallationToken(repository: repository, includeWorkflows: elevated)
        appendAccessLog(
            "granted \(repository) (\(authorization.grant))\(elevated ? ", elevated" : "") to \(authorization.chain)"
        )
        return GitHubCredential(token: token.token, expires: token.expires)
    } catch {
        appendAccessLog("refused \(repository) to \(authorization.chain): \(error)")
        throw error
    }
}

/// Approves a pending session with Touch ID, or waits while another client of the same session shows the dialog.
private func awaitApproval(of session: SessionInfo) throws {
    let reply = agentRequest(["op": "begin-approval", "session": session.id])
    if reply?["state"] as? String == "approved" {
        return
    }
    if reply?["lease"] as? Bool == true {
        let reason = "let \(session.program) in \(displayFolder(session.folder)) "
            + "(started \(clockTime(session.started))) use GitHub for "
            + "\(repositoryList(session.repositories)) until it exits"
        do {
            try authenticate(reason: reason)
        } catch {
            _ = agentRequest(["op": "deny", "session": session.id, "reason": "\(error)"])
            throw error
        }
        guard agentRequest(["op": "approve", "session": session.id])?["ok"] as? Bool == true else {
            throw ToolError.agent("the agent did not record the approval")
        }
        return
    }
    guard reply?["lease"] as? Bool == false else {
        let message = reply?["error"] as? String ?? "no answer"
        throw ToolError.agent("cannot ask to approve the session: \(message)")
    }

    // another client of this session shows the dialog; its answer applies here too
    let deadline = Date().addingTimeInterval(approvalWindow + 10)
    while Date() < deadline {
        sleep(1)
        guard let current = SessionInfo(agentRequest(["op": "check"])?["session"]), current.id == session.id else {
            throw ToolError.refused("the session ended before it was approved")
        }
        if current.approved {
            return
        }
        if !current.approving {
            throw ToolError.refused("the session was not approved")
        }
    }
    throw ToolError.authenticationNotAnswered
}

/// Ends an App token after its single use; a failure is reported and logged, not fatal.
func revokeAfterUse(_ credential: GitHubCredential, repository: String) {
    guard let expires = credential.expires else {
        return
    }
    do {
        try revokeInstallationToken(credential.token)
    } catch {
        fputs("gh-touchid: could not revoke the token for \(repository); it expires at \(localTime(expires)): \(error)\n", stderr)
        appendAccessLog("could not revoke the token for \(repository): \(error)")
    }
}
