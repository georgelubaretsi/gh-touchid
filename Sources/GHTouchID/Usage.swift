// What `gh-touchid help` prints: every command's synopsis and description, made from the operations' declarations
// (plus `help`, `rpc` and `mcp`, which are not operations). `help <command>` and `<command> --help` print one
// command's, with an example of each of its forms, as does a wrong use of that command (on stderr, exit status 2).

enum Usage {
    /// A command that is not an operation.
    private struct Extra {
        let name: String
        let synopsis: String
        let description: String
        let example: String
    }

    private static let extras = [
        Extra(
            name: "help",
            synopsis: "gh-touchid help [<command>]",
            description: "`help` prints this, or one command's usage; so does `gh-touchid <command> --help`. "
                + "`gh-touchid --help --json` prints every operation as an MCP tool, with its input and output "
                + "schemas.",
            example: "gh-touchid help gh"
        ),
        Extra(
            name: "rpc",
            synopsis: "gh-touchid rpc",
            description: "`rpc` serves the operations as JSON-RPC 2.0 on stdin and stdout, one message per line, "
                + "through gh-touchid-adapter; approvals still come only from Touch ID, and operations with a secret "
                + "input are refused there.",
            example: "gh-touchid rpc"
        ),
        Extra(
            name: "mcp",
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

    /// A command's synopsis lines, descriptions and examples.
    private static func parts(_ name: String) -> (synopses: [String], descriptions: [String], examples: [String]) {
        if let extra = extras.first(where: { $0.name == name }) {
            return ([extra.synopsis], [extra.description], [extra.example])
        }
        let declared = operations.filter { $0.words.first == name }
        return (
            declared.map { commandSynopses[$0.name] ?? synopsis($0) },
            declared.map(\.description),
            declared.map(\.example)
        )
    }

    /// Every command.
    static var all: String {
        let all = names.map(parts)
        let synopses = all.flatMap(\.synopses).map { "  \($0)" }.joined(separator: "\n")
        let descriptions = all.flatMap(\.descriptions).map { wrapped($0) }.joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(descriptions)\n\(wrapped(footer))"
    }

    /// One command's; nil for a name that is not one.
    static func of(_ name: String) -> String? {
        guard names.contains(name) else {
            return nil
        }
        let command = parts(name)
        let synopses = command.synopses.map { "  \($0)" }.joined(separator: "\n")
        let descriptions = command.descriptions.map { wrapped($0) }.joined(separator: "\n")
        let examples = command.examples.map { "    \($0)" }.joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(descriptions)\n\nExample\(command.examples.count == 1 ? "" : "s"):\n"
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
