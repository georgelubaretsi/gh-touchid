import Darwin
import Foundation

// `app create <owner>`: GitHub's App manifest flow, then the sign-in, in one trip of the browser. The local server on
// the callback port serves a page that posts the manifest to GitHub; once you choose Create GitHub App there, GitHub
// sends the browser to /created with a code and the `state` it was given. The code buys the App's client ID and client
// secret (its private key and webhook secret are dropped: gh-touchid does not act as an owner's App), and the browser
// goes on to GitHub's authorize page for the new App. After you choose Authorize, one Touch ID stores the App and your
// sign-in, and the browser goes on to the App's installation page.
//
// `reader create`: the same manifest flow for the reader, an App with no permissions on your user account. Its code
// buys the App's ID and private key (the one key gh-touchid keeps; client secret and webhook secret are dropped), one
// Touch ID stores them, and the browser goes on to the installation page while gh-touchid waits for the installation
// and proves it with one token, checked and revoked.

private let manifestPermissions = [
    "actions": "write",
    "contents": "write",
    "issues": "write",
    "pull_requests": "write",
    "workflows": "write",
    "checks": "read",
    "statuses": "read",
    "metadata": "read",
]

/// How long the manifest step may take; GitHub's codes last an hour too.
private let manifestTimeout: TimeInterval = 60 * 60

private struct CreatedApp {
    let id: Int
    let slug: String
    let credentials: AppCredentials
    let owner: String
    let ownerIsOrganization: Bool
}

/// What `app create` made: the App, and the login signed in to it (nil when the sign-in did not finish, in which case
/// the App is stored alone and `app login` finishes).
struct CreatedAppResult {
    let slug: String
    let appId: Int
    let login: String?
    let installURL: String
}

func createApp(owner: String, name: String, openBrowser: Bool) throws -> CreatedAppResult {
    let web = try webBaseURL()
    let organization = try isOrganization(owner)
    let server = try LocalServer(port: callbackPort)
    let state = randomHex(bytes: 16)
    let local = "http://127.0.0.1:\(server.port)"
    let manifest: [String: Any] = [
        "name": name,
        "url": "https://github.com/\(owner)",
        "public": false,
        "redirect_url": "\(local)/created",
        "callback_urls": [callbackURL],
        "request_oauth_on_install": false,
        "default_permissions": manifestPermissions,
        "default_events": [String](),
    ]
    let settings = organization ? "\(web)/organizations/\(owner)/settings" : "\(web)/settings"
    let page = manifestPage(
        action: "\(settings)/apps/new?state=\(state)",
        manifest: String(decoding: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                         as: UTF8.self),
        title: "Create the GitHub App \(name) for \(owner)"
    )

    fputs(
        "To create the GitHub App \(name) for \(owner), open \(local)/ and choose Create GitHub App, then Authorize "
            + "(waiting up to an hour).\n",
        stderr
    )
    if openBrowser {
        openInBrowser("\(local)/")
    }
    let created = try server.awaitRequest(
        for: ["/created"],
        pages: ["/": page],
        deadline: Date().addingTimeInterval(manifestTimeout)
    )
    guard created.query["state"] == state, let code = created.query["code"], isManifestCode(code) else {
        respond(created.client, status: 400, text: "This is not the answer to gh-touchid's request; nothing was stored.")
        close(created.client)
        throw ToolError.refused("the callback did not carry this request's state and code; nothing was stored")
    }
    let app: CreatedApp
    do {
        app = try convertManifest(code: code)
    } catch {
        respond(created.client, status: 200, text: "Nothing was stored: \(error)")
        close(created.client)
        throw error
    }
    let advanced = "\(web)/\(app.ownerIsOrganization ? "organizations/\(app.owner)/settings" : "settings")"
        + "/apps/\(app.slug)/advanced"
    guard app.owner.lowercased() == owner else {
        let message = "GitHub created the App \(app.slug) for \(app.owner), not \(owner); nothing was stored. "
            + "Delete it at \(advanced)"
        respond(created.client, status: 200, text: message)
        close(created.client)
        throw ToolError.refused(message)
    }

    // on to the sign-in; the manifest page is no longer served, so that a reload cannot make a second App
    let request = try signInRequest(app: app.credentials)
    redirect(created.client, to: request.url)
    close(created.client)
    let install = "\(web)/apps/\(app.slug)/installations/new"
    let signIn: SignIn
    let browser: Int32
    do {
        (signIn, browser) = try awaitSignIn(
            request,
            app: app.credentials,
            owner: owner,
            server: server,
            deadline: Date().addingTimeInterval(signInTimeout)
        )
    } catch {
        // the App exists on GitHub: keep it, so that `app login` can finish what is left
        Notices.tell("you are not signed in to the new App \(app.slug): \(error)")
        try authenticate(.newApp(app.slug, owner: owner))
        // a sign-in to a previous App would not work with this one
        try withSignInLock(owner: owner) {
            try storeAppCredentials(app.credentials, owner: owner, slug: app.slug)
            _ = try? removeSignIn(owner: owner)
        }
        fputs(
            "Stored the GitHub App \(app.slug) (ID \(app.id)) for \(owner). Sign in to it with "
                + "`gh-touchid app login \(owner)`, and install it: \(install)\n",
            stderr
        )
        return CreatedAppResult(slug: app.slug, appId: app.id, login: nil, installURL: install)
    }
    defer { close(browser) }
    do {
        try authenticate(.signIn(signIn.login, owner: owner, app: app.slug, storesApp: true))
    } catch {
        respond(browser, status: 200, text: "Nothing was stored: \(error). Delete the App at \(advanced)")
        throw ToolError.refused("\(error); nothing was stored. Delete the App \(app.slug) at \(advanced)")
    }
    do {
        try storeSignedIn(signIn, app: app.credentials, slug: app.slug, owner: owner)
    } catch {
        respond(browser, status: 200, text: "\(error)")
        throw error
    }
    redirect(browser, to: install)
    appendAccessLog("stored the \(owner) App \(app.slug) and signed in as \(signIn.login)")
    fputs(
        "Stored the GitHub App \(app.slug) (ID \(app.id)) for \(owner) and signed you in to it as \(signIn.login).\n"
            + "Install it on the repositories agents should reach: \(install)\n",
        stderr
    )
    return CreatedAppResult(slug: app.slug, appId: app.id, login: signIn.login, installURL: install)
}

/// `POST /app-manifests/{code}/conversions`, which needs no credential: the new App's settings and secrets. Its reply
/// holds the App's private key and secrets, so no part of it goes into an error.
private func convertManifest(code: String) throws -> CreatedApp {
    let response = try githubAPI("POST", "/app-manifests/\(code)/conversions", bearer: nil)
    guard response.status == 201 else {
        throw ToolError.github("GitHub did not hand over the new App (HTTP \(response.status))")
    }
    guard let object = response.object,
          let id = object["id"] as? Int,
          let slug = object["slug"] as? String, validOwner(slug) != nil,
          let clientId = object["client_id"] as? String, !clientId.isEmpty,
          let clientSecret = object["client_secret"] as? String, !clientSecret.isEmpty,
          let owner = object["owner"] as? [String: Any],
          let login = owner["login"] as? String, validOwner(login) != nil else {
        throw ToolError.github(
            "GitHub's reply with the new App (HTTP 201) lacks its ID, slug, client ID, client secret or owner; "
                + "nothing was stored"
        )
    }
    return CreatedApp(
        id: id,
        slug: slug,
        credentials: AppCredentials(clientId: printable(clientId), clientSecret: clientSecret),
        owner: login,
        ownerIsOrganization: owner["type"] as? String == "Organization"
    )
}

private func isManifestCode(_ code: String) -> Bool {
    !code.isEmpty && code.count <= 100 && code.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
}

/// A page that posts `manifest` to `action` as soon as it loads (or when its button is pressed).
private func manifestPage(action: String, manifest: String, title: String) -> String {
    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>\(htmlEscaped(title))</title></head>
    <body>
    <form method="post" action="\(htmlEscaped(action))">
    <input type="hidden" name="manifest" value="\(htmlEscaped(manifest))">
    <p>\(htmlEscaped(title)): continuing to GitHub…</p>
    <button type="submit">Continue to GitHub</button>
    </form>
    <script>document.forms[0].submit()</script>
    </body></html>
    """
}

/// How long `reader create` waits for the reader's installation once it is stored.
private let readerInstallTimeout: TimeInterval = {
#if GH_TOUCHID_TESTING
    return ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_INSTALL_TIMEOUT"].flatMap(Double.init) ?? 15 * 60
#else
    return 15 * 60
#endif
}()

/// How often `reader create` asks GitHub whether the reader is installed.
private let readerInstallPoll: TimeInterval = {
#if GH_TOUCHID_TESTING
    return 0.2
#else
    return 3
#endif
}()

/// What `reader create` made and stored.
struct CreatedReader {
    let slug: String
    let appId: Int
    let owner: String
    let installURL: String
}

/// The reader App as GitHub's manifest conversion describes it. `pem` is its private key: no part of this goes into
/// an error.
private struct ConvertedReader {
    let id: Int
    let slug: String
    let owner: String
    let ownerType: String
    /// nil when GitHub did not say.
    let permissions: [String: Any]?
    let pem: String
}

/// `reader create`: makes the reader through the manifest flow, stores it after Touch ID, waits for its installation,
/// and proves it with one checked, revoked token. Refused with `readerExists` while a reader is stored.
func createReader(name: String, openBrowser: Bool, progress: (String) -> Void) throws -> CreatedReader {
    if hasReader() {
        throw ToolError.readerExists(readerLabel()?.slug ?? "reader")
    }
    let web = try webBaseURL()
    let server = try LocalServer(port: callbackPort)
    let state = randomHex(bytes: 16)
    let local = "http://127.0.0.1:\(server.port)"
    let manifest: [String: Any] = [
        "name": name,
        "url": "https://github.com/georgelubaretsi/gh-touchid",
        "public": false,
        "redirect_url": "\(local)/created",
        "setup_url": "\(local)/installed",
        "request_oauth_on_install": false,
        "default_permissions": [String: String](),
        "default_events": [String](),
    ]
    let page = manifestPage(
        action: "\(web)/settings/apps/new?state=\(state)",
        manifest: String(decoding: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                         as: UTF8.self),
        title: "Create the reader App \(name)"
    )
    progress("To create the reader App \(name), open \(local)/ and choose Create GitHub App (waiting up to an hour).")
    if openBrowser {
        openInBrowser("\(local)/")
    }
    let created = try server.awaitRequest(
        for: ["/created"],
        pages: ["/": page],
        deadline: Date().addingTimeInterval(manifestTimeout)
    )
    var answered = false
    /// Answers the browser with `message` and returns the refusal to throw.
    func refuse(_ message: String) -> ToolError {
        if !answered {
            respond(created.client, status: 200, text: message)
            close(created.client)
            answered = true
        }
        return ToolError.refused(message)
    }
    guard created.query["state"] == state, let code = created.query["code"], isManifestCode(code) else {
        respond(created.client, status: 400, text: "This is not the answer to gh-touchid's request; nothing was stored.")
        close(created.client)
        throw ToolError.refused("the callback did not carry this request's state and code; nothing was stored")
    }
    let reader: ConvertedReader
    do {
        reader = try convertReaderManifest(code: code)
    } catch {
        throw refuse("\(error)")
    }
    let settings = reader.ownerType == "Organization" ? "organizations/\(reader.owner)/settings" : "settings"
    let delete = "\(web)/\(settings)/apps/\(reader.slug)/advanced"
    guard reader.ownerType == "User" else {
        throw refuse(
            "GitHub made the reader \(reader.slug) for \(reader.owner), which is not a user account; nothing was "
                + "stored. Delete it at \(delete)"
        )
    }
    guard let permissions = reader.permissions, permissions.isEmpty else {
        let named = reader.permissions.map { $0.keys.sorted().joined(separator: ", ") } ?? "not said"
        throw refuse(
            "GitHub gave the reader \(reader.slug) permissions (\(printable(named))); nothing was stored. "
                + "Delete it at \(delete)"
        )
    }
    let key: AppPrivateKey
    do {
        key = try AppPrivateKey(pem: reader.pem)
    } catch {
        throw refuse("GitHub's key for the reader \(reader.slug) is not a PKCS#1 RSA key; nothing was stored. "
            + "Delete it at \(delete)")
    }
    let label = ReaderLabel(slug: reader.slug, owner: reader.owner)
    do {
        try authenticate(.reader(reader.slug, owner: reader.owner, replacing: nil))
    } catch {
        throw refuse("\(error); nothing was stored. Delete the App \(reader.slug) at \(delete)")
    }
    // another `reader create` or `reader add` may have stored one while this one waited for the browser
    if hasReader() {
        throw refuse(
            "\(ToolError.readerExists(readerLabel()?.slug ?? "reader")); nothing was stored. Delete the App "
                + "\(reader.slug) at \(delete)"
        )
    }
    do {
        try storeReader(ReaderSecret(appId: reader.id, privateKey: reader.pem), label: label)
    } catch {
        throw refuse("\(error)")
    }
    appendAccessLog("stored the reader \(reader.slug) (ID \(reader.id)) of \(reader.owner)")
    let install = try readerInstallURL(slug: reader.slug)
    redirect(created.client, to: install)
    close(created.client)
    answered = true
    progress(
        "Stored the reader \(reader.slug) (ID \(reader.id)). Install it on \(reader.owner) with no repository: "
            + "\(install) (waiting up to \(durationWords(readerInstallTimeout)))."
    )
    try awaitReaderInstallation(key: key, appId: reader.id, label: label, server: server, installURL: install)
    try testReader(key: key, appId: reader.id, label: label)
    appendAccessLog("checked the reader \(reader.slug): installed on \(reader.owner), no permissions, no repository")
    return CreatedReader(slug: reader.slug, appId: reader.id, owner: reader.owner, installURL: install)
}

/// Waits until GitHub lists the reader's installation, asking every `readerInstallPoll` seconds and at once when the
/// browser comes back from the installation page (the manifest's `setup_url`), which gets a page saying how it went.
/// Not installed in time: `readerNotInstalled`; the reader stays stored.
private func awaitReaderInstallation(
    key: AppPrivateKey,
    appId: Int,
    label: ReaderLabel,
    server: LocalServer,
    installURL: String
) throws {
    let deadline = Date().addingTimeInterval(readerInstallTimeout)
    var browser: Int32?
    func answer(_ text: String) {
        if let client = browser {
            respond(client, status: 200, text: text)
            close(client)
            browser = nil
        }
    }
    do {
        while true {
            if try readerInstallation(jwt: key.jwt(appId: appId), appId: appId, label: label) != nil {
                // GitHub sends the browser back right after installing: a moment's wait gives it a page instead of a
                // closed connection
                if browser == nil, let back = try? server.awaitRequest(
                    for: ["/installed"],
                    deadline: Date().addingTimeInterval(5)
                ) {
                    browser = back.client
                }
                answer("The reader \(label.slug) is installed; you can close this page.")
                return
            }
            guard Date() < deadline else {
                throw ToolError.readerNotInstalled(installURL)
            }
            // the wait between two questions; it ends early when the browser comes back from the installation
            let next = min(deadline, Date().addingTimeInterval(readerInstallPoll))
            if let back = try? server.awaitRequest(for: ["/installed"], deadline: next) {
                answer("Still waiting for GitHub to list the installation.")
                browser = back.client
            }
        }
    } catch {
        answer("\(error)")
        throw error
    }
}

/// `POST /app-manifests/{code}/conversions` for the reader: its ID, slug, owner, permissions and private key; the
/// client secret and webhook secret are dropped. The reply holds secrets, so no part of it goes into an error.
private func convertReaderManifest(code: String) throws -> ConvertedReader {
    let response = try githubAPI("POST", "/app-manifests/\(code)/conversions", bearer: nil)
    guard response.status == 201 else {
        throw ToolError.github("GitHub did not hand over the new reader App (HTTP \(response.status))")
    }
    guard let object = response.object,
          let id = object["id"] as? Int, id > 0,
          let slug = (object["slug"] as? String).flatMap(validOwner),
          let owner = object["owner"] as? [String: Any],
          let login = (owner["login"] as? String).flatMap(validOwner),
          let pem = object["pem"] as? String, !pem.isEmpty else {
        throw ToolError.github(
            "GitHub's reply with the new reader App (HTTP 201) lacks its ID, slug, owner or key; nothing was stored"
        )
    }
    return ConvertedReader(
        id: id,
        slug: slug,
        owner: login,
        ownerType: printable(owner["type"] as? String ?? "unknown", limit: 40),
        permissions: object["permissions"] as? [String: Any],
        pem: pem
    )
}
