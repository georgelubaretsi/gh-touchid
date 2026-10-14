import Foundation

/// The flags of one gh command, by long name and by shorthand: true when the flag takes a value. `-R`/`--repo` is
/// inherited and not listed per command, so it is always known (and always takes a value); `-h`/`--help` unless the
/// command uses the names itself.
struct CommandFlags {
    var long: [String: Bool] = ["repo": true, "help": false]
    var short: [Character: Bool] = ["R": true, "h": false]
}

/// Whether gh's flag definitions can change which repository `arguments` select: a candidate selector (`-R…`,
/// `--repo…`, or a group of short flags containing `R`) right after a flag token without an inline value, which may
/// take it as its value, or a group in which `R` follows other flags, one of which may take the rest as its value.
/// `--` ends the flags, unless it too follows such a flag token: then it may be that flag's value.
func repositorySelectorIsAmbiguous(_ arguments: [String]) -> Bool {
    var previousMayTakeNext = false
    var endMayBeValue = false
    for argument in arguments {
        if argument == "--" {
            guard previousMayTakeNext else {
                return false
            }
            endMayBeValue = true
            previousMayTakeNext = false
            continue
        }
        let isFlag = argument.count > 1 && argument.hasPrefix("-")
        let isShortGroup = isFlag && !argument.hasPrefix("--")
        let isCandidate = argument.hasPrefix("--repo") || (isShortGroup && argument.dropFirst().contains("R"))
        if isCandidate && (previousMayTakeNext || endMayBeValue || (isShortGroup && !argument.hasPrefix("-R"))) {
            return true
        }
        previousMayTakeNext = isFlag && !argument.contains("=")
    }
    return false
}

/// The value of the last `-R`/`--repo` before `--` (gh acts on the last one), read the way gh's flag parser (pflag)
/// reads `arguments`: `--x v`, `--x=v`, `-x v`, `-xv`, `-x=v`, and groups of short flags in which the first flag that
/// takes a value takes the rest of the group, or the next argument. An unknown short flag ends its group: gh would
/// refuse it.
func repositorySelector(_ arguments: [String], flags: CommandFlags) throws -> String? {
    var selected: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        guard argument.count > 1, argument.hasPrefix("-") else {
            continue
        }
        if argument == "--" {
            break
        }

        if argument.hasPrefix("--") {
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard flags.long[name] == true else {
                continue
            }
            let value: String
            if parts.count == 2 {
                value = String(parts[1])
            } else if index < arguments.count {
                value = arguments[index]
                index += 1
            } else if name == "repo" {
                throw ToolError.input("\(argument) needs a repository")
            } else {
                break
            }
            if name == "repo" {
                selected = value
            }
            continue
        }

        var group = argument.dropFirst()
        while let shorthand = group.first, let takesValue = flags.short[shorthand] {
            group = group.dropFirst()
            guard takesValue else {
                continue
            }
            let value: String
            if group.count > 1, group.hasPrefix("=") {
                value = String(group.dropFirst())
            } else if !group.isEmpty {
                value = String(group)
            } else if index < arguments.count {
                value = arguments[index]
                index += 1
            } else if shorthand == "R" {
                throw ToolError.input("-R needs a repository")
            } else {
                break
            }
            if shorthand == "R" {
                selected = value
            }
            break
        }
    }
    return selected
}

/// The flags of the command `arguments` run, from `gh help reference` of the gh that will run; nil when the reference
/// cannot be read or does not know the command (aliases included). The command path is the leading arguments that
/// name commands.
func gitHubCommandFlags(_ arguments: [String]) -> CommandFlags? {
    guard let text = gitHubReference() else {
        return nil
    }
    let reference = parseGitHubReference(text)
    var path = ""
    for word in arguments {
        guard let next = reference.names[path.isEmpty ? word : "\(path) \(word)"] else {
            break
        }
        path = next
    }
    guard var flags = reference.commands[path] else {
        return nil
    }
    flags.long["repo"] = true
    flags.short["R"] = true
    return flags
}

/// Commands by path (`issue create`), and the paths their names and aliases lead to: `issue new` → `issue create`,
/// `cs` → `codespace`, `codespace ls` → `codespace list`.
private struct GitHubReference {
    var commands: [String: CommandFlags] = [:]
    var names: [String: String] = [:]
}

/// Sections `### gh <path> [args]` (one `#` per level below `gh`), each followed by its flags
/// (`  -b, --body string   desc`, `      --web   desc`: a type word after the long name means it takes a value,
/// unless it has an optional value as in `string[="last"]`) and an "Aliases" paragraph (`gh issue new, gh …`).
private func parseGitHubReference(_ text: String) -> GitHubReference {
    var reference = GitHubReference()
    var path: String?
    var flags = CommandFlags()
    var inAliases = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("#") {
            if let path {
                reference.commands[path] = flags
            }
            path = commandPath(line)
            flags = CommandFlags()
            inAliases = false
            if let path {
                reference.names[path] = path
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
        } else if line.hasPrefix(" "), let flag = flagDefinition(line) {
            flags.long[flag.long] = flag.takesValue
            if let shorthand = flag.short {
                flags.short[shorthand] = flag.takesValue
            }
        }
    }
    if let path {
        reference.commands[path] = flags
    }
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

/// The output of `gh help reference`, run in a fresh empty configuration directory and without a token; nil when it
/// fails.
private func gitHubReference() -> String? {
    guard let cli = try? gitHubCLI() else {
        return nil
    }
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

    let process = Process()
    let output = Pipe()
    // waitUntilExit polls and adds ~70 ms; the handler runs as soon as gh exits
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    process.executableURL = cli.executable
    process.arguments = cli.prefix + ["help", "reference"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    var environment = ProcessInfo.processInfo.environment
    environment["GH_CONFIG_DIR"] = configDirectory.path
    environment["GH_PAGER"] = "cat"
    for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
        environment.removeValue(forKey: name)
    }
    process.environment = environment

    guard (try? process.run()) != nil else {
        return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}
