import Darwin
import Foundation
import Security

// `app create <owner>`: GitHub's App manifest flow. A one-off web server on 127.0.0.1 serves a page that posts the
// manifest to GitHub; once you choose Create GitHub App there, GitHub sends the browser back to the server with a code
// and the `state` it was given, and the code buys the App's ID, client ID and private key. Only the client ID and key
// are kept (in the Keychain, as `app set` does); the client and webhook secrets are dropped.

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

/// How long the flow may take; GitHub's codes last an hour too.
private let manifestTimeout: TimeInterval = 60 * 60

private struct CreatedApp {
    let id: Int
    let slug: String
    let clientId: String
    let pem: String
    let owner: String
    let ownerIsOrganization: Bool
}

func createApp(owner: String, name: String, openBrowser: Bool) throws -> Int32 {
    let web = try webBaseURL()
    let organization = try isOrganization(owner)
    let server = try CallbackServer()
    let state = randomHex(bytes: 16)
    let local = "http://127.0.0.1:\(server.port)"
    let manifest: [String: Any] = [
        "name": name,
        "url": "https://github.com/\(owner)",
        "public": false,
        "redirect_url": "\(local)/callback",
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
        "To create the GitHub App \(name) for \(owner), open \(local)/ and choose Create GitHub App on GitHub "
            + "(waiting up to an hour).\n",
        stderr
    )
    if openBrowser {
        openInBrowser("\(local)/")
    }
    let (client, query) = try server.awaitCallback(page: page, deadline: Date().addingTimeInterval(manifestTimeout))
    guard query["state"] == state, let code = query["code"], isManifestCode(code) else {
        respond(client, status: 400, text: "This is not the answer to gh-touchid's request; nothing was stored.")
        close(client)
        throw ToolError.refused("the callback did not carry this request's state and code; nothing was stored")
    }
    respond(client, status: 200, text: "GitHub created the App. Finish in the terminal.")
    close(client)

    let app = try convertManifest(code: code)
    guard app.owner.lowercased() == owner else {
        let path = app.ownerIsOrganization ? "organizations/\(app.owner)/settings" : "settings"
        throw ToolError.refused(
            "GitHub created the App \(app.slug) for \(app.owner), not \(owner); nothing was stored. "
                + "Delete it at \(web)/\(path)/apps/\(app.slug)/advanced"
        )
    }
    let key = try rsaPrivateKey(pem: app.pem)
    try authenticate(.newApp(app.slug, owner: owner))
    _ = try verifyAppKey(clientId: app.clientId, key: key)
    try storeAppCredentials(AppCredentials(clientId: app.clientId, privateKey: app.pem), owner: owner)
    let install = "\(web)/apps/\(app.slug)/installations/new"
    fputs(
        "Stored the GitHub App \(app.slug) (ID \(app.id)) for \(owner); GitHub accepted its key.\n"
            + "Install it on the repositories agents should reach: \(install)\n",
        stderr
    )
    if openBrowser {
        openInBrowser(install)
    }
    return 0
}

/// `POST /app-manifests/{code}/conversions`, which needs no credential: the new App's settings and private key. Its
/// reply holds the key and the App's secrets, so no part of it goes into an error.
private func convertManifest(code: String) throws -> CreatedApp {
    let response = try githubAPI("POST", "/app-manifests/\(code)/conversions", bearer: nil)
    guard response.status == 201 else {
        throw ToolError.github("GitHub did not hand over the new App (HTTP \(response.status))")
    }
    guard let object = response.object,
          let id = object["id"] as? Int,
          let slug = object["slug"] as? String, validOwner(slug) != nil,
          let clientId = object["client_id"] as? String, !clientId.isEmpty,
          let pem = object["pem"] as? String,
          let owner = object["owner"] as? [String: Any],
          let login = owner["login"] as? String, validOwner(login) != nil else {
        throw ToolError.github(
            "GitHub's reply with the new App (HTTP 201) lacks its ID, slug, client ID, key or owner; nothing was stored"
        )
    }
    return CreatedApp(
        id: id,
        slug: slug,
        clientId: printable(clientId),
        pem: pem,
        owner: login,
        ownerIsOrganization: owner["type"] as? String == "Organization"
    )
}

private func isManifestCode(_ code: String) -> Bool {
    !code.isEmpty && code.count <= 100 && code.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
}

private func randomHex(bytes count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        fatalError("no random bytes")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func htmlEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
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

private func respond(_ client: Int32, status: Int, html: String) {
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
    let body = Data(html.utf8)
    let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
        + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        + "Connection: close\r\n\r\n"
    _ = writeAll(client, Data(head.utf8) + body)
}

private func respond(_ client: Int32, status: Int, text: String) {
    respond(client, status: status, html: "<!doctype html><meta charset=\"utf-8\"><p>gh-touchid: \(htmlEscaped(text))</p>")
}

/// A one-off HTTP server on 127.0.0.1 and a random port: `/` serves the manifest page, `/callback` ends it.
private final class CallbackServer {
    let port: Int
    private let listener: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ToolError.input("cannot create a socket")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard listening else {
            close(fd)
            throw ToolError.input("cannot listen on 127.0.0.1")
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        close(listener)
    }

    /// Serves `page` until the first request for `/callback`, and returns that connection with its query.
    func awaitCallback(page: String, deadline: Date) throws -> (Int32, [String: String]) {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ToolError.refused("GitHub did not send the browser back within an hour; nothing was stored")
            }
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(min(remaining, 60) * 1000)) > 0 else {
                continue
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                continue
            }
            configureSocket(client, timeoutSeconds: 10)
            guard let target = requestTarget(client), let components = URLComponents(string: target) else {
                respond(client, status: 400, text: "Bad request.")
                close(client)
                continue
            }
            switch components.path {
            case "/":
                respond(client, status: 200, html: page)
                close(client)
            case "/callback":
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] {
                    query[item.name] = item.value ?? ""
                }
                return (client, query)
            default:
                respond(client, status: 404, text: "Not found.")
                close(client)
            }
        }
    }

    /// The target of a `GET` request (`/callback?code=…`), from its request line.
    private func requestTarget(_ client: Int32) -> String? {
        var head = Data()
        var byte: UInt8 = 0
        let end = Data("\r\n\r\n".utf8)
        while head.count < 16384, !head.hasSuffix(end) {
            guard read(client, &byte, 1) == 1 else {
                return nil
            }
            head.append(byte)
        }
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else {
            return nil
        }
        return String(parts[1])
    }
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        count >= suffix.count && self.suffix(suffix.count) == suffix
    }
}
