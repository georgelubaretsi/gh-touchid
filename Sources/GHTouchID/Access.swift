import Darwin
import Foundation

// Who gets a token for repository R, decided by the client that needs it:
// 1. Acting as one of your accounts (`as <login>`, GH_TOUCHID_AS=<login>): Touch ID for every use, sessions or not,
//    then that account's token.
// 2. Inside an approved session that lists R: a token from the App without Touch ID.
// 3. Inside a pending session that lists R: one Touch ID approves the session, then as 2.
// 4. Anything else: Touch ID naming the command and who asked, then one token from the App.
// App tokens include `workflows` only if R is elevated when the token is minted, which is after any dialog.
// Every outcome is logged with the process chain.

struct GitHubCredential {
    let token: String
    /// What Git sends as the username with it.
    let username: String
    /// When an App token expires; nil for an account's token, which is neither revoked nor expires here.
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
}

/// The account GH_TOUCHID_AS names, if any.
func actingAccount() throws -> String? {
    guard let value = ProcessInfo.processInfo.environment["GH_TOUCHID_AS"], !value.isEmpty else {
        return nil
    }
    guard let login = validOwner(value) else {
        throw ToolError.input("GH_TOUCHID_AS takes the login of one of your GitHub accounts")
    }
    return login
}

/// How an authorized use gets its token.
enum Grant {
    /// The token of one of your accounts.
    case account(String)
    /// A token from the App: for a session that lists the repository, or (no session) once after Touch ID.
    case app(session: SessionInfo?)
}

/// A use that Touch ID or a session allowed; the token is issued separately, right after.
struct Authorization {
    /// nil only when acting as an account and no repository could be told.
    let repository: String?
    let grant: Grant
    let chain: String

    var target: String {
        repository ?? "no repository"
    }
}

/// Touch ID or session approval for one use of `repository` by `command`, as `account` when one is given.
func authorizeUse(repository: String?, command: String, account: String?) throws -> Authorization {
    let chain = processChain(getpid())
    let target = repository ?? "no repository"
    func authorized(_ grant: Grant) -> Authorization {
        Authorization(repository: repository, grant: grant, chain: chain)
    }
    do {
        if let account {
            guard hasUserToken(login: account) else {
                throw ToolError.missingAccount(account)
            }
            try authenticate(
                reason: "act as \(account): \(command) on \(target) (asked by \(processChain(getppid())))"
            )
            return authorized(.account(account))
        }
        guard let repository else {
            throw ToolError.missingRepository
        }
        let reply = agentRequest(["op": "check", "repo": repository])
        if let session = SessionInfo(reply?["session"]), reply?["covers"] as? Bool == true {
            if !session.approved {
                try awaitApproval(of: session)
            }
            return authorized(.app(session: session))
        }
        try authenticate(
            reason: "use GitHub for \(repository): \(command) (asked by \(processChain(getppid())))"
        )
        return authorized(.app(session: nil))
    } catch {
        appendAccessLog("refused \(target) to \(chain): \(error)")
        throw error
    }
}

/// The token for an authorized use: an account's own, or a new one from the App.
func issueCredential(_ authorization: Authorization) throws -> GitHubCredential {
    let chain = authorization.chain
    do {
        switch authorization.grant {
        case let .account(login):
            let token = try loadUserToken(login: login)
            appendAccessLog("granted \(authorization.target) (as \(login)) to \(chain)")
            return GitHubCredential(token: token, username: login, expires: nil)
        case let .app(session):
            guard let repository = authorization.repository else {
                throw ToolError.missingRepository
            }
            // asked now, not before the dialog: an elevation that ran out or was locked meanwhile no longer counts
            let elevated = agentRequest(["op": "check", "repo": repository])?["elevated"] as? Bool == true
            let token = try mintInstallationToken(repository: repository, includeWorkflows: elevated)
            let grant = session.map { "session \($0.label)" } ?? "once"
            appendAccessLog("granted \(repository) (\(grant))\(elevated ? ", elevated" : "") to \(chain)")
            return GitHubCredential(token: token.token, username: "x-access-token", expires: token.expires)
        }
    } catch {
        appendAccessLog("refused \(authorization.target) to \(chain): \(error)")
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
        let reply = agentRequest(["op": "check", "session": session.id])
        guard let current = SessionInfo(reply?["session"]), current.id == session.id else {
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
