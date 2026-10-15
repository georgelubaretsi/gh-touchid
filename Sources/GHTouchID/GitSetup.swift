import Darwin
import Foundation

// `git-setup <owner>`: Git's HTTPS credential requests for an owner's repositories go to this gh-touchid alone,
// through three entries in the global Git configuration:
//
//   [credential "https://github.com/OWNER"]
//       helper =
//       helper = !/opt/homebrew/bin/gh-touchid git-credential
//       useHttpPath = true
//
// Git asks every helper of every matching section, in the order it reads them, and an empty helper drops those before
// it; so the section goes last in the file, after any broader one such as `credential.https://github.com.helper`.

/// `git-setup <owner>`. The owner is kept as typed: Git compares the path of a URL case-sensitively, so it must be
/// written as in the remotes' URLs.
func gitSetup(_ arguments: [String]) throws -> Int32 {
    guard arguments.count == 1, validOwner(arguments[0]) != nil else {
        throw ToolError.usage
    }
    try setUpGit(owner: arguments[0])
    return 0
}

/// Writes the owner's entries, replacing those of an earlier run, and prints them.
func setUpGit(owner: String) throws {
    guard let target = gitCredentialExecutable() else {
        throw ToolError.input("cannot find gh-touchid's own executable")
    }
    let section = "credential.https://github.com/\(owner)"
    let helper = "!\(shellQuoted(target.path)) git-credential"

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
            "\(target.path) changes when gh-touchid is updated: run `gh-touchid git-setup \(owner)` again after "
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
    let command = "gh-touchid git-setup \(owner)"
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

/// What `status` says about Git and gh: for each owner the credential helpers Git asks for its repositories, then
/// whether `gh` on PATH is this gh-touchid's, each with the fix unless it is this gh-touchid alone.
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
                + "fix: gh-touchid git-setup \(owner)"
        )
    }
    lines.append(gitHubCLIStatus())
    return lines
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

/// Whether the first `gh` on PATH is the one beside this gh-touchid's executable, which runs gh through it.
private func gitHubCLIStatus() -> String {
    let first = commandsOnPath("gh").first
    let shown = first ?? "none"
    guard let own = ownRealExecutablePath else {
        return "gh on PATH: \(shown)"
    }
    let ours = ((own as NSString).deletingLastPathComponent as NSString).appendingPathComponent("gh")
    guard let real = realPath(ours) else {
        return "gh on PATH: \(shown); this gh-touchid has no gh of its own, run gh as `gh-touchid gh …`"
    }
    if let first, realPath(first) == real {
        return "gh on PATH: \(first), gh-touchid's"
    }
    let link = commandsOnPath("gh").first(where: { realPath($0) == real }) ?? ours
    let folder = (link as NSString).deletingLastPathComponent
    guard let first else {
        return "gh on PATH: none; fix: put \(folder) on PATH for gh-touchid's gh"
    }
    return "gh on PATH: \(first), not gh-touchid's; fix: put \(folder) before "
        + "\((first as NSString).deletingLastPathComponent) in PATH, or remove that gh"
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

/// Whether `helper` is `!<path> git-credential` with a path, or a name found on PATH, that resolves to this executable.
func runsThisGitCredential(_ helper: String) -> Bool {
    guard helper.hasPrefix("!"), let own = ownRealExecutablePath else {
        return false
    }
    var rest = helper.dropFirst().drop(while: { $0 == " " })
    let command: Substring
    if rest.hasPrefix("'") {
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: "'") else {
            return false
        }
        command = rest[..<end]
        rest = rest[rest.index(after: end)...]
    } else {
        command = rest.prefix(while: { $0 != " " })
        rest = rest.dropFirst(command.count)
    }
    guard rest.trimmingCharacters(in: .whitespaces) == "git-credential" else {
        return false
    }
    let path = command.contains("/") ? String(command) : commandsOnPath(String(command)).first
    return path.flatMap(realPath) == own
}

/// A helper as gh-touchid names it: its program, without arguments, which might hold a secret.
func helperName(_ helper: String) -> String {
    let command = (helper.hasPrefix("!") ? helper.dropFirst() : Substring(helper)).drop(while: { $0 == " " })
    let word = command.hasPrefix("'")
        ? command.dropFirst().prefix(while: { $0 != "'" })
        : command.prefix(while: { $0 != " " })
    return printable((String(word) as NSString).lastPathComponent, limit: 60)
}
