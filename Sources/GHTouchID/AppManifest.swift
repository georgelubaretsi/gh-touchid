import Darwin
import Foundation

// `app create <owner>`: GitHub's App manifest flow, then the sign-in, in one trip of the browser. The local server on
// the callback port serves a page that posts the manifest to GitHub; once you choose Create GitHub App there, GitHub
// sends the browser to /created with a code and the `state` it was given. The code buys the App's client ID and
// client secret (its private key and webhook secret are dropped: the App never acts as itself), and the browser goes
// on to GitHub's authorize page for the new App. After you choose Authorize, one Touch ID stores the App and your
// sign-in, and the browser goes on to the App's installation page.

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

func createApp(owner: String, name: String, openBrowser: Bool) throws -> Int32 {
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
        fputs("You are not signed in to the new App \(app.slug): \(error)\n", stderr)
        try authenticate(.newApp(app.slug, owner: owner))
        try storeAppCredentials(app.credentials, owner: owner, slug: app.slug)
        fputs(
            "Stored the GitHub App \(app.slug) (ID \(app.id)) for \(owner). Sign in to it with "
                + "`gh-touchid app login \(owner)`, and install it: \(install)\n",
            stderr
        )
        return 1
    }
    defer { close(browser) }
    do {
        try authenticate(.signIn(signIn.login, owner: owner, app: app.slug, storesApp: true))
        try storeAppCredentials(app.credentials, owner: owner, slug: app.slug)
        try storeSignIn(signIn, owner: owner)
    } catch {
        respond(browser, status: 200, text: "Nothing was stored: \(error). Delete the App at \(advanced)")
        throw ToolError.refused("\(error); nothing was stored. Delete the App \(app.slug) at \(advanced)")
    }
    redirect(browser, to: install)
    appendAccessLog("stored the \(owner) App \(app.slug) and signed in as \(signIn.login)")
    fputs(
        "Stored the GitHub App \(app.slug) (ID \(app.id)) for \(owner) and signed you in to it as \(signIn.login).\n"
            + "Install it on the repositories agents should reach: \(install)\n",
        stderr
    )
    try offerGitSetup(owner: app.owner)
    return 0
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
