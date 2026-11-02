import Foundation

// gh-touchid tells what a gh command line does the way gh tells it: from gh's own list of commands, aliases and flags
// (`gh help reference`), read by the rules of Cobra and pflag, gh's command and flag parsers. Every decision about a
// command line comes from this one reading: which commands may run, what the approval dialog names, whether the reader
// may be used, and which repository the token is for. A second reading, however careful, is a second parser that a
// command line can be written to make disagree with gh (`gh --hostname github.com auth token` ran `auth token` past a
// check that read only the first word), so nothing else reads gh's command line.

/// gh's commands as `gh help reference` lists them.
struct GitHubReference {
    /// Each command's flags, by path (`issue create`; the empty path is gh itself).
    var commands: [String: CommandFlags] = [:]
    /// The path each name and alias leads to, by the path it is written as: `issue new` → `issue create`, `cs` →
    /// `codespace`, `codespace ls` → `codespace list`, `co` → `pr checkout`; each command's own path leads to itself.
    var names: [String: String] = [:]
    /// The commands that have subcommands.
    var parents: Set<String> = []
}

/// A gh command line as gh reads it: the command it runs and what that command parses.
struct GitHubCommandLine {
    /// The command, aliases resolved: `pr checkout` for `co 12`; empty for gh itself (`--help`, `--version`).
    let path: [String]
    /// The arguments without the words that named the command, flags before them included: Cobra passes them all on
    /// to the command it found.
    let rest: [String]
    /// The command's flags.
    let flags: CommandFlags

    /// `gh pr checkout`.
    var name: String {
        (["gh"] + path).joined(separator: " ")
    }
}

/// The command `gh <arguments>` runs, refused when it is not one of gh's own (see `readGitHubCommand`) or when it could
/// reveal the token, store it elsewhere or run code gh-touchid does not know: `--show-token` anywhere, `alias`,
/// `extension`, and `auth` other than `auth status` without `-t`.
func allowedGitHubCommand(_ arguments: [String]) throws -> GitHubCommandLine {
    let command = try readGitHubCommand(arguments)
    if arguments.contains(where: { $0 == "--show-token" || $0.hasPrefix("--show-token=") }) {
        throw ToolError.forbiddenCommand
    }
    switch command.path.first {
    case "alias", "extension":
        throw ToolError.forbiddenCommand
    case "auth":
        // `-t` is `auth status --show-token`, also inside a group of short flags such as `-at`
        let showsToken = command.rest.contains { argument in
            argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains("t")
        }
        guard command.path == ["auth", "status"], !showsToken else {
            throw ToolError.forbiddenCommand
        }
    default:
        break
    }
    return command
}

/// The command `arguments` run, found as Cobra finds it: at each level, the first word that is neither a flag nor the
/// value of one (judged by the flags of the command reached so far) names a subcommand or an alias of one; it is taken
/// out and the search goes on a level down. Flags before it, as in `pr -R o/r merge`, stay for the levels below.
/// Refused where gh would look for a command and the word names none of gh's: an extension, an alias of the user's, a
/// hidden command, or a word written to read one way here and another way in gh.
func readGitHubCommand(_ arguments: [String]) throws -> GitHubCommandLine {
    let reference = try loadedGitHubReference.get()
    var path = ""
    var remaining = Array(arguments.indices)
    var words: [String] = []
    while let position = commandWordIndex(
        remaining.map { arguments[$0] },
        flags: reference.commands[path] ?? CommandFlags()
    ) {
        let word = arguments[remaining[position]]
        guard let next = reference.names[path.isEmpty ? word : "\(path) \(word)"] else {
            guard path.isEmpty || reference.parents.contains(path) else {
                break // the first of the command's own arguments
            }
            throw ToolError.unknownGitHubCommand(printable((["gh"] + words + [word]).joined(separator: " ")))
        }
        path = next
        words.append(word)
        remaining.remove(at: position)
    }
    var flags = reference.commands[path] ?? CommandFlags()
    // inherited from the command's parents, so not listed with it
    flags.long["repo"] = true
    flags.short["R"] = true
    return GitHubCommandLine(
        path: path.isEmpty ? [] : path.split(separator: " ").map(String.init),
        rest: remaining.map { arguments[$0] },
        flags: flags
    )
}

/// Where the first word that is not a flag or a flag's value is, before `--`, as Cobra's `stripFlags` reads it: `--x`
/// and `-x` without an inline value take the next argument unless `flags` knows them as switches; groups such as
/// `-wR` take none.
private func commandWordIndex(_ arguments: [String], flags: CommandFlags) -> Int? {
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            return nil
        }
        if argument.hasPrefix("--"), !argument.contains("="), flags.long[String(argument.dropFirst(2))] != false {
            index += 2
        } else if argument.count == 2, argument.hasPrefix("-"), !argument.contains("="),
                  let shorthand = argument.last, flags.short[shorthand] != false {
            index += 2
        } else if !argument.isEmpty, !argument.hasPrefix("-") {
            return index
        } else {
            index += 1
        }
    }
    return nil
}

/// gh's commands, read once: from the list built into a build that pins gh (its gh is fixed, so the list is too), else
/// from `gh help reference` of the gh that will run, chosen when it runs in a development or test build. A list that
/// lacks gh's own `api` and `auth` is not gh's, and is refused: every command would be misread.
private let loadedGitHubReference: Result<GitHubReference, ToolError> = {
    let source: String
    let text: String?
    if !pinnedGitHubReference.hasPrefix("@") {
        source = "the list built into gh-touchid"
        text = Data(base64Encoded: pinnedGitHubReference).flatMap { String(data: $0, encoding: .utf8) }
    } else if !pinnedGitHubCLI.hasPrefix("@") {
        source = "the list a build that pins gh must have built in"
        text = nil
    } else {
        let cli: GitHubCLI
        do {
            cli = try gitHubCLI()
        } catch let error as ToolError {
            return .failure(error)
        } catch {
            return .failure(.gitHubCommandsUnreadable("gh"))
        }
        source = "`\(cli.prefix.isEmpty ? cli.executable.path : "gh") help reference`"
        text = gitHubReferenceText(cli)
    }
    guard let text else {
        return .failure(.gitHubCommandsUnreadable(source))
    }
    let reference = parseGitHubReference(text)
    guard reference.names["api"] == "api", reference.names["auth"] == "auth" else {
        return .failure(.gitHubCommandsUnreadable(source))
    }
    return .success(reference)
}()

/// The output of `gh help reference` from `cli`, run without a token and with fresh empty configuration and data
/// folders: gh lists the user's installed extensions among its commands, and they are not gh's. Nil when it fails.
private func gitHubReferenceText(_ cli: GitHubCLI) -> String? {
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-touchid-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(
        at: configDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )) != nil else {
        return nil
    }
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    var environment = ProcessInfo.processInfo.environment
    for name in ["HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
        environment[name] = configDirectory.path
    }
    environment["GH_PAGER"] = "cat"
    for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
        environment.removeValue(forKey: name)
    }
    guard let result = runCapturingOutput(cli.executable, cli.prefix + ["help", "reference"], environment: environment),
          result.exitedNormally, result.status == 0 else {
        return nil
    }
    return String(data: result.output, encoding: .utf8)
}

/// Sections `### gh <path> [args]` (one `#` per level below `gh`), each followed by its flags
/// (`  -b, --body string   desc`, `      --web   desc`: a type word after the long name means it takes a value,
/// unless it has an optional value as in `string[="last"]`) and an "Aliases" paragraph (`gh issue new, gh …`).
/// A section of a top-level alias holds just `Alias for "pr checkout"`.
private func parseGitHubReference(_ text: String) -> GitHubReference {
    var reference = GitHubReference()
    var path: String?
    var flags = CommandFlags()
    var inAliases = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("#") {
            if let path, reference.names[path] == path {
                reference.commands[path] = flags
            }
            path = commandPath(line)
            flags = CommandFlags()
            inAliases = false
            if let path {
                reference.names[path] = path
                let parent = path.split(separator: " ").dropLast().joined(separator: " ")
                if !parent.isEmpty {
                    reference.parents.insert(parent)
                }
            }
            continue
        }
        guard let current = path else {
            continue
        }
        if line == "Aliases" {
            inAliases = true
        } else if inAliases, line.hasPrefix("gh ") {
            let parent = current.split(separator: " ").dropLast().joined(separator: " ")
            for alias in line.components(separatedBy: ", ") where alias.hasPrefix("gh ") {
                if let name = alias.split(separator: " ").last {
                    reference.names[parent.isEmpty ? String(name) : "\(parent) \(name)"] = current
                }
            }
        } else if line.hasPrefix("Alias for \""), line.hasSuffix("\""), !current.contains(" ") {
            let target = line.dropFirst("Alias for \"".count).dropLast()
            if !target.isEmpty {
                reference.names[current] = String(target)
            }
        } else if line.hasPrefix(" "), let flag = flagDefinition(line) {
            flags.long[flag.long] = flag.takesValue
            if let shorthand = flag.short {
                flags.short[shorthand] = flag.takesValue
            }
        }
    }
    if let path, reference.names[path] == path {
        reference.commands[path] = flags
    }
    // gh itself has no section; its own `--version` is a switch
    reference.commands[""] = CommandFlags(long: ["help": false, "version": false])
    return reference
}

/// `issue create` from `### gh issue create [flags]`, or nil when the heading is not a command's.
private func commandPath(_ heading: Substring) -> String? {
    let parts = heading.split(separator: " ")
    let depth = parts[0].count - 1
    guard depth >= 1, parts[0].allSatisfy({ $0 == "#" }), parts.count > depth + 1, parts[1] == "gh" else {
        return nil
    }
    return parts[2...(depth + 1)].joined(separator: " ")
}

/// `  -b, --body string   desc` → (`body`, `b`, true); nil when the line is not a flag's.
private func flagDefinition(_ line: Substring) -> (long: String, short: Character?, takesValue: Bool)? {
    var rest = line.drop(while: { $0 == " " })
    var short: Character?
    if rest.count > 4, rest.hasPrefix("-"), !rest.hasPrefix("--") {
        let shorthand = rest[rest.index(after: rest.startIndex)]
        guard rest.dropFirst(2).hasPrefix(", ") else {
            return nil
        }
        short = shorthand
        rest = rest.dropFirst(4)
    }
    guard rest.hasPrefix("--") else {
        return nil
    }
    rest = rest.dropFirst(2)
    let name = rest.prefix(while: { $0 != " " })
    guard !name.isEmpty else {
        return nil
    }
    rest = rest.dropFirst(name.count)
    // a single space, then the type word; descriptions are set off by two or more
    var takesValue = false
    if rest.hasPrefix(" "), let first = rest.dropFirst().first, first != " " {
        let type = rest.dropFirst().prefix(while: { $0 != " " })
        takesValue = !type.contains("[=")
    }
    return (String(name), short, takesValue)
}
