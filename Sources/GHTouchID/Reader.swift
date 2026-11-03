import Darwin
import Foundation

// The reader: one GitHub App of yours with no permissions, installed on your user account with no repository, whose
// installation tokens let gh read public data for owners without an App of their own, or outside any repository,
// without Touch ID. Nothing about its installation is cached: every use signs a JWT with the stored key, finds the one
// installation (`GET /app/installations`), mints a token (`POST /app/installations/{id}/access_tokens`), and checks
// what GitHub says the token can do before gh gets it: no permissions, `selected` repositories, and none listed
// (`GET /installation/repositories`). A token that fails a check is revoked (`DELETE /installation/token`) before the
// use is refused, so an App that gained permissions or repositories on GitHub never reaches gh. GitHub does let such
// a token open issues on public repositories; gh-touchid refuses those commands before minting (IssueCheck.swift),
// and every use says on stderr what the token is for.

/// A minted reader token and when GitHub ends it on its own.
struct ReaderToken {
    let token: String
    let expires: Date
}

/// What every use of the reader tells its caller (Notices) before gh starts.
func readerNotice(slug: String) -> String {
    "public read-only access as \(slug)[bot]; don't create or change anything with it"
}

/// GitHub's page for installing the reader on its owner.
func readerInstallURL(slug: String) throws -> String {
    try webBaseURL() + "/apps/\(slug)/installations/new"
}

/// The reader's settings on GitHub, where its keys are listed and deleted.
func readerSettingsURL(slug: String) throws -> String {
    try webBaseURL() + "/settings/apps/\(slug)"
}

/// Where the reader App itself is deleted.
func readerDeleteURL(slug: String) throws -> String {
    try readerSettingsURL(slug: slug) + "/advanced"
}

/// A token from the stored reader for one use, minted and checked as this file's top comment says; `readerMissing`
/// without a reader.
func mintStoredReaderToken() throws -> (token: ReaderToken, label: ReaderLabel) {
    guard hasReader() else {
        throw ToolError.readerMissing
    }
    try checkFormat(.reader)
    guard let label = readerLabel() else {
        throw ToolError.unreadableFormat(item: "\(StoredItem.reader)", storeAgain: StoredItem.reader.storeAgain)
    }
    let secret = try loadReader()
    let key: AppPrivateKey
    do {
        key = try AppPrivateKey(pem: secret.privateKey)
    } catch {
        throw ToolError.keychain("the stored reader key is not valid; \(StoredItem.reader.storeAgain)")
    }
    let jwt = try key.jwt(appId: secret.appId)
    guard let installation = try readerInstallation(jwt: jwt, appId: secret.appId, label: label) else {
        throw ToolError.readerNotInstalled(try readerInstallURL(slug: label.slug))
    }
    let token = try mintCheckedReaderToken(jwt: jwt, appId: secret.appId, installation: installation)
    return (token, label)
}

/// The id of the reader's one installation, on its owner (a user); nil when it has none yet. Any other count, or one
/// installation elsewhere, is `readerInstallations`.
func readerInstallation(jwt: String, appId: Int, label: ReaderLabel) throws -> Int? {
    let response = try githubAPI("GET", "/app/installations?per_page=100", bearer: nil, jwt: jwt)
    if response.status == 401 {
        throw ToolError.readerKeyRejected(appId)
    }
    guard response.status == 200,
          let installations = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
        throw ToolError.github(
            "cannot read where the reader \(label.slug) is installed (HTTP \(response.status): \(response.message))"
        )
    }
    if installations.isEmpty {
        return nil
    }
    guard installations.count == 1, let installation = installations.first,
          let account = installation["account"] as? [String: Any],
          (account["login"] as? String)?.lowercased() == label.owner,
          account["type"] as? String == "User",
          let id = installation["id"] as? Int else {
        throw ToolError.readerInstallations(installations.count)
    }
    return id
}

/// A token of the installation, after GitHub confirmed it has no permissions and no repository; a token that fails
/// either check is revoked first, then refused with `readerPermissions`.
func mintCheckedReaderToken(jwt: String, appId: Int, installation: Int) throws -> ReaderToken {
    let response = try githubAPI(
        "POST",
        "/app/installations/\(installation)/access_tokens",
        bearer: nil,
        jwt: jwt,
        body: [:]
    )
    if response.status == 401 {
        throw ToolError.readerKeyRejected(appId)
    }
    guard response.status == 201 || response.status == 200 else {
        throw ToolError.github("GitHub did not make a reader token (HTTP \(response.status): \(response.message))")
    }
    // the reply holds the token: no part of it goes into an error
    guard let object = response.object, let token = object["token"] as? String, !token.isEmpty else {
        throw ToolError.github("GitHub's reply with a reader token (HTTP \(response.status)) lacks the token")
    }
    let expires = (object["expires_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        ?? Date().addingTimeInterval(60 * 60)
    let minted = ReaderToken(token: token, expires: expires)
    do {
        try checkReaderToken(object, token: token)
    } catch {
        revokeReaderToken(minted, context: "the refused reader token")
        throw error
    }
    return minted
}

/// What a reader token may do, as GitHub reported it at minting and as `/installation/repositories` lists it; throws
/// `readerPermissions` naming what is more than public reading.
private func checkReaderToken(_ object: [String: Any], token: String) throws {
    guard let permissions = object["permissions"] as? [String: Any] else {
        throw ToolError.readerPermissions("GitHub did not say which")
    }
    if !permissions.isEmpty {
        let granted = permissions.keys.sorted().map { name in
            "\(printable(name, limit: 40)): \(printable("\(permissions[name]!)", limit: 20))"
        }
        throw ToolError.readerPermissions(granted.joined(separator: ", "))
    }
    let selection = object["repository_selection"] as? String
    guard selection == "selected" else {
        throw ToolError.readerPermissions("access to \(printable(selection ?? "unknown", limit: 20)) repositories")
    }
    let response = try githubAPI("GET", "/installation/repositories?per_page=1", bearer: token)
    guard response.status == 200, let count = (response.object?["total_count"] as? NSNumber)?.intValue else {
        throw ToolError.github(
            "cannot read which repositories the reader reaches (HTTP \(response.status): \(response.message))"
        )
    }
    guard count == 0 else {
        throw ToolError.readerPermissions("access to \(count) \(count == 1 ? "repository" : "repositories")")
    }
}

/// Ends a reader token (`DELETE /installation/token`, authorized by the token itself).
func revokeInstallationToken(_ token: String) throws {
    let response = try githubAPI("DELETE", "/installation/token", bearer: token)
    guard response.status == 204 else {
        throw ToolError.github("HTTP \(response.status): \(response.message)")
    }
}

/// Revokes `token`, reporting and logging a failure rather than throwing it: the token ends on its own at `expires`.
func revokeReaderToken(_ token: ReaderToken, context: String) {
    do {
        try revokeInstallationToken(token.token)
    } catch {
        fputs("gh-touchid: could not revoke \(context); it expires at \(localTime(token.expires)): \(error)\n", stderr)
        appendAccessLog("could not revoke \(context): \(error)")
    }
}

/// `reader create` and `reader add` end with this: one token minted, checked and revoked, proving the key, the
/// installation and the App's lack of permissions before (or right after) anything is stored.
func testReader(key: AppPrivateKey, appId: Int, label: ReaderLabel) throws {
    let jwt = try key.jwt(appId: appId)
    guard let installation = try readerInstallation(jwt: jwt, appId: appId, label: label) else {
        throw ToolError.readerNotInstalled(try readerInstallURL(slug: label.slug))
    }
    let token = try mintCheckedReaderToken(jwt: jwt, appId: appId, installation: installation)
    revokeReaderToken(token, context: "the reader's test token")
}
