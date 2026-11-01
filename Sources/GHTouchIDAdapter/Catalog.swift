import Foundation
import MCP

// The operations the adapter offers, read once at start from the core's own declarations (`gh-touchid --help --json`),
// so that the adapter never describes an operation differently from the core that runs it.

/// One operation of the core, as the adapter calls it.
struct CoreOperation: Sendable {
    /// The MCP tool, as the core declares it.
    let tool: Tool
    /// The operation's command words: the name split on `_` (`app_create` → `app create`, `git_credential` →
    /// `git credential`); `gh` and `as` are one word.
    var words: [String] {
        tool.name.split(separator: "_").map(String.init)
    }
    /// Whether an input is a secret, which only the CLI's standard input may carry.
    var takesSecret: Bool {
        tool._meta?["gh-touchid/secret"]?.stringValue == "input"
    }

    /// The refusal of an operation with a secret input, naming the command that takes the secret on standard input.
    var secretRefusal: CallFailure {
        let command = (["gh-touchid"] + words).joined(separator: " ")
        return CallFailure(
            code: "secret_needs_stdin",
            message: "\(tool.name) takes a secret, which only standard input may carry: run `\(command)` in a "
                + "terminal with the secret piped in (see `\(command) --help`)",
            invalidInput: false
        )
    }
}

/// The core's operations, by name, and its version.
struct Catalog: Sendable {
    let operations: [CoreOperation]
    let version: String

    func operation(_ name: String) -> CoreOperation? {
        operations.first { $0.tool.name == name }
    }

    /// Reads the operations from `gh-touchid --help --json` and the version from `gh-touchid --json version`.
    static func load(core: String) throws -> Catalog {
        struct Tools: Decodable {
            let tools: [Tool]
        }
        let help = try runToEnd(core: core, arguments: ["--help", "--json"])
        guard let tools = try? JSONDecoder().decode(Tools.self, from: Data(help.utf8)) else {
            throw CallFailure(code: "adapter", message: "gh-touchid --help --json printed no tools",
                              invalidInput: false)
        }
        let version = try runToEnd(core: core, arguments: ["--json", "version"])
        let object = try? JSONSerialization.jsonObject(with: Data(version.utf8)) as? [String: Any]
        return Catalog(
            operations: tools.tools.map(CoreOperation.init),
            version: object?["version"] as? String ?? "unknown"
        )
    }
}

/// The JSON text the core prints for `arguments`, which take no input; its failure as a `CallFailure`.
private func runToEnd(core: String, arguments: [String]) throws -> String {
    switch CoreCall(core: core, arguments: arguments, input: Data()).run() {
    case .success(_, let text):
        return text
    case .failure(let failure):
        throw failure
    case .cancelled:
        throw CallFailure(code: "adapter", message: "gh-touchid was ended", invalidInput: false)
    }
}
