// What `gh-touchid help` prints: every command's synopsis and description, made from the operations' declarations
// (plus `help`, `rpc` and `mcp`, which are not operations). `help <command>` and `<command> --help` print one
// command's, with an example of each of its forms, as does a wrong use of that command (on stderr, exit status 2).
// `--help --json` lists the same `commands`, so the text help and the generated docs/commands.md cannot disagree.

enum Usage {
    /// One form of a command, as `help` shows it.
    struct Command {
        /// `["reader", "create"]`.
        let words: [String]
        /// The operation's name; nil for `help`, `rpc` and `mcp`, which are not operations.
        let tool: String?
        /// The operation's title, or the extra's: what the command does, in a few words.
        let title: String
        let synopsis: String
        let description: String
        let example: String
    }

    /// A command that is not an operation.
    private struct Extra {
        let name: String
        let title: String
        let synopsis: String
        let description: String
        let example: String
    }

    private static let extras = [
        Extra(
            name: "help",
            title: "Print every command's usage, or one command's",
            synopsis: "gh-touchid help [<command>]",
            description: "`help` prints this, or one command's usage; so does `gh-touchid <command> --help`. "
                + "`gh-touchid --help --json` prints every operation as an MCP tool, with its input and output "
                + "schemas, and every command's usage and every error code.",
            example: "gh-touchid help gh"
        ),
        Extra(
            name: "rpc",
            title: "Serve the operations over JSON-RPC",
            synopsis: "gh-touchid rpc",
            description: "`rpc` serves the operations as JSON-RPC 2.0 on stdin and stdout, one message per line, "
                + "through gh-touchid-adapter; approvals still come only from Touch ID, and operations with a secret "
                + "input are refused there.",
            example: "gh-touchid rpc"
        ),
        Extra(
            name: "mcp",
            title: "Serve the operations as an MCP server",
            synopsis: "gh-touchid mcp",
            description: "`mcp` serves the operations as an MCP server on stdin and stdout, through "
                + "gh-touchid-adapter, with the same limits as `rpc`.",
            example: "gh-touchid mcp"
        ),
    ]

    /// The commands in the order `help` lists them; operations of other first words follow.
    private static let order = [
        "app", "account", "reader", "gh", "git", "as", "session", "elevate", "status", "setup", "lock", "version",
        "help", "rpc", "mcp",
    ]

    private static let footer = "Every use is logged to ~/Library/Logs/gh-touchid/access.log. With --json, output "
        + "is one JSON value and errors end stderr with {\"error\": {\"code\", \"message\"}}; --input <file|-> "
        + "takes the input as a JSON object; --no-input never asks."

    /// The command names, in order.
    private static var names: [String] {
        var names = order.filter { name in
            extras.contains { $0.name == name } || operations.contains { $0.words.first == name }
        }
        for operation in operations {
            if let first = operation.words.first, !names.contains(first) {
                names.append(first)
            }
        }
        return names
    }

    /// The forms of the command `name` (its first word), in declaration order.
    private static func forms(_ name: String) -> [Command] {
        if let extra = extras.first(where: { $0.name == name }) {
            return [Command(words: [extra.name], tool: nil, title: extra.title, synopsis: extra.synopsis,
                            description: extra.description, example: extra.example)]
        }
        return operations.filter { $0.words.first == name }.map { operation in
            Command(words: operation.words, tool: operation.name, title: operation.title,
                    synopsis: commandSynopses[operation.name] ?? synopsis(operation),
                    description: operation.description, example: operation.example)
        }
    }

    /// Every form of every command, in the order `help` lists them.
    static var commands: [Command] {
        names.flatMap(forms)
    }

    /// Every command.
    static var all: String {
        let all = commands
        let synopses = all.map { "  \($0.synopsis)" }.joined(separator: "\n")
        let descriptions = all.map { wrapped($0.description) }.joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(descriptions)\n\(wrapped(footer))"
    }

    /// One command's; nil for a name that is not one.
    static func of(_ name: String) -> String? {
        guard names.contains(name) else {
            return nil
        }
        let command = forms(name)
        let synopses = command.map { "  \($0.synopsis)" }.joined(separator: "\n")
        let descriptions = command.map { wrapped($0.description) }.joined(separator: "\n")
        let examples = command.map { "    \($0.example)" }.joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(descriptions)\n\nExample\(command.count == 1 ? "" : "s"):\n"
            + examples
    }

    /// `text` in lines of at most 116 characters.
    private static func wrapped(_ text: String) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + 1 + word.count > 116 {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " \(word)"
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
