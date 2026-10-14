import Darwin
import Foundation
import Security

// Secrets live in the login Keychain as generic passwords (test builds: in files under GH_TOUCHID_TEST_DIR).
// - service `com.lubaretsi.gh-touchid.app`, account = owner: the owner's GitHub App as JSON {clientId, privateKey}
// - service `com.lubaretsi.gh-touchid.user`, account = login: a token of one of your GitHub accounts, used by `as`
// Accounts are lowercase. Items of gh-touchid 0.2 (service `com.lubaretsi.gh-touchid`) are no longer read.
// Listing and existence checks read attributes only, never a secret.

private let appService = "com.lubaretsi.gh-touchid.app"
private let userService = "com.lubaretsi.gh-touchid.user"

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

func hasAppCredentials(owner: String) -> Bool {
    hasSecret(service: appService, account: owner)
}

/// Owners with a stored App.
func storedAppOwners() throws -> [String] {
    try storedAccounts(service: appService)
}

func storeUserToken(_ token: String, login: String) throws {
    try storeSecret(Data(token.utf8), service: userService, account: login, label: "gh-touchid account \(login)")
}

func loadUserToken(login: String) throws -> String {
    guard let data = try loadSecret(service: userService, account: login) else {
        throw ToolError.missingAccount(login)
    }
    guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
        throw ToolError.keychain("the stored token for \(login) is not valid UTF-8")
    }
    return token
}

func hasUserToken(login: String) -> Bool {
    hasSecret(service: userService, account: login)
}

/// Removes the token of `login`; false when none was stored.
func removeUserToken(login: String) throws -> Bool {
    try deleteSecret(service: userService, account: login)
}

/// Logins of your accounts with a stored token.
func storedUserLogins() throws -> [String] {
    try storedAccounts(service: userService)
}

#if GH_TOUCHID_TESTING

private func serviceDirectory(_ service: String) -> String {
    (testDirectory as NSString).appendingPathComponent("secrets/\(service)")
}

private func secretPath(service: String, account: String) -> String {
    (serviceDirectory(service) as NSString).appendingPathComponent(account)
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

private func hasSecret(service: String, account: String) -> Bool {
    FileManager.default.fileExists(atPath: secretPath(service: service, account: account))
}

private func deleteSecret(service: String, account: String) throws -> Bool {
    let path = secretPath(service: service, account: account)
    guard FileManager.default.fileExists(atPath: path) else {
        return false
    }
    try FileManager.default.removeItem(atPath: path)
    return true
}

private func storedAccounts(service: String) throws -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: serviceDirectory(service))) ?? []).sorted()
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

/// Whether the item exists; reads its attributes, not its data, so the Keychain does not ask to reveal it.
private func hasSecret(service: String, account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
}

private func deleteSecret(service: String, account: String) throws -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
        return false
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(keychainError(status))
    }
    return true
}

/// The accounts of every item of `service`, from their attributes.
private func storedAccounts(service: String) throws -> [String] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound {
        return []
    }
    guard status == errSecSuccess else {
        throw ToolError.keychain(keychainError(status))
    }
    let attributes = items as? [[String: Any]] ?? []
    return attributes.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
}

#endif
