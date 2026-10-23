import Darwin
import Foundation

// Tokens that act as you, through the owner's GitHub App. Your sign-in to the App (an expiring user access token,
// renewed with its refresh token) never leaves gh-touchid: each use narrows it to one repository and the permissions
// that use may have (`POST /applications/{client_id}/token/scoped`), and that token is revoked after gh. gh-touchid
// never acts as the App: it holds no key for it, only the client secret that lets it narrow and revoke your tokens.

/// A token for one repository that acts as `login`, and the App that made it (to revoke it).
struct ScopedToken {
    let token: String
    let expires: Date
    let login: String
    let app: AppCredentials
}

/// What a token may do: the installation's permissions (without `workflows` unless the repository is elevated), or
/// just open issues and read the repository.
enum TokenScope {
    case repository(includeWorkflows: Bool)
    case issues

    static let issuePermissions = ["issues": "write", "metadata": "read", "contents": "read"]
}

/// A sign-in is renewed once it has less than this left, so that every token narrowed from it lasts at least this long.
private let renewalMargin: TimeInterval = 60 * 60

/// A token for one repository, acting as you, from your sign-in to its owner's App.
func mintScopedToken(repository: String, scope: TokenScope) throws -> ScopedToken {
    let owner = ownerAccount(repository)
    let (app, signIn) = try currentSignIn(owner: owner)
    let permissions: [String: Any]
    switch scope {
    case let .repository(includeWorkflows):
        var granted = try installationPermissions(owner: owner, token: signIn.accessToken)
        if !includeWorkflows {
            granted.removeValue(forKey: "workflows")
        }
        permissions = granted
    case .issues:
        permissions = TokenScope.issuePermissions
    }

    let response = try githubAPI(
        "POST",
        "/applications/\(app.clientId)/token/scoped",
        bearer: nil,
        basic: app,
        body: [
            "access_token": signIn.accessToken,
            "target": owner,
            "repositories": [repositoryName(repository)],
            "permissions": permissions,
        ]
    )
    switch response.status {
    case 200, 201:
        break
    case 401, 404:
        throw ToolError.github(
            "GitHub accepted neither your sign-in to the \(owner) App nor its client secret (HTTP \(response.status)); "
                + "run `gh-touchid app login \(owner)`"
        )
    default:
        throw ToolError.github(
            "GitHub did not narrow your sign-in to \(repository) (HTTP \(response.status): \(response.message)); "
                + "is the \(owner) App installed on it?"
        )
    }
    // the reply holds the token: no part of it goes into an error
    guard let token = response.object?["token"] as? String, !token.isEmpty else {
        throw ToolError.github("GitHub's reply with a token for \(repository) (HTTP \(response.status)) lacks the token")
    }
    let expires = (response.object?["expires_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        ?? Date(timeIntervalSince1970: signIn.accessExpires)
    return ScopedToken(token: token, expires: expires, login: signIn.login, app: app)
}

/// Ends a token narrowed from your sign-in (`DELETE /applications/{client_id}/token`); the sign-in stays.
func revokeScopedToken(_ token: String, app: AppCredentials) throws {
    let response = try githubAPI(
        "DELETE",
        "/applications/\(app.clientId)/token",
        bearer: nil,
        basic: app,
        body: ["access_token": token]
    )
    guard response.status == 204 else {
        throw ToolError.github("HTTP \(response.status): \(response.message)")
    }
}

/// The permissions of the owner's installation of the App, as your sign-in sees it (`GET /user/installations`).
private func installationPermissions(owner: String, token: String) throws -> [String: Any] {
    let response = try githubAPI("GET", "/user/installations?per_page=100", bearer: token)
    if response.status == 401 {
        throw ToolError.notSignedIn(owner)
    }
    guard response.status == 200, let installations = response.object?["installations"] as? [[String: Any]] else {
        throw ToolError.github(
            "cannot read where the \(owner) App is installed (HTTP \(response.status): \(response.message))"
        )
    }
    let installation = installations.first {
        (($0["account"] as? [String: Any])?["login"] as? String)?.lowercased() == owner
    }
    guard let permissions = installation?["permissions"] as? [String: Any] else {
        throw ToolError.github("the \(owner) App is not installed on \(owner)\(installHint(owner: owner))")
    }
    return permissions
}

/// `: install it at https://github.com/apps/<slug>/installations/new`, when the App's slug is stored.
func installHint(owner: String) -> String {
    guard let slug = appSlug(owner: owner), let web = try? webBaseURL() else {
        return ""
    }
    return "; install it at \(web)/apps/\(slug)/installations/new"
}

/// The owner's App and your sign-in to it with at least `renewalMargin` left, renewed first when needed. Both are read
/// under the owner's sign-in lock, so that an `app create`, `app set` or `app login` storing a new pair meanwhile can
/// never leave this use with one App's secret and another's sign-in. Renewing replaces the refresh token (GitHub
/// accepts each one once); other gh-touchid processes for the same owner wait for the lock and then find the renewed
/// sign-in.
private func currentSignIn(owner: String) throws -> (AppCredentials, SignIn) {
    try withSignInLock(owner: owner) {
        let app = try loadAppCredentials(owner: owner)
        let signIn = try loadSignIn(owner: owner)
        let now = Date().timeIntervalSince1970
        if signIn.accessExpires - now > renewalMargin {
            return (app, signIn)
        }
        guard signIn.refreshExpires - now > 60 else {
            throw ToolError.notSignedIn(owner)
        }
        let reply = try githubOAuth("/login/oauth/access_token", fields: [
            "client_id": app.clientId,
            "client_secret": app.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": signIn.refreshToken,
        ])
        let pair = try tokenPair(reply, owner: owner)
        let renewed = pair.signIn(login: signIn.login)
        try storeSignIn(renewed, owner: owner)
        appendAccessLog("renewed the sign-in of \(signIn.login) to the \(owner) App")
        return (app, renewed)
    }
}

/// Runs `body` holding the owner's sign-in lock: renewals, sign-ins and App replacements for one owner take turns.
func withSignInLock<T>(owner: String, _ body: () throws -> T) throws -> T {
    try ensureSessionDirectory()
    let path = (sessionDirectory as NSString).appendingPathComponent("signin-\(owner).lock")
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        throw ToolError.input("cannot open \(path): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
        guard errno == EINTR else {
            throw ToolError.input("cannot lock \(path): \(String(cString: strerror(errno)))")
        }
    }
    return try body()
}

/// The tokens in a reply of `/login/oauth/access_token`.
struct TokenPair {
    let accessToken: String
    let accessExpires: TimeInterval
    let refreshToken: String
    let refreshExpires: TimeInterval

    func signIn(login: String) -> SignIn {
        SignIn(
            login: login,
            accessToken: accessToken,
            accessExpires: accessExpires,
            refreshToken: refreshToken,
            refreshExpires: refreshExpires
        )
    }
}

/// The tokens GitHub's OAuth endpoint sent, which reports refusals in an `error` field (often with HTTP 200). A reply
/// without an expiry or a refresh token is refused: gh-touchid never keeps a token that does not expire. The reply
/// holds tokens, so only its `error` fields go into an error.
func tokenPair(_ response: APIResponse, owner: String) throws -> TokenPair {
    let object = response.object
    if let error = object?["error"] as? String {
        if error == "bad_refresh_token" {
            throw ToolError.notSignedIn(owner)
        }
        let description = (object?["error_description"] as? String).map { ": \(printable($0))" } ?? ""
        throw ToolError.github("GitHub refused the sign-in to the \(owner) App (\(printable(error))\(description))")
    }
    guard response.status == 200 else {
        throw ToolError.github("GitHub refused the sign-in to the \(owner) App (HTTP \(response.status))")
    }
    guard let access = object?["access_token"] as? String, !access.isEmpty,
          let accessSeconds = (object?["expires_in"] as? NSNumber)?.doubleValue,
          let refresh = object?["refresh_token"] as? String, !refresh.isEmpty,
          let refreshSeconds = (object?["refresh_token_expires_in"] as? NSNumber)?.doubleValue else {
        throw ToolError.github(
            "GitHub's sign-in to the \(owner) App came without an expiry or a refresh token; gh-touchid keeps only "
                + "tokens that expire"
        )
    }
    let now = Date().timeIntervalSince1970
    return TokenPair(
        accessToken: access,
        accessExpires: now + accessSeconds,
        refreshToken: refresh,
        refreshExpires: now + refreshSeconds
    )
}
