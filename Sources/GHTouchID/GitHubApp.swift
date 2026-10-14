import Foundation
import Security

// Tokens from the owner's GitHub App: a JWT signed with the App's key finds the repository's installation, which then
// issues a token for that one repository (about an hour long). Nothing is cached; every use mints its own token.

struct InstallationToken {
    let token: String
    let expires: Date
    /// Whether the repository is private, when GitHub said so in its reply.
    let isPrivate: Bool?
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

/// Checks the App's key with GitHub (`GET /app`) and returns the App's slug (nil when the reply lacks a valid one) and
/// its name for messages.
func verifyAppKey(clientId: String, key: SecKey) throws -> (slug: String?, name: String) {
    let response = try githubAPI("GET", "/app", bearer: appJWT(clientId: clientId, key: key))
    guard response.status == 200 else {
        throw ToolError.github(
            "GitHub did not accept this key for the App with client ID \(clientId) "
                + "(HTTP \(response.status): \(response.message))"
        )
    }
    let object = response.object
    let slug = object?["slug"] as? String
    return (slug.flatMap(validOwner), slug ?? (object?["name"] as? String) ?? "GitHub")
}

/// What a token may do: the installation's permissions (without `workflows` unless the repository is elevated), or
/// just open issues and read the repository.
enum TokenScope {
    case installation(includeWorkflows: Bool)
    case issues

    static let issuePermissions = ["issues": "write", "metadata": "read", "contents": "read"]
}

/// A token for one repository from its owner's App.
func mintInstallationToken(repository: String, scope: TokenScope) throws -> InstallationToken {
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
    switch scope {
    case let .installation(includeWorkflows):
        if !includeWorkflows {
            permissions.removeValue(forKey: "workflows")
        }
    case .issues:
        permissions = TokenScope.issuePermissions
    }

    let created = try githubAPI(
        "POST",
        "/app/installations/\(id)/access_tokens",
        bearer: jwt,
        body: ["repositories": [repositoryName(repository)], "permissions": permissions]
    )
    guard created.status == 201 else {
        throw ToolError.github(
            "GitHub did not issue a token for \(repository) (HTTP \(created.status): \(created.message))"
        )
    }
    // the reply holds the token: no part of it goes into an error
    guard let token = created.object?["token"] as? String, !token.isEmpty else {
        throw ToolError.github("GitHub's reply with a token for \(repository) (HTTP 201) lacks the token")
    }
    guard let expiresText = created.object?["expires_at"] as? String,
          let expires = ISO8601DateFormatter().date(from: expiresText) else {
        // unusable without its expiry: end it now rather than leave it valid for an hour
        try? revokeInstallationToken(token)
        throw ToolError.github("GitHub's reply with a token for \(repository) (HTTP 201) lacks its expiry")
    }
    let listed = (created.object?["repositories"] as? [[String: Any]])?.first
    return InstallationToken(token: token, expires: expires, isPrivate: listed?["private"] as? Bool)
}

/// Ends an installation token early (`DELETE /installation/token`).
func revokeInstallationToken(_ token: String) throws {
    let response = try githubAPI("DELETE", "/installation/token", bearer: token)
    guard response.status == 204 else {
        throw ToolError.github("HTTP \(response.status): \(response.message)")
    }
}
