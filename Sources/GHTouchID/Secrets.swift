import Darwin
import Foundation
import Security

// Secrets live in the login Keychain as generic passwords (test builds: in files under GH_TOUCHID_TEST_DIR).
// - service `com.lubaretsi.gh-touchid.app`, account = owner: the owner's GitHub App as JSON {clientId, privateKey}
// - service `com.lubaretsi.gh-touchid`, account = owner: the owner's own token, used by `me`
// Accounts are lowercase owners. Items of gh-touchid 0.2 used `owner/repo` accounts; nothing reads them any more.

private let ownTokenService = "com.lubaretsi.gh-touchid"
private let appService = "com.lubaretsi.gh-touchid.app"

struct AppCredentials: Codable {
    let clientId: String
    let privateKey: String
}

func storeAppCredentials(_ credentials: AppCredentials, owner: String) throws {
    let data = try JSONEncoder().encode(credentials)
    try storeSecret(data, service: appService, account: owner, label: "gh-touchid App for \(owner)")
}

func loadAppCredentials(owner: String) throws -> AppCredentials {
    guard let data = try loadSecret(service: appService, account: owner) else {
        throw ToolError.missingApp(owner)
    }
    guard let credentials = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
        throw ToolError.keychain("the stored App for \(owner) is not valid; run `gh-touchid app set` again")
    }
    return credentials
}

func storeOwnToken(_ token: String, owner: String) throws {
    try storeSecret(Data(token.utf8), service: ownTokenService, account: owner, label: "gh-touchid \(owner)")
}

func loadOwnToken(owner: String) throws -> String {
    guard let data = try loadSecret(service: ownTokenService, account: owner) else {
        throw ToolError.missingOwnToken(owner)
    }
    guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
        throw ToolError.keychain("the stored token for \(owner) is not valid UTF-8")
    }
    return token
}

#if GH_TOUCHID_TESTING

private func secretPath(service: String, account: String) -> String {
    ((testDirectory as NSString).appendingPathComponent("secrets/\(service)") as NSString)
        .appendingPathComponent(account)
}

private func storeSecret(_ data: Data, service: String, account: String, label _: String) throws {
    let path = secretPath(service: service, account: account)
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw ToolError.keychain("cannot write \(path)")
    }
}

private func loadSecret(service: String, account: String) throws -> Data? {
    FileManager.default.contents(atPath: secretPath(service: service, account: account))
}

#else

private func keychainError(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
        return "\(message) (\(status))"
    }
    return "OSStatus \(status)"
}

private func storeSecret(_ data: Data, service: String, account: String, label: String) throws {
    let lookup: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]

    let update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrLabel as String: label,
    ]

    let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw ToolError.keychain(keychainError(updateStatus))
    }

    var add = lookup
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = label
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    add[kSecAttrSynchronizable as String] = false

    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw ToolError.keychain(keychainError(addStatus))
    }
}

/// The item's data, or nil when there is none.
private func loadSecret(service: String, account: String) throws -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        return nil
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(keychainError(status))
    }
    guard let data = item as? Data else {
        throw ToolError.keychain("the item for \(account) has no data")
    }
    return data
}

#endif
