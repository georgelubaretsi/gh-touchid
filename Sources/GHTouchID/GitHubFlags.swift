import Foundation

/// The flags of one gh command, by long name and by shorthand: true when the flag takes a value. `--help` is gh's own,
/// a switch on every command. `-h` is listed only when the command defines it (`auth status -h <hostname>`): while
/// Cobra looks for the command, it knows no other `-h`, so that one takes the next argument as its value, as in
/// `gh -h x pr list`, which runs `pr list`; once the command runs, it is the help switch (`parsedArguments`).
struct CommandFlags {
    var long: [String: Bool] = ["help": false]
    var short: [Character: Bool] = [:]
}

/// One argument of a gh command as pflag, gh's flag parser, reads it.
enum ParsedArgument {
    /// A flag by the name it was written with (`repo` for `--repo`, `R` for `-R`) and its value: nil for a switch, or
    /// for a flag that takes a value and has none left (gh refuses that).
    case flag(name: String, value: String?)
    /// An argument that is not a flag, or any argument after `--`.
    case positional(String)
}

/// `arguments` as pflag reads them with `flags`: `--x v`, `--x=v`, `-x v`, `-xv`, `-x=v`, and groups of short flags
/// in which the first flag that takes a value takes the rest of the group, or else the next argument. `--` ends the
/// flags; `-` alone is an argument. An unknown long flag takes nothing and an unknown short flag ends its group: gh
/// refuses both, so what they would take cannot matter. The one reading of a gh command's flags: the repository, the
/// dialog's title and body, and `gh api`'s method and fields all come from it.
func parsedArguments(_ arguments: [String], flags: CommandFlags) -> [ParsedArgument] {
    var parsed: [ParsedArgument] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        if argument == "--" {
            parsed += arguments[index...].map { .positional($0) }
            break
        }
        guard argument.count > 1, argument.hasPrefix("-") else {
            parsed.append(.positional(argument))
            continue
        }
        if argument.hasPrefix("--") {
            let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if parts.count == 2 {
                parsed.append(.flag(name: name, value: String(parts[1])))
            } else if flags.long[name] == true {
                parsed.append(.flag(name: name, value: index < arguments.count ? arguments[index] : nil))
                index += 1
            } else {
                parsed.append(.flag(name: name, value: nil))
            }
            continue
        }
        var group = argument.dropFirst()
        // `-h`, unless the command defines it, is the help switch Cobra adds as the command runs
        while let shorthand = group.first, let takesValue = flags.short[shorthand] ?? (shorthand == "h" ? false : nil) {
            let after = group.dropFirst()
            // `-x=v`, a switch's value included
            if after.count > 1, after.hasPrefix("=") {
                parsed.append(.flag(name: String(shorthand), value: String(after.dropFirst())))
                break
            }
            guard takesValue else {
                parsed.append(.flag(name: String(shorthand), value: nil))
                group = after
                continue
            }
            if after.isEmpty {
                parsed.append(.flag(name: String(shorthand), value: index < arguments.count ? arguments[index] : nil))
                index += 1
            } else {
                parsed.append(.flag(name: String(shorthand), value: String(after)))
            }
            break
        }
    }
    return parsed
}

/// The value of the last of the flags `names` among `parsed`, as gh keeps the last one given.
func lastFlagValue(_ parsed: [ParsedArgument], _ names: Set<String>) -> String? {
    var found: String?
    for case let .flag(name, value?) in parsed where names.contains(name) {
        found = value
    }
    return found
}

/// The value of the last `-R`/`--repo` (gh acts on the last one), read from a command's `arguments` with its `flags`.
func repositorySelector(_ arguments: [String], flags: CommandFlags) throws -> String? {
    var selected: String?
    for case let .flag(name, value) in parsedArguments(arguments, flags: flags) where name == "repo" || name == "R" {
        guard let value else {
            throw ToolError.input("\(name == "R" ? "-R" : "--repo") needs a repository")
        }
        selected = value
    }
    return selected
}
