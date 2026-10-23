import Darwin
import Foundation

// Who gets a token for repository R, decided by the client that needs it:
// 1. Acting as one of your accounts (`as <login>`, GH_TOUCHID_AS=<login>): Touch ID for every use, sessions or not,
//    then that account's token.
// 2. R's owner has no App stored, or you are not signed in to it: refused before any dialog.
// 3. Inside an approved session that lists R: a token for R, acting as you through the App, without Touch ID. The
//    session may be held by the agent or, in builds that share agent.sock, by an agent of 0.4.0/0.4.1.
// 4. Inside an approved session that does not list R: an issue-only token; for a public R, Touch ID for this use
//    first, and nothing for Git.
// 5. Inside a pending session: one Touch ID approves the session, then as 3 or 4.
// 6. Anything else: Touch ID naming the command and who asked, then one token for R.
// Tokens of 3–6 come from your sign-in to R's owner's App, narrowed to R; they include `workflows` only if R is
// elevated when the token is made, which is after any dialog; issue-only tokens never do. Every outcome is logged
// with the process chain.

struct GitHubCredential {
    let token: String
    /// What Git sends as the username with it.
    let username: String
    /// When a narrowed token expires; nil for an account's token, which is neither revoked nor expires here.
    let expires: Date?
    /// The App that narrowed the token, which revokes it after use; nil for an account's token.
    let app: AppCredentials?
}

/// A session as an agent reports it.
struct SessionInfo {
    let id: String
    let pid: Int
    let program: String
    let folder: String
    let repositories: [String]
    let started: Date
    let approved: Bool
    let approving: Bool
    /// The agent of 0.4.0/0.4.1 that holds the session; nil for the agent's own.
    var legacy: LegacyAgent?

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
    /// A token for the repository from your sign-in: for a session that lists it, or (no session) once after Touch ID.
    case app(session: SessionInfo?)
    /// An issue-only token, for a repository the session does not list.
    case issues(session: SessionInfo)
}

/// A use that Touch ID or a session allowed; the token is issued separately, right after.
struct Authorization {
    /// nil only when acting as an account and no repository could be told.
    let repository: String?
    let grant: Grant
    /// What asked, as the dialog shows it: `gh pr list`, `git push`, with what gh-touchid could tell about it.
    let use: Use
    let forGit: Bool
    let chain: String

    var target: String {
        repository ?? "no repository"
    }
}

/// Touch ID or session approval for one use of `repository` by `use`, as `account` when one is given.
func authorizeUse(repository: String?, use: Use, account: String?, forGit: Bool) throws -> Authorization {
    let chain = processChain(getpid())
    let target = repository ?? "no repository"
    func authorized(_ grant: Grant) -> Authorization {
        Authorization(repository: repository, grant: grant, use: use, forGit: forGit, chain: chain)
    }
    do {
        if let account {
            guard hasUserToken(login: account) else {
                throw ToolError.missingAccount(account)
            }
            try checkFormat(.account(login: account))
            try authenticate(.acting(as: account, by: requester(), use: use, repository: repository))
            return authorized(.account(account))
        }
        guard let repository else {
            throw ToolError.missingRepository
        }
        // nothing could be issued: say so before anyone is asked
        let owner = ownerAccount(repository)
        guard hasAppCredentials(owner: owner) else {
            let logins = (try? storedUserLogins()) ?? []
            throw ToolError.noApp(owner: owner, logins: logins, program: forGit ? "git" : "gh")
        }
        guard hasSignIn(owner: owner) else {
            throw ToolError.notSignedIn(owner)
        }
        try checkFormat(.app(owner: owner))
        try checkFormat(.signIn(owner: owner))

        // an approved session that lists the repository decides, whichever agent holds it; otherwise the agent's
        let reply = agentRequest(["op": "check", "repo": repository])
        let current = SessionInfo(reply?["session"])
        let covers = reply?["covers"] as? Bool == true
        if let current, current.approved, covers {
            return authorized(.app(session: current))
        }
        if let legacy = legacyApprovedSession(covering: repository) {
            return authorized(.app(session: legacy))
        }
        if let session = current {
            if !session.approved {
                try awaitApproval(of: session)
            }
            return authorized(covers ? .app(session: session) : .issues(session: session))
        }
        fputs("To approve this whole session once, run: gh-touchid session\n", stderr)
        try authenticate(.appUse(
            by: requester(),
            use: use,
            repository: repository,
            app: appSlug(owner: owner),
            login: signedInLogin(owner: owner)
        ))
        return authorized(.app(session: nil))
    } catch {
        appendAccessLog("refused \(target) to \(chain): \(error)")
        throw error
    }
}

/// The token for an authorized use: an account's own, or one narrowed from your sign-in.
func issueCredential(_ authorization: Authorization) throws -> GitHubCredential {
    let chain = authorization.chain
    do {
        switch authorization.grant {
        case let .account(login):
            let token = try loadUserToken(login: login)
            appendAccessLog("granted \(authorization.target) (as \(login)) to \(chain)")
            return GitHubCredential(token: token, username: login, expires: nil, app: nil)
        case let .app(session):
            guard let repository = authorization.repository else {
                throw ToolError.missingRepository
            }
            // asked now, not before the dialog: an elevation that ran out or was locked meanwhile no longer counts
            let elevated = isElevated(repository)
            let token = try mintScopedToken(repository: repository, scope: .repository(includeWorkflows: elevated))
            let grant = session.map { "session \($0.label)\($0.legacy.map { " of \($0.marker)" } ?? "")" } ?? "once"
            appendAccessLog(
                "granted \(repository) (\(grant))\(elevated ? ", elevated" : "") as \(token.login) to \(chain)"
            )
            return GitHubCredential(token: token.token, username: token.login, expires: token.expires, app: token.app)
        case let .issues(session):
            guard let repository = authorization.repository else {
                throw ToolError.missingRepository
            }
            return try issueOnlyCredential(repository: repository, session: session, authorization: authorization)
        }
    } catch {
        appendAccessLog("refused \(authorization.target) to \(chain): \(error)")
        throw error
    }
}

/// An issue-only token for a repository the session does not list. A public one takes Touch ID for this use, and
/// Git gets nothing for it (it reads public repositories without a credential); the token is made first, because it
/// can read whether the repository is public, and revoked when the use is not allowed.
private func issueOnlyCredential(
    repository: String,
    session: SessionInfo,
    authorization: Authorization
) throws -> GitHubCredential {
    let minted = try mintScopedToken(repository: repository, scope: .issues)
    let credential = GitHubCredential(
        token: minted.token,
        username: minted.login,
        expires: minted.expires,
        app: minted.app
    )
    let grant = "session \(session.label)"
    do {
        if try isPrivateRepository(repository, token: minted.token) {
            appendAccessLog("granted \(repository) (issues, \(grant)) as \(minted.login) to \(authorization.chain)")
            return credential
        }
        guard !authorization.forGit else {
            throw ToolError.refused(
                "\(repository) is public and outside the session; Git reads it without a credential"
            )
        }
        let owner = ownerAccount(repository)
        try authenticate(.publicIssue(
            by: Requester(name: session.program, folder: session.folder),
            use: authorization.use,
            repository: repository,
            app: appSlug(owner: owner),
            login: minted.login
        ))
    } catch {
        revokeAfterUse(credential, repository: repository)
        throw error
    }
    appendAccessLog(
        "granted \(repository) (issues, public, approved once, \(grant)) as \(minted.login) to \(authorization.chain)"
    )
    return credential
}

/// Approves a pending session with Touch ID, or waits while another client of the same session shows the dialog.
private func awaitApproval(of session: SessionInfo) throws {
    let reply = agentRequest(["op": "begin-approval", "session": session.id])
    if reply?["state"] as? String == "approved" {
        return
    }
    if reply?["lease"] as? Bool == true {
        let prompt = Prompt.session(
            program: session.program,
            repositories: session.repositories,
            folder: session.folder,
            started: session.started
        )
        do {
            try authenticate(prompt)
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

/// Ends a narrowed token after its single use; a failure is reported and logged, not fatal.
func revokeAfterUse(_ credential: GitHubCredential, repository: String) {
    guard let app = credential.app, let expires = credential.expires else {
        return
    }
    do {
        try revokeScopedToken(credential.token, app: app)
    } catch {
        fputs("gh-touchid: could not revoke the token for \(repository); it expires at \(localTime(expires)): \(error)\n", stderr)
        appendAccessLog("could not revoke the token for \(repository): \(error)")
    }
}
