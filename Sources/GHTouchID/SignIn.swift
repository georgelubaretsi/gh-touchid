import CryptoKit
import Darwin
import Foundation

// Signing in to an owner's GitHub App: GitHub's web flow with PKCE. The browser goes to GitHub's authorize page for the
// App; once you choose Authorize, GitHub sends it back to the local server's /callback with a code, which (with the
// App's client secret and this attempt's PKCE verifier) buys an expiring user access token and its refresh token.
// `app login`, and the end of `app create` and `app set`, store the sign-in after Touch ID.

/// How long the browser may take to come back from GitHub's authorize page.
let signInTimeout: TimeInterval = 15 * 60

/// One sign-in attempt: GitHub's authorize URL with its `state` and PKCE challenge, and the verifier that answers it.
struct SignInRequest {
    let url: String
    let state: String
    let verifier: String
}

func signInRequest(app: AppCredentials) throws -> SignInRequest {
    let state = randomHex(bytes: 16)
    // 64 hex digits: within PKCE's 43 to 128 unreserved characters
    let verifier = randomHex(bytes: 32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    var components = URLComponents(string: try webBaseURL() + "/login/oauth/authorize")
    components?.queryItems = [
        URLQueryItem(name: "client_id", value: app.clientId),
        URLQueryItem(name: "redirect_uri", value: callbackURL),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        // an expiring token with a refresh token, even from an App that has expiring tokens turned off
        URLQueryItem(name: "scope", value: "offline_access"),
    ]
    guard let url = components?.string else {
        throw ToolError.input("cannot build GitHub's authorize URL")
    }
    return SignInRequest(url: url, state: state, verifier: verifier)
}

/// Waits until GitHub sends the browser back with this attempt's `state`, then buys the sign-in (not stored). Returns
/// it with the browser's connection, which the caller answers and closes. A callback with another `state`, as from an
/// old tab, is turned away and the wait goes on.
func awaitSignIn(
    _ request: SignInRequest,
    app: AppCredentials,
    owner: String,
    server: LocalServer,
    deadline: Date
) throws -> (signIn: SignIn, browser: Int32) {
    while true {
        let (client, _, query) = try server.awaitRequest(for: ["/callback"], deadline: deadline)
        guard query["state"] == request.state else {
            respond(client, status: 400, text: "This is not the answer to gh-touchid's current sign-in.")
            close(client)
            continue
        }
        do {
            if let error = query["error"] {
                let description = query["error_description"].map { ": \(printable($0))" } ?? ""
                throw ToolError.refused("GitHub did not sign you in (\(printable(error))\(description))")
            }
            guard let code = query["code"], !code.isEmpty, code.count <= 100 else {
                throw ToolError.refused("GitHub sent the browser back without a code")
            }
            let reply = try githubOAuth("/login/oauth/access_token", fields: [
                "client_id": app.clientId,
                "client_secret": app.clientSecret,
                "code": code,
                "redirect_uri": callbackURL,
                "code_verifier": request.verifier,
            ])
            let pair = try tokenPair(reply, owner: owner)
            let owned = try tokenOwner(pair.accessToken)
            guard let login = validOwner(owned.login) else {
                throw ToolError.github("GitHub named an account gh-touchid cannot use: \(printable(owned.login))")
            }
            return (pair.signIn(login: login), client)
        } catch {
            respond(client, status: 200, text: "Nothing was stored: \(error)")
            close(client)
            throw error
        }
    }
}

/// `app login <owner> [--no-open]`: signs you in to the owner's stored App again, as when the sign-in has ended.
func appLogin(owner: String, openBrowser: Bool) throws -> Int32 {
    let app = try loadAppCredentials(owner: owner)
    let slug = appSlug(owner: owner)
    let server = try LocalServer(port: callbackPort)
    let request = try signInRequest(app: app)
    fputs(
        "To sign in to \(appWords(slug, owner: owner)), open \(request.url) and choose Authorize "
            + "(waiting up to 15 minutes).\n",
        stderr
    )
    if openBrowser {
        openInBrowser(request.url)
    }
    let (signIn, browser) = try awaitSignIn(
        request,
        app: app,
        owner: owner,
        server: server,
        deadline: Date().addingTimeInterval(signInTimeout)
    )
    defer { close(browser) }
    do {
        try authenticate(.signIn(signIn.login, owner: owner, app: slug, storesApp: false))
        try storeSignIn(signIn, owner: owner)
    } catch {
        respond(browser, status: 200, text: "Nothing was stored: \(error)")
        throw error
    }
    respond(browser, status: 200, text: "Signed in as \(signIn.login). You can close this tab.")
    appendAccessLog("signed in as \(signIn.login) to the \(owner) App")
    fputs("Signed in to \(appWords(slug, owner: owner)) as \(signIn.login).\n", stderr)
    return 0
}

/// The slug of the App your sign-in reaches, from any of its installations you can access (`GET /user/installations`);
/// nil when it is installed nowhere you can see.
func installedAppSlug(token: String) -> String? {
    guard let response = try? githubAPI("GET", "/user/installations?per_page=100", bearer: token),
          response.status == 200,
          let installations = response.object?["installations"] as? [[String: Any]] else {
        return nil
    }
    return installations.lazy.compactMap { ($0["app_slug"] as? String).flatMap(validOwner) }.first
}

/// `the GitHub App acme-agent`, or `acme's GitHub App` when the slug is not stored.
func appWords(_ slug: String?, owner: String) -> String {
    slug.map { "the GitHub App \($0)" } ?? "\(owner)'s GitHub App"
}
