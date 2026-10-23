import Darwin
import Foundation

// `git setup <owner>`: Git's HTTPS credential requests for an owner's repositories go to this gh-touchid alone,
// through three entries in the global Git configuration:
//
//   [credential "https://github.com/OWNER"]
//       helper =
//       helper = !/opt/homebrew/bin/gh-touchid git credential
//       useHttpPath = true
//
// Git asks every helper of every matching section, in the order it reads them, and an empty helper drops those before
// it; so the section goes last in the file, after any broader one such as `credential.https://github.com.helper`.

/// `git setup <owner>`. The owner is kept as typed: Git compares the path of a URL case-sensitively, so it must be
/// written as in the remotes' URLs.
func gitSetup(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 1, validOwner(arguments[0]) != nil else {
        throw ToolError.usage
    }
    try setUpGit(owner: arguments[0])
    return 0
}

/// Writes the owner's entries, replacing those of an earlier run (whatever helper they named), and prints them.
func setUpGit(owner: String) throws {
    guard let target = gitCredentialExecutable() else {
        throw ToolError.input("cannot find gh-touchid's own executable")
    }
    let section = "credential.https://github.com/\(owner)"
    let helper = "!\(shellQuoted(target.path)) git credential"

    // Other settings of the section stay; the helpers and useHttpPath are gh-touchid's. Removing the section and
    // adding it again moves it to the end of the file.
    let kept = globalSettings(of: section).filter { !["helper", "usehttppath"].contains($0.name) }
    _ = runGit(["config", "--global", "--remove-section", section])
    for setting in kept {
        try writeGlobalSetting(["--add", "\(section).\(setting.name)", setting.value])
    }
    try writeGlobalSetting(["--add", "\(section).helper", ""])
    try writeGlobalSetting(["--add", "\(section).helper", helper])
    try writeGlobalSetting(["\(section).useHttpPath", "true"])

    let file = gitOutput(["config", "--global", "--show-origin", "--get", "\(section).usehttppath"])
        .flatMap { $0.hasPrefix("file:") ? $0.dropFirst("file:".count).split(separator: "\t").first : nil }
        .map { displayFolder(String($0)) } ?? "your global Git configuration"
    print("Wrote to \(file), so that Git asks only this gh-touchid for credentials of \(owner)'s repositories:")
    print("[credential \"https://github.com/\(owner)\"]")
    print("\thelper =")
    print("\thelper = \(helper)")
    print("\tuseHttpPath = true")
    if !kept.isEmpty {
        print("(and kept the section's \(kept.count) other setting\(kept.count == 1 ? "" : "s"))")
    }
    print("The empty helper turns off helpers set for broader URLs, such as osxkeychain; useHttpPath tells gh-touchid")
    print("which repository Git is talking to. Use HTTPS remotes: https://github.com/\(owner)/REPO.git")
    if target.changesOnUpdate {
        print(
            "\(target.path) changes when gh-touchid is updated: run `gh-touchid git setup \(owner)` again after "
                + "each update, or put a gh-touchid link that stays (such as Homebrew's bin or your Nix profile's) "
                + "on PATH and run it from there."
        )
    }
    let helpers = credentialHelpers(for: probeURL(owner: owner)) ?? [helper]
    if helpers != [helper] {
        let names = helpers.filter { $0 != helper }.map(helperName)
        print(
            "Here Git asks \(names.isEmpty ? "no helper" : names.joined(separator: ", ")) for \(owner)'s "
                + "repositories\(helpers.contains(helper) ? " besides this gh-touchid" : ""): a setting after these "
                + "entries, for example in this repository's own configuration, changes them."
        )
    }
}

/// The end of `app create` and `app set`: in a terminal, asks whether to set up Git for the owner now and does;
/// without one, prints the command.
func offerGitSetup(owner: String) throws {
    let command = "gh-touchid git setup \(owner)"
    guard isatty(STDERR_FILENO) != 0, let answer = askInTerminal("Set up Git for \(owner) now? [Y/n] ") else {
        fputs("To have Git use gh-touchid for \(owner)'s repositories, run: \(command)\n", stderr)
        return
    }
    guard ["", "y", "yes"].contains(answer.lowercased()) else {
        fputs("Git was left as it is; to set it up later, run: \(command)\n", stderr)
        return
    }
    try setUpGit(owner: owner)
}

/// Asks on the terminal itself (`app set` reads the key from stdin) and returns the answer without surrounding
/// spaces; nil without a terminal or when its input ends.
private func askInTerminal(_ question: String) -> String? {
    let terminal = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
    guard terminal >= 0 else {
        return nil
    }
    defer { close(terminal) }
    _ = question.withCString { write(terminal, $0, strlen($0)) }
    var line: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        let count = read(terminal, &byte, 1)
        if count < 0 && errno == EINTR {
            continue
        }
        guard count == 1 else {
            return nil
        }
        if byte == UInt8(ascii: "\n") {
            return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        line.append(byte)
    }
}

/// What `status` says about Git and gh: for each owner the credential helpers Git asks for its repositories, each with
/// the fix unless it is this gh-touchid alone; then which `gh` is first on PATH and whether another gh is signed in.
func gitStatus(owners: [String]) -> [String] {
    let ownName = ownRealExecutablePath.map { ($0 as NSString).lastPathComponent }
    var lines: [String] = []
    for stored in owners {
        let owner = configuredOwner(stored)
        guard let helpers = credentialHelpers(for: probeURL(owner: owner)) else {
            lines.append("Git for \(owner): cannot ask git")
            continue
        }
        if helpers.count == 1, runsThisGitCredential(helpers[0]) {
            lines.append("Git for \(owner) asks: this gh-touchid only")
            continue
        }
        let asked = helpers.map { helper -> String in
            if runsThisGitCredential(helper) {
                return "this gh-touchid"
            }
            let name = helperName(helper)
            return name == "gh-touchid" || name == ownName ? "another \(name)" : name
        }
        lines.append(
            "Git for \(owner) asks: \(asked.isEmpty ? "no credential helper" : asked.joined(separator: ", ")); "
                + "fix: gh-touchid git setup \(owner)"
        )
    }
    return lines + gitHubCLIStatus()
}

/// The owner as a `credential.https://github.com/<owner>.helper` setting writes it, such as `Acme` for the stored
/// `acme`, since Git compares it case-sensitively; the stored owner when no setting names it.
private func configuredOwner(_ owner: String) -> String {
    let pattern = #"^credential\.https://github\.com/[^/]+\.helper$"#
    for key in gitOutput(["config", "--name-only", "--get-regexp", pattern])?.split(separator: "\n") ?? [] {
        let written = key.dropFirst("credential.https://github.com/".count).dropLast(".helper".count)
        if written.lowercased() == owner {
            return String(written)
        }
    }
    return owner
}

/// Which `gh` is first on PATH: this gh-touchid's wrapper, another gh, or none, with the fix for this installation unless
/// it is the wrapper; then, when a gh other than the wrapper is on PATH, whether gh is signed in to github.com.
private func gitHubCLIStatus() -> [String] {
    let found = commandsOnPath("gh")
    let first = found.first
    var lines: [String] = []
    let wrapper = ownRealExecutablePath.flatMap { own in
        realPath((gitHubCLIWrapperFolder(own: own, stable: false) as NSString).appendingPathComponent("gh"))
    }
    if let own = ownRealExecutablePath, let wrapper {
        if let first, realPath(first) == wrapper {
            lines.append("gh on PATH: \(first), this gh-touchid's wrapper")
        } else {
            let folder = gitHubCLIWrapperFolder(own: own, stable: true)
            let onPath = commandsOnPath((own as NSString).lastPathComponent).first.flatMap(realPath) == own
            let command = onPath ? (own as NSString).lastPathComponent : gitCredentialExecutable()?.path ?? own
            let fix = "fix: add `export PATH=\"\(folder):$PATH\"` to your shell's profile, "
                + "or `alias gh='\(command) gh'` for your own shell only"
            lines.append(first.map { "gh on PATH: \($0), another gh; \(fix)" } ?? "gh on PATH: none; \(fix)")
        }
    } else {
        lines.append("gh on PATH: \(first ?? "none"); this gh-touchid has no gh of its own, run gh as `gh-touchid gh …`")
    }
    if found.contains(where: { realPath($0) != wrapper }), let login = gitHubCLISignIn() {
        lines.append(
            "another gh is signed in \(login.isEmpty ? "to github.com" : "as \(login)"): any program can use that "
                + "login; `gh auth logout` to close it"
        )
    }
    return lines
}

/// The folder of this installation's gh wrapper, `libexec/bin` beside the real folder of the executable `own`. With
/// `stable`, an executable in Homebrew's Cellar (`<prefix>/Cellar/<name>/<version>/bin/…`) gets the formula's `opt`
/// link instead, `<prefix>/opt/<name>/libexec/bin`, which stays the same across updates, when it exists.
private func gitHubCLIWrapperFolder(own: String, stable: Bool) -> String {
    let components = (own as NSString).pathComponents
    let root = NSString.path(withComponents: Array(components.dropLast(2)))
    let installed = (root as NSString).appendingPathComponent("libexec/bin")
    guard stable, components.count >= 6, components[components.count - 5] == "Cellar" else {
        return installed
    }
    let prefix = NSString.path(withComponents: Array(components.dropLast(5)))
    let opt = (prefix as NSString).appendingPathComponent("opt/\(components[components.count - 4])/libexec/bin")
    return realPath((opt as NSString).appendingPathComponent("gh")) != nil ? opt : installed
}

/// The login a gh is signed in to github.com as, "" when it cannot be told, or nil when no gh is. No gh is run and no
/// secret is read: only whether gh's hosts.yml has an `oauth_token` for github.com, and whether the Keychain has an
/// item of gh's service `gh:github.com` (its attributes only).
private func gitHubCLISignIn() -> String? {
    let environment = ProcessInfo.processInfo.environment
    let folder: String
    if let configured = environment["GH_CONFIG_DIR"], !configured.isEmpty {
        folder = configured
    } else if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        folder = (xdg as NSString).appendingPathComponent("gh")
    } else {
        folder = (NSHomeDirectory() as NSString).appendingPathComponent(".config/gh")
    }
    let hosts = (try? String(contentsOfFile: (folder as NSString).appendingPathComponent("hosts.yml"), encoding: .utf8))
        .map(gitHubCLIHostsEntry) ?? (user: nil, hasToken: false)
    let keychain = gitHubCLIKeychainAccounts()
    guard hosts.hasToken || !keychain.isEmpty else {
        return nil
    }
    let login = hosts.user ?? keychain.first(where: { !$0.isEmpty })
    return login.flatMap { validOwner($0) == nil ? nil : $0 } ?? ""
}

/// What gh's hosts.yml says of github.com: its active login (`user:`, else the first one under `users:`) and whether
/// an `oauth_token` is written in the file. The token is never kept.
private func gitHubCLIHostsEntry(_ text: String) -> (user: String?, hasToken: Bool) {
    let quotes = CharacterSet(charactersIn: "\"' ")
    var inHost = false
    var hostIndent: Int?
    var usersIndent: Int?
    var listedIndent: Int?
    var user: String?
    var listed: String?
    var hasToken = false
    for raw in text.split(whereSeparator: \.isNewline) {
        let content = raw.drop(while: { $0 == " " })
        guard !content.isEmpty, !content.hasPrefix("#"), let colon = content.firstIndex(of: ":") else {
            continue
        }
        let indent = raw.count - content.count
        let key = content[..<colon].trimmingCharacters(in: quotes)
        let value = content[content.index(after: colon)...].trimmingCharacters(in: quotes)
        if indent == 0 {
            inHost = key == "github.com"
            (hostIndent, usersIndent, listedIndent) = (nil, nil, nil)
            continue
        }
        guard inHost else {
            continue
        }
        if key == "oauth_token", !value.isEmpty {
            hasToken = true
        }
        let host = hostIndent ?? indent
        hostIndent = host
        if indent <= host {
            usersIndent = key == "users" ? indent : nil
            listedIndent = nil
            if key == "user", !value.isEmpty {
                user = value
            }
        } else if let usersIndent, indent > usersIndent {
            if listedIndent == nil {
                listedIndent = indent
            }
            if indent == listedIndent, listed == nil {
                listed = key
            }
        }
    }
    return (user ?? listed, hasToken)
}

/// A URL of one of the owner's repositories, to ask Git which helpers it would run.
func probeURL(owner: String) -> String {
    "https://github.com/\(owner)/x"
}

/// The settings of a section in the global configuration, in order, names lowercase.
private func globalSettings(of section: String) -> [(name: String, value: String)] {
    let pattern = "^" + section.replacingOccurrences(of: ".", with: "\\.") + "\\."
    guard let result = runGit(["config", "--global", "--null", "--get-regexp", pattern]), result.status == 0 else {
        return []
    }
    return result.output.split(separator: 0).compactMap { record in
        let text = String(decoding: record, as: UTF8.self)
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count > section.count + 1 else {
            return nil // a setting without a value cannot be written back with `git config`
        }
        return (String(parts[0].dropFirst(section.count + 1)), String(parts[1]))
    }
}

private func writeGlobalSetting(_ arguments: [String]) throws {
    guard let result = runGit(["config", "--global"] + arguments, showErrors: true) else {
        throw ToolError.input("cannot run git")
    }
    guard result.status == 0 else {
        throw ToolError.input("git config --global \(arguments.joined(separator: " ")) failed")
    }
}

/// The path Git should run this gh-touchid by: the first one on PATH that resolves to this executable, preferring one
/// outside the Nix store and Homebrew's Cellar, whose paths change with every update; else this executable itself.
func gitCredentialExecutable() -> (path: String, changesOnUpdate: Bool)? {
    guard let own = ownRealExecutablePath else {
        return nil
    }
    let candidates = commandsOnPath((own as NSString).lastPathComponent).filter { realPath($0) == own }
    if let stable = candidates.first(where: { !isVersionedPath($0) }) {
        return (stable, false)
    }
    let path = candidates.first ?? own
    return (path, isVersionedPath(path))
}

private func isVersionedPath(_ path: String) -> Bool {
    path.hasPrefix("/nix/store/") || path.contains("/Cellar/")
}

/// Every executable named `name` in the folders of PATH, in order.
func commandsOnPath(_ name: String) -> [String] {
    var seen = Set<String>()
    let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    return folders.compactMap { folder in
        guard folder.hasPrefix("/") else {
            return nil
        }
        let candidate = (String(folder) as NSString).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: candidate), seen.insert(candidate).inserted else {
            return nil
        }
        return candidate
    }
}

/// `text` as one word for the shell that runs a `!` helper.
private func shellQuoted(_ text: String) -> String {
    let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-@%:,=")
    if !text.isEmpty, text.unicodeScalars.allSatisfy({ plain.contains($0) }) {
        return text
    }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The credential helpers Git asks for `url`, in order: every `credential.helper` and `credential.<url>.helper` that
/// applies to it, collected in the order Git reads its configuration, an empty one dropping those before it. Which
/// sections apply is left to Git (`--get-urlmatch`). Nil when Git cannot be asked.
func credentialHelpers(for url: String) -> [String]? {
    guard let listing = runGit(["config", "--null", "--get-regexp", #"^credential\.(.*\.)?helper$"#]) else {
        return nil
    }
    guard listing.status == 0 else {
        return listing.status == 1 ? [] : nil // 1: no helper set anywhere
    }
    var entries: [(section: String?, value: String)] = []
    for record in listing.output.split(separator: 0) {
        let parts = String(decoding: record, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue // a helper without a value, which Git rejects
        }
        let key = parts[0]
        let section = key == "credential.helper"
            ? nil
            : String(key.dropFirst("credential.".count).dropLast(".helper".count))
        entries.append((section, String(parts[1])))
    }

    var sections: [String] = []
    for case let section? in entries.map(\.section) where !sections.contains(section) {
        sections.append(section)
    }
    var matching = Set<String>()
    if !sections.isEmpty {
        // One made-up setting per section; Git prints those of the sections that match the URL.
        var arguments: [String] = []
        for (index, section) in sections.enumerated() where !section.contains("=") {
            arguments += ["-c", "credential.\(section).ghtouchidprobe\(index)=1"]
        }
        guard let probe = runGit(arguments + ["config", "--get-urlmatch", "credential", url]) else {
            return nil
        }
        for line in String(decoding: probe.output, as: UTF8.self).split(separator: "\n") {
            let prefix = "credential.ghtouchidprobe"
            guard line.hasPrefix(prefix),
                  let index = Int(line.dropFirst(prefix.count).prefix(while: { $0 != " " })),
                  sections.indices.contains(index) else {
                continue
            }
            matching.insert(sections[index])
        }
    }

    var helpers: [String] = []
    for entry in entries where entry.section.map(matching.contains) ?? true {
        if entry.value.isEmpty {
            helpers.removeAll()
        } else {
            helpers.append(entry.value)
        }
    }
    return helpers
}

/// Whether `helper` is `!<path> git credential` with a path, or a name found on PATH, that resolves to this
/// executable. The `!<path> git-credential` of gh-touchid 0.3 is not: that command is gone.
func runsThisGitCredential(_ helper: String) -> Bool {
    guard helper.hasPrefix("!"), let own = ownRealExecutablePath, let words = shellWords(helper.dropFirst()),
          words.count == 3, words[1] == "git", words[2] == "credential" else {
        return false
    }
    let path = words[0].contains("/") ? words[0] : commandsOnPath(words[0]).first
    return path.flatMap(realPath) == own
}

/// A helper as gh-touchid names it: its program, without arguments, which might hold a secret.
func helperName(_ helper: String) -> String {
    let command = helper.hasPrefix("!") ? helper.dropFirst() : Substring(helper)
    let word = shellWords(command)?.first
        ?? String(command.drop(while: { $0 == " " }).prefix(while: { $0 != " " }))
    return printable((word as NSString).lastPathComponent, limit: 60)
}

/// The words the shell makes of `text`, its quoting undone as for `shellQuoted`'s: single quotes, double quotes (in
/// which a backslash escapes `"`, `\`, `$` and a backquote) and backslashes outside quotes. Nil for an unterminated
/// quote; anything else the shell would expand stays as it is.
private func shellWords(_ text: Substring) -> [String]? {
    var words: [String] = []
    var word = ""
    var inWord = false
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        index = text.index(after: index)
        switch character {
        case " ", "\t", "\n":
            if inWord {
                words.append(word)
                word = ""
                inWord = false
            }
        case "'":
            inWord = true
            guard let end = text[index...].firstIndex(of: "'") else {
                return nil
            }
            word += text[index..<end]
            index = text.index(after: end)
        case "\"":
            inWord = true
            var closed = false
            while index < text.endIndex {
                let inner = text[index]
                index = text.index(after: index)
                if inner == "\"" {
                    closed = true
                    break
                }
                if inner == "\\", index < text.endIndex, "\"\\$`".contains(text[index]) {
                    word.append(text[index])
                    index = text.index(after: index)
                } else {
                    word.append(inner)
                }
            }
            guard closed else {
                return nil
            }
        case "\\":
            inWord = true
            if index < text.endIndex {
                word.append(text[index])
                index = text.index(after: index)
            }
        default:
            inWord = true
            word.append(character)
        }
    }
    if inWord {
        words.append(word)
    }
    return words
}
