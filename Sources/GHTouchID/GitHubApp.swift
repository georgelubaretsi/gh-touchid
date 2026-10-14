import Foundation
import Security

// Tokens from the owner's GitHub App: a JWT signed with the App's key finds the repository's installation, which then
// issues a token for that one repository (about an hour long). Nothing is cached; every use mints its own token.

struct InstallationToken {
    let token: String
    let expires: Date
}

/// The App's private key from a PKCS#1 PEM (`-----BEGIN RSA PRIVATE KEY-----`), the format GitHub hands out.
func rsaPrivateKey(pem: String) throws -> SecKey {
    let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
    let begin = "-----BEGIN RSA PRIVATE KEY-----"
    let end = "-----END RSA PRIVATE KEY-----"
    guard text.hasPrefix(begin), text.hasSuffix(end) else {
        if text.hasPrefix("-----BEGIN "), let label = text.split(separator: "\n").first {
            throw ToolError.input(
                "the key starts with \(label); gh-touchid needs the PKCS#1 key GitHub downloads, "
                    + "which starts with \(begin)"
            )
        }
        throw ToolError.input("the private key must be a PEM file starting with \(begin)")
    }
    let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
    guard let der = Data(base64Encoded: String(body)) else {
        throw ToolError.input("the private key is not valid base64 (an encrypted key is not supported)")
    }
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
        let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
        throw ToolError.input("the private key is not a valid RSA key: \(reason)")
    }
    return key
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// An RS256 JWT that authenticates as the App for nine minutes.
private func appJWT(clientId: String, key: SecKey) throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
    let payload = try JSONSerialization.data(
        withJSONObject: ["iat": now - 60, "exp": now + 540, "iss": clientId],
        options: [.sortedKeys]
    )
    let signingInput = base64URL(header) + "." + base64URL(payload)
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
        key,
        .rsaSignatureMessagePKCS1v15SHA256,
        Data(signingInput.utf8) as CFData,
        &error
    ) as Data? else {
        let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
        throw ToolError.github("cannot sign the App's JWT: \(reason)")
    }
    return signingInput + "." + base64URL(signature)
}

private struct APIResponse {
    let status: Int
    let body: Data

    var object: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// GitHub's error message, for error reports.
    var message: String {
        if let message = object?["message"] as? String {
            return printable(message)
        }
        return printable(String(decoding: body.prefix(200), as: UTF8.self))
    }
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

/// One synchronous request to the GitHub API; nothing is cached or stored.
private func githubAPI(
    _ method: String,
    _ path: String,
    bearer: String,
    body: [String: Any]? = nil
) throws -> APIResponse {
    guard let url = URL(string: try apiBaseURL() + path) else {
        throw ToolError.github("cannot build the API URL for \(path)")
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("gh-touchid", forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let box = ResponseBox()
    let semaphore = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, response, error in
        box.data = data
        box.response = response
        box.error = error
        semaphore.signal()
    }.resume()
    semaphore.wait()

    if let error = box.error {
        throw ToolError.github("cannot reach GitHub (\(method) \(path)): \(error.localizedDescription)")
    }
    guard let response = box.response as? HTTPURLResponse else {
        throw ToolError.github("GitHub sent no HTTP response to \(method) \(path)")
    }
    return APIResponse(status: response.statusCode, body: box.data ?? Data())
}

/// Checks the App's key with GitHub (`GET /app`) and returns the App's name.
func verifyAppKey(clientId: String, key: SecKey) throws -> String {
    let response = try githubAPI("GET", "/app", bearer: appJWT(clientId: clientId, key: key))
    guard response.status == 200 else {
        throw ToolError.github(
            "GitHub did not accept this key for the App with client ID \(clientId) "
                + "(HTTP \(response.status): \(response.message))"
        )
    }
    let object = response.object
    return (object?["slug"] as? String) ?? (object?["name"] as? String) ?? "GitHub"
}

/// A token for one repository from its owner's App; it includes `workflows` only when `includeWorkflows`.
func mintInstallationToken(repository: String, includeWorkflows: Bool) throws -> InstallationToken {
    let owner = String(repository.split(separator: "/")[0])
    let credentials = try loadAppCredentials(owner: ownerAccount(repository))
    let jwt = try appJWT(clientId: credentials.clientId, key: rsaPrivateKey(pem: credentials.privateKey))

    let installation = try githubAPI("GET", "/repos/\(repository)/installation", bearer: jwt)
    if installation.status == 404 {
        throw ToolError.github("the \(owner) App is not installed on \(repository)")
    }
    guard installation.status == 200,
          let id = installation.object?["id"] as? Int,
          var permissions = installation.object?["permissions"] as? [String: Any] else {
        throw ToolError.github(
            "cannot find the \(owner) App's installation on \(repository) "
                + "(HTTP \(installation.status): \(installation.message))"
        )
    }
    if !includeWorkflows {
        permissions.removeValue(forKey: "workflows")
    }

    let created = try githubAPI(
        "POST",
        "/app/installations/\(id)/access_tokens",
        bearer: jwt,
        body: ["repositories": [repositoryName(repository)], "permissions": permissions]
    )
    guard created.status == 201,
          let token = created.object?["token"] as? String, !token.isEmpty,
          let expiresText = created.object?["expires_at"] as? String,
          let expires = ISO8601DateFormatter().date(from: expiresText) else {
        throw ToolError.github(
            "GitHub did not issue a token for \(repository) (HTTP \(created.status): \(created.message))"
        )
    }
    return InstallationToken(token: token, expires: expires)
}

/// Ends an installation token early (`DELETE /installation/token`).
func revokeInstallationToken(_ token: String) throws {
    let response = try githubAPI("DELETE", "/installation/token", bearer: token)
    guard response.status == 204 else {
        throw ToolError.github("HTTP \(response.status): \(response.message)")
    }
}
