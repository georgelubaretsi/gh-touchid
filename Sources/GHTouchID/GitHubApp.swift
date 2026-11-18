import Darwin
import Foundation

// Tokens that act as you, through the owner's GitHub App. Your sign-in to the App (an expiring user access token,
// renewed with its refresh token) never leaves gh-touchid: each use narrows it to one repository and the permissions
// that use may have (`POST /applications/{client_id}/token/scoped`), and that token is revoked after gh. gh-touchid
// does not act as an owner's App: it holds no key for one, only the client secret that lets it narrow and revoke your
// tokens. The one App gh-touchid acts as is the reader (Reader.swift), whose key it holds: an App with no permissions,
// installed on no repository, so its tokens read public data and GitHub refuses them most writes; the one write GitHub
// lets through, opening an issue, gh-touchid refuses before a token is made (IssueCheck.swift).

/// A token for one repository that acts as `login`, the App that made it (to revoke it), and what its installation has
/// that the token was made without: each permission with the installation's level.
struct ScopedToken {
    let token: String
    let expires: Date
    let login: String
    let app: AppCredentials
    let heldBack: [String: String]
}

/// The permissions a token for a repository may have without elevation, each at most at this level: those `app
/// create` gives an App, without `workflows`. Anything else an installation has reaches a token only while the
/// repository is elevated for it: `workflows`, a higher level of one of these, and every permission an owner added to
/// the App (environments, secrets, administration and the like) or GitHub introduces later.
let everydayPermissions = [
    "actions": "write",
    "contents": "write",
    "issues": "write",
    "pull_requests": "write",
    "checks": "read",
    "statuses": "read",
    "metadata": "read",
]

/// What an elevation is for when it names no permission: `workflows`, as every elevation was before agent protocol 3.
let defaultElevation = ["workflows"]

/// A GitHub permission's name as GitHub writes it (`pull_requests`): a lowercase letter, then lowercase letters,
/// digits and underscores, at most 64 in all; or nil.
func validPermission(_ name: String) -> String? {
    guard let first = name.unicodeScalars.first, ("a" ... "z").contains(first), name.unicodeScalars.count <= 64,
          name.unicodeScalars.allSatisfy({ ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "_" })
    else {
        return nil
    }
    return name
}

/// What a token may do: the installation's everyday permissions, and those of its other permissions the repository is
/// elevated for; or just open issues and read the repository.
enum TokenScope {
    case repository(elevated: Set<String>)
    case issues

    static let issuePermissions = ["issues": "write", "metadata": "read", "contents": "read"]
}

private let permissionLevels = ["read": 1, "write": 2, "admin": 3]

/// The permissions to ask for in a token for one repository, and those of the installation it goes without (with the
/// installation's level): each permission the repository is elevated for, at the installation's level; each other
/// everyday permission the installation has, at the lower of the two levels. A level gh-touchid does not know is held
/// back unless elevated.
func repositoryPermissions(
    installation: [String: Any],
    elevated: Set<String>
) -> (granted: [String: String], heldBack: [String: String]) {
    var granted: [String: String] = [:]
    var heldBack: [String: String] = [:]
    for case let (name, level as String) in installation {
        if elevated.contains(name) {
            granted[name] = level
        } else if let ceiling = everydayPermissions[name], let have = permissionLevels[level],
                  let most = permissionLevels[ceiling] {
            granted[name] = have <= most ? level : ceiling
            if have > most {
                heldBack[name] = level
            }
        } else {
            heldBack[name] = level
        }
    }
    return (granted, heldBack)
}

/// What to tell the caller when gh fails with a token made without some of its installation's permissions, other than
/// `workflows`, which GitHub names in its refusals; for the others it says only "Resource not accessible by
/// integration". It names no permission to elevate for: gh-touchid cannot tell which one gh needed.
func heldBackNotice(_ heldBack: [String: String], repository: String) -> String? {
    let named = heldBack.filter { $0.key != "workflows" }.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
    guard let last = named.last else {
        return nil
    }
    let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " and " + last
    return "gh failed with a token for \(repository) made without \(list), which the \(ownerAccount(repository)) App "
        + "has; a token includes one while the repository is elevated for it: gh-touchid elevate --for 30m --repo "
        + "\(repository) --permission NAME"
}

/// A sign-in is renewed once it has less than this left, so that every token narrowed from it lasts at least this long.
private let renewalMargin: TimeInterval = 60 * 60

/// A token for one repository, acting as you, from your sign-in to its owner's App.
func mintScopedToken(repository: String, scope: TokenScope) throws -> ScopedToken {
    let owner = ownerAccount(repository)
    let (app, signIn) = try currentSignIn(owner: owner)
    let permissions: [String: String]
    let heldBack: [String: String]
    switch scope {
    case let .repository(elevated):
        let installation = try installationPermissions(owner: owner, token: signIn.accessToken)
        (permissions, heldBack) = repositoryPermissions(installation: installation, elevated: elevated)
    case .issues:
        permissions = TokenScope.issuePermissions
        heldBack = [:]
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
    return ScopedToken(token: token, expires: expires, login: signIn.login, app: app, heldBack: heldBack)
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

/// Ends your sign-in's grant to the App (`DELETE /applications/{client_id}/grant`): GitHub revokes every token the
/// sign-in made, and the App no longer appears among your authorized Apps. A grant GitHub does not know is already
/// gone.
func revokeGrant(app: AppCredentials, accessToken: String) throws {
    let response = try githubAPI(
        "DELETE",
        "/applications/\(app.clientId)/grant",
        bearer: nil,
        basic: app,
        body: ["access_token": accessToken]
    )
    guard response.status == 204 || response.status == 404 else {
        throw ToolError.github("GitHub did not end the sign-in's grant (HTTP \(response.status): \(response.message))")
    }
}

/// The permissions of the owner's installation of the App, as your sign-in sees it (`GET /user/installations`, page by
/// page: an App installed on many accounts lists the owner's wherever GitHub puts it).
private func installationPermissions(owner: String, token: String) throws -> [String: Any] {
    let pageSize = 100
    var page = 1
    while true {
        let response = try githubAPI("GET", "/user/installations?per_page=\(pageSize)&page=\(page)", bearer: token)
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
        if let permissions = installation?["permissions"] as? [String: Any] {
            return permissions
        }
        // a short page is the last; so is page 50, which is 5,000 installations
        guard installations.count == pageSize, page < 50 else {
            throw ToolError.github("the \(owner) App is not installed on \(owner)\(installHint(owner: owner))")
        }
        page += 1
    }
}

/// `: install it at https://github.com/apps/<slug>/installations/new`, when the App's slug is stored.
func installHint(owner: String) -> String {
    guard let slug = appSlug(owner: owner), let web = try? webBaseURL() else {
        return ""
    }
    return "; install it at \(web)/apps/\(slug)/installations/new"
}

/// The owner's App and your sign-in to it with at least `renewalMargin` left, renewed first when needed. Both are read
/// under the owner's sign-in lock, so that an `app create`, `app add` or `app login` storing a new pair meanwhile can
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
        throw ToolError.refused("cannot open \(path): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
        guard errno == EINTR else {
            throw ToolError.refused("cannot lock \(path): \(String(cString: strerror(errno)))")
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
