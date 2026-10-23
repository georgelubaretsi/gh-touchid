import Darwin
import Foundation
import Security

// Secrets live in the login Keychain as generic passwords (test builds: in files under GH_TOUCHID_TEST_DIR).
// - service `com.lubaretsi.gh-touchid.app`, account = owner: the owner's GitHub App as JSON {clientId, clientSecret},
//   and its slug as the item's comment
// - service `com.lubaretsi.gh-touchid.signin`, account = owner: your sign-in to that App as JSON {login, accessToken,
//   accessExpires, refreshToken, refreshExpires} (expiries in seconds since 1970), and the login as its comment
// - service `com.lubaretsi.gh-touchid.user`, account = login: a token of one of your GitHub accounts, used by `as`
// Every item's description says its format (`gh-touchid format 1`; see `itemFormat`). Accounts are lowercase.
// gh's own sign-in, service `gh:github.com`, is only looked up, to tell whether another gh is signed in.
// Listing, existence checks, the formats, the App's slug and the signed-in login read attributes only, never a secret.

/// The format gh-touchid writes its items in, kept in each item's description (Keychain Access shows it as the item's
/// kind), so that it can be read without the secret. An item without one was written by 0.4.0, in format 1. Whoever
/// changes what an item holds gives the format the next number and reads the earlier ones; a gh-touchid that finds an
/// item in a format above its own refuses it rather than misreading it.
let itemFormat = 1

private let formatPrefix = "gh-touchid format "
/// What every item's description says.
private let formatDescription = "\(formatPrefix)\(itemFormat)"

/// One of gh-touchid's items, as messages name it.
enum StoredItem: CustomStringConvertible {
    case app(owner: String)
    case signIn(owner: String)
    case account(login: String)

    fileprivate var service: String {
        switch self {
        case .app:
            return appService
        case .signIn:
            return signInService
        case .account:
            return userService
        }
    }

    fileprivate var account: String {
        switch self {
        case let .app(owner), let .signIn(owner):
            return owner
        case let .account(login):
            return login
        }
    }

    var description: String {
        switch self {
        case let .app(owner):
            return "App for \(owner)"
        case let .signIn(owner):
            return "sign-in to the \(owner) App"
        case let .account(login):
            return "token of \(login)"
        }
    }
}

/// The format `item` is stored in, read from its attributes; nil when there is no such item.
func storedFormat(_ item: StoredItem) -> Int? {
    guard hasSecret(service: item.service, account: item.account) else {
        return nil
    }
    guard let description = secretDescription(service: item.service, account: item.account),
          description.hasPrefix(formatPrefix), let format = Int(description.dropFirst(formatPrefix.count)),
          format > 0 else {
        return 1
    }
    return format
}

/// Refuses an item that a newer gh-touchid wrote; reads attributes only, so it may come before any dialog.
func checkFormat(_ item: StoredItem) throws {
    if let format = storedFormat(item), format > itemFormat {
        throw ToolError.newerFormat(item: "\(item)", format: format)
    }
}

/// A development build (one with no pinned gh, outside tests) keeps its items under `com.lubaretsi.gh-touchid.dev.*`,
/// so that trying one never reads or replaces the Apps, sign-ins and tokens of an installed gh-touchid.
private let servicePrefix: String = {
#if GH_TOUCHID_TESTING
    return "com.lubaretsi.gh-touchid"
#else
    return pinnedGitHubCLI.hasPrefix("@") ? "com.lubaretsi.gh-touchid.dev" : "com.lubaretsi.gh-touchid"
#endif
}()
private let appService = "\(servicePrefix).app"
private let signInService = "\(servicePrefix).signin"
private let userService = "\(servicePrefix).user"

/// The owner's GitHub App as gh-touchid uses it: the OAuth client you sign in to, which narrows your tokens.
struct AppCredentials: Codable {
    let clientId: String
    let clientSecret: String
}

/// Stores the owner's App; `slug` (from GitHub) is what the approval window calls it.
func storeAppCredentials(_ credentials: AppCredentials, owner: String, slug: String?) throws {
    let data = try JSONEncoder().encode(credentials)
    let label = "gh-touchid App for \(owner)"
    try storeSecret(data, service: appService, account: owner, label: label, comment: slug ?? "")
}

func loadAppCredentials(owner: String) throws -> AppCredentials {
    try checkFormat(.app(owner: owner))
    guard let data = try loadSecret(service: appService, account: owner) else {
        throw ToolError.missingApp(owner)
    }
    guard let credentials = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
        throw ToolError.keychain("the stored App for \(owner) is not valid; run `gh-touchid app create \(owner)` again")
    }
    return credentials
}

func hasAppCredentials(owner: String) -> Bool {
    hasSecret(service: appService, account: owner)
}

/// The slug of the owner's stored App, read from its attributes; nil when it was stored without one.
func appSlug(owner: String) -> String? {
    secretComment(service: appService, account: owner).flatMap(validOwner)
}

/// Owners with a stored App.
func storedAppOwners() throws -> [String] {
    try storedAccounts(service: appService)
}

/// Your sign-in to an owner's App: an expiring user access token and the refresh token that renews it.
struct SignIn: Codable {
    let login: String
    let accessToken: String
    /// Seconds since 1970.
    let accessExpires: TimeInterval
    let refreshToken: String
    /// Seconds since 1970.
    let refreshExpires: TimeInterval
}

func storeSignIn(_ signIn: SignIn, owner: String) throws {
    let data = try JSONEncoder().encode(signIn)
    let label = "gh-touchid sign-in for \(owner)"
    try storeSecret(data, service: signInService, account: owner, label: label, comment: signIn.login)
}

func loadSignIn(owner: String) throws -> SignIn {
    try checkFormat(.signIn(owner: owner))
    guard let data = try loadSecret(service: signInService, account: owner) else {
        throw ToolError.notSignedIn(owner)
    }
    guard let signIn = try? JSONDecoder().decode(SignIn.self, from: data) else {
        throw ToolError.keychain("the stored sign-in for \(owner) is not valid; run `gh-touchid app login \(owner)`")
    }
    return signIn
}

func hasSignIn(owner: String) -> Bool {
    hasSecret(service: signInService, account: owner)
}

/// The login signed in to the owner's App, read from its attributes; nil when nobody is.
func signedInLogin(owner: String) -> String? {
    secretComment(service: signInService, account: owner).flatMap(validOwner)
}

/// Removes the owner's sign-in; false when none was stored.
func removeSignIn(owner: String) throws -> Bool {
    try deleteSecret(service: signInService, account: owner)
}

func storeUserToken(_ token: String, login: String) throws {
    let label = "gh-touchid account \(login)"
    try storeSecret(Data(token.utf8), service: userService, account: login, label: label, comment: nil)
}

func loadUserToken(login: String) throws -> String {
    try checkFormat(.account(login: login))
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

/// The accounts of gh's own items for github.com (service `gh:github.com`, account = login, empty for older gh), read
/// from their attributes: any means a gh is signed in with its token in the Keychain.
func gitHubCLIKeychainAccounts() -> [String] {
    (try? storedAccounts(service: "gh:github.com")) ?? []
}

#if GH_TOUCHID_TESTING

private func serviceDirectory(_ service: String) -> String {
    (testDirectory as NSString).appendingPathComponent("secrets/\(service)")
}

private func secretPath(service: String, account: String) -> String {
    (serviceDirectory(service) as NSString).appendingPathComponent(account)
}

private func commentPath(service: String, account: String) -> String {
    (testDirectory as NSString).appendingPathComponent("comments/\(service)/\(account)")
}

/// Where a test build keeps an item's description, which says its format.
private func descriptionPath(service: String, account: String) -> String {
    (testDirectory as NSString).appendingPathComponent("descriptions/\(service)/\(account)")
}

private func storeSecret(_ data: Data, service: String, account: String, label _: String, comment: String?) throws {
    for (path, contents) in [(secretPath(service: service, account: account), data),
                             (commentPath(service: service, account: account), comment.map { Data($0.utf8) }),
                             (descriptionPath(service: service, account: account), Data(formatDescription.utf8))] {
        guard let contents else {
            continue
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: path, contents: contents, attributes: attributes) else {
            throw ToolError.keychain("cannot write \(path)")
        }
    }
}

private func loadSecret(service: String, account: String) throws -> Data? {
    FileManager.default.contents(atPath: secretPath(service: service, account: account))
}

private func hasSecret(service: String, account: String) -> Bool {
    FileManager.default.fileExists(atPath: secretPath(service: service, account: account))
}

private func secretComment(service: String, account: String) -> String? {
    FileManager.default.contents(atPath: commentPath(service: service, account: account))
        .map { String(decoding: $0, as: UTF8.self) }
}

private func secretDescription(service: String, account: String) -> String? {
    FileManager.default.contents(atPath: descriptionPath(service: service, account: account))
        .map { String(decoding: $0, as: UTF8.self) }
}

private func deleteSecret(service: String, account: String) throws -> Bool {
    let path = secretPath(service: service, account: account)
    guard FileManager.default.fileExists(atPath: path) else {
        return false
    }
    try FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: commentPath(service: service, account: account))
    try? FileManager.default.removeItem(atPath: descriptionPath(service: service, account: account))
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

/// Stores the item's data, label and format, and its comment unless `comment` is nil.
private func storeSecret(_ data: Data, service: String, account: String, label: String, comment: String?) throws {
    let lookup: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]

    var update: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrLabel as String: label,
        kSecAttrDescription as String: formatDescription,
    ]
    update[kSecAttrComment as String] = comment

    let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw ToolError.keychain(keychainError(updateStatus))
    }

    var add = lookup.merging(update) { $1 }
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

/// The item's comment, from its attributes; nil when there is no item or no comment.
private func secretComment(service: String, account: String) -> String? {
    secretAttribute(kSecAttrComment, service: service, account: account)
}

/// The item's description, which says its format, from its attributes; nil when there is no item or none.
private func secretDescription(service: String, account: String) -> String? {
    secretAttribute(kSecAttrDescription, service: service, account: account)
}

private func secretAttribute(_ key: CFString, service: String, account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
        return nil
    }
    return (item as? [String: Any])?[key as String] as? String
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
