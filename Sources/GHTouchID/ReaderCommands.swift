import Darwin
import Foundation

// `reader create`, `reader add` and `reader remove`: the reader's operations, declared against the interfaces
// contract (Operations.swift). Creating and adding store the reader only after GitHub showed, with one token minted,
// checked and revoked, that the key works and that the App has no permissions and no repository, and after Touch ID.
// Removing takes access away, so `--yes` (or a terminal's yes) confirms it without Touch ID. The private key is a
// secret: it comes from stdin (never a terminal, never a flag) or from the `--input` document, and goes only to the
// Keychain; what is printed of it is its fingerprint.

/// The largest key `reader add` reads from stdin; GitHub's 2048-bit PEM keys are under 2 KiB.
private let privateKeyLimit = 64 * 1024

let readerOperations: [Operation] = [
    Operation(
        name: "reader_create",
        words: ["reader", "create"],
        title: "Create the reader",
        description: "`reader create` makes the reader: a GitHub App of yours with no permissions, installed on your "
            + "user account with no repository, whose tokens let gh read public data without Touch ID for owners "
            + "without an App and outside any repository. The browser makes the App on GitHub; one Touch ID stores "
            + "it; then the browser installs it and gh-touchid checks it with one token, revoked at once. Refused "
            + "while a reader is stored.",
        example: "gh-touchid reader create",
        positional: [],
        input: .object(
            properties: [
                ("name", .string(
                    pattern: "^[^\\u0000-\\u001f\\u007f]{1,100}$",
                    description: "The App's name on GitHub; by default gh-touchid-reader-<6 hex digits>."
                )),
                ("open_browser", .boolean(description: "Open the browser (default true); false prints the address.")),
            ],
            required: []
        ),
        output: .object(
            properties: [
                ("app", .string(description: "The reader App's slug; it acts as <slug>[bot].")),
                ("app_id", .integer(minimum: 1, description: "The reader App's ID.")),
                ("owner", .string(description: "The user account the reader belongs to and is installed on.")),
                ("installed", .boolean(description: "Whether GitHub lists its installation, checked with a token.")),
                ("install_url", .string(description: "GitHub's page for installing the reader.")),
            ],
            required: ["app", "app_id", "owner", "installed", "install_url"]
        ),
        annotations: Annotations(readOnly: false, destructive: false, idempotent: false, openWorld: true),
        run: { context, input in
            let name = input["name"] as? String ?? "gh-touchid-reader-\(randomHex(bytes: 3))"
            let reader = try createReader(
                name: name,
                openBrowser: input["open_browser"] as? Bool ?? true,
                progress: context.progress
            )
            return [
                "app": reader.slug,
                "app_id": reader.appId,
                "owner": reader.owner,
                "installed": true,
                "install_url": reader.installURL,
            ]
        },
        text: { output in
            "The reader \(output["app"] ?? "") of \(output["owner"] ?? "") is installed and checked: gh reads public "
                + "data with it where you have no App, without Touch ID."
        }
    ),
    Operation(
        name: "reader_add",
        words: ["reader", "add"],
        title: "Add the reader's key",
        description: "`reader add` stores a reader App made by hand, or a new key for the stored one: the App's "
            + "private key (the PKCS#1 .pem GitHub downloads) on stdin. GitHub must confirm the App ID, that the App "
            + "belongs to a user and has no permissions, and one installation on that user with no repository; then "
            + "one Touch ID stores it, replacing any reader. Prints the key's fingerprint, and the replaced key's "
            + "with where to delete it on GitHub.",
        example: "gh-touchid reader add --app-id 123456 < gh-touchid-reader.private-key.pem",
        positional: [],
        input: .object(
            properties: [
                ("app_id", .integer(minimum: 1, description: "The App ID, from the App's settings on GitHub.")),
                ("private_key", .string(
                    secret: true,
                    description: "The App's private key, PKCS#1 PEM (BEGIN RSA PRIVATE KEY); on the command line, "
                        + "piped to stdin."
                )),
            ],
            required: ["app_id"]
        ),
        output: .object(
            properties: [
                ("app", .string(description: "The reader App's slug.")),
                ("app_id", .integer(minimum: 1, description: "The reader App's ID.")),
                ("owner", .string(description: "The user account the reader belongs to and is installed on.")),
                ("fingerprint", .string(description: "The stored key's fingerprint, as GitHub shows it.")),
                ("replaced", .object(
                    properties: [
                        ("fingerprint", .string(description: "The replaced key's fingerprint.")),
                        ("delete_keys_url", .string(description: "Where the replaced key is deleted on GitHub.")),
                    ],
                    required: ["fingerprint", "delete_keys_url"],
                    description: "The key this one replaced, when a reader was stored."
                )),
            ],
            required: ["app", "app_id", "owner", "fingerprint"]
        ),
        annotations: Annotations(readOnly: false, destructive: true, idempotent: false, openWorld: true),
        run: { _, input in
            let appId = input["app_id"] as? Int ?? 0
            let pem = try input["private_key"] as? String ?? readPrivateKey(appId: appId)
            return try addReader(appId: appId, pem: pem)
        },
        text: { output in
            var lines = [
                "Stored the reader \(output["app"] ?? "") (ID \(output["app_id"] ?? "")) of \(output["owner"] ?? ""), "
                    + "key \(output["fingerprint"] ?? "").",
            ]
            if let replaced = output["replaced"] as? [String: Any] {
                lines.append(
                    "It replaced the key \(replaced["fingerprint"] ?? ""); once no use of the old key runs, delete it "
                        + "at \(replaced["delete_keys_url"] ?? "")"
                )
            }
            return lines.joined(separator: "\n")
        }
    ),
    Operation(
        name: "reader_remove",
        words: ["reader", "remove"],
        title: "Remove the reader",
        description: "`reader remove` deletes the stored reader, after a yes on the terminal or with --yes; gh then "
            + "refuses owners without an App. The App stays on GitHub until deleted at the printed address.",
        example: "gh-touchid reader remove --yes",
        positional: [],
        input: .object(
            properties: [("yes", .boolean(description: "Remove without asking."))],
            required: []
        ),
        output: .object(
            properties: [
                ("removed", .boolean(description: "Whether a reader was stored and is now deleted.")),
                ("delete_url", .string(description: "Where the reader App is deleted on GitHub.")),
            ],
            required: ["removed"]
        ),
        annotations: Annotations(readOnly: false, destructive: true, idempotent: true, openWorld: false),
        run: { context, input in
            try removeStoredReader(confirmed: input["yes"] as? Bool ?? false, noInput: context.noInput)
        },
        text: { output in
            guard output["removed"] as? Bool == true else {
                return "No reader was stored."
            }
            return "Removed the reader. Delete the App on GitHub: \(output["delete_url"] ?? "")"
        }
    ),
]

/// The private key piped to `reader add`: refused from a terminal (where it would be typed or pasted in the clear),
/// at most `privateKeyLimit` bytes.
private func readPrivateKey(appId: Int) throws -> String {
    let command = "gh-touchid reader add --app-id \(appId) < key.pem"
    guard !inputReadFromStandardInput else {
        throw ToolError.input("--input - took stdin; give private_key in the input document, or run: \(command)")
    }
    guard isatty(STDIN_FILENO) == 0 else {
        throw ToolError.input("pipe the key: \(command)")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count <= privateKeyLimit {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 {
            guard errno == EINTR else {
                throw ToolError.refused("cannot read the key from stdin: \(String(cString: strerror(errno)))")
            }
            continue
        }
        if count == 0 {
            break
        }
        data.append(contentsOf: buffer[..<count])
    }
    guard data.count <= privateKeyLimit else {
        throw ToolError.invalidPrivateKey("it is larger than \(privateKeyLimit / 1024) KiB")
    }
    guard let pem = String(data: data, encoding: .utf8), !pem.isEmpty else {
        throw ToolError.invalidPrivateKey("stdin held no key")
    }
    return pem
}

/// `reader add`: checks the App and key with GitHub, then Touch ID, then stores them, replacing any reader.
private func addReader(appId: Int, pem: String) throws -> [String: Any] {
    let key = try AppPrivateKey(pem: pem)
    let fingerprint = try key.fingerprint()
    let jwt = try key.jwt(appId: appId)
    let response = try githubAPI("GET", "/app", bearer: nil, jwt: jwt)
    if response.status == 401 {
        throw ToolError.readerKeyRejected(appId)
    }
    guard response.status == 200, let app = response.object else {
        throw ToolError.github("cannot read the App \(appId) with this key (HTTP \(response.status): \(response.message))")
    }
    guard app["id"] as? Int == appId,
          let slug = (app["slug"] as? String).flatMap(validOwner),
          let owner = app["owner"] as? [String: Any],
          let login = (owner["login"] as? String).flatMap(validOwner) else {
        throw ToolError.refused("this key belongs to another App than \(appId); check the App ID in the App's settings")
    }
    guard owner["type"] as? String == "User" else {
        throw ToolError.refused(
            "the App \(slug) belongs to \(login), which is not a user account; a reader is an App of your user account"
        )
    }
    guard let permissions = app["permissions"] as? [String: Any], permissions.isEmpty else {
        let named = (app["permissions"] as? [String: Any]).map { $0.keys.sorted().joined(separator: ", ") }
        throw ToolError.readerPermissions(printable(named ?? "GitHub did not say which"))
    }
    let label = ReaderLabel(slug: slug, owner: login)
    try testReader(key: key, appId: appId, label: label)

    // what is replaced, read before the dialog that names it
    let replacing = hasReader()
    let previousSlug: String? = replacing ? readerLabel()?.slug ?? "reader" : nil
    let previousFingerprint: String? = replacing
        ? (try? loadReader()).flatMap { try? AppPrivateKey(pem: $0.privateKey).fingerprint() }
        : nil
    let deleteKeysURL = try readerSettingsURL(slug: previousSlug ?? slug)
    try authenticate(.reader(slug, owner: login, replacing: previousSlug))
    try storeReader(ReaderSecret(appId: appId, privateKey: pem), label: label)
    appendAccessLog("stored the reader \(slug) (ID \(appId)) of \(login), key \(fingerprint)")

    var output: [String: Any] = ["app": slug, "app_id": appId, "owner": login, "fingerprint": fingerprint]
    if replacing {
        output["replaced"] = [
            "fingerprint": previousFingerprint ?? "unknown",
            "delete_keys_url": deleteKeysURL,
        ]
    }
    return output
}

/// `reader remove`: deletes the reader once confirmed by `--yes` or on the terminal.
private func removeStoredReader(confirmed: Bool, noInput: Bool) throws -> [String: Any] {
    guard hasReader() else {
        return ["removed": false]
    }
    let slug = readerLabel()?.slug
    if !confirmed {
        let canAsk = !noInput && isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0
        guard canAsk else {
            throw ToolError.confirmationNeeded("gh-touchid reader remove --yes")
        }
        let answer = askInTerminal("Remove the reader \(slug ?? "")? gh will refuse owners without an App. [y/N] ")
        guard let answer, ["y", "yes"].contains(answer.lowercased()) else {
            throw ToolError.refused("the reader was not removed")
        }
    }
    try removeReader()
    appendAccessLog("removed the reader \(slug ?? "with an unreadable comment")")
    var output: [String: Any] = ["removed": true]
    if let slug {
        output["delete_url"] = try readerDeleteURL(slug: slug)
    }
    return output
}
