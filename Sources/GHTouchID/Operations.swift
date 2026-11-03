import Darwin
import Foundation

// The interfaces contract: every command is one declared operation, with a JSON Schema for its input and output and
// MCP-style annotations. One path runs them all: the command line's words, flags and positional arguments (or the JSON
// object of `--input <file|->`) become an input object, which is checked against the schema before anything runs;
// the output is printed as one JSON value with `--json`, else as the operation's text. Errors carry stable codes:
// with `--json`, the last line on stderr is `{"error": {"code", "message"}}`. Exit status 0 is success, 2 wrong
// input, 1 anything else; `gh` and `as` pass on the status of what they ran, except with `--json`, whose output
// carries it. `--help --json` prints every operation as an MCP tool, for the adapter behind `rpc` and `mcp`.
//
// Global flags `--json`, `--input <file|->` and `--no-input` go before or after the command's words, except after
// `gh`, `as` and `git credential`, whose arguments belong to another program: there they go before.

/// MCP's tool annotations.
struct Annotations {
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    let openWorld: Bool
}

/// What an operation knows of how it was called.
struct OperationContext {
    /// `--json` was given.
    let json: Bool
    /// `--no-input` was given, or neither stdin nor stderr is a terminal: nothing may be asked.
    let noInput: Bool
    /// Says how far the operation got, on stderr: one line, or with `--json` `{"progress": {"message": …}}`.
    let progress: (String) -> Void
}

/// One command, declared once: `help`, `--help --json` and the checks all come from here.
struct Operation {
    /// `reader_create`.
    let name: String
    /// `["reader", "create"]`.
    let words: [String]
    let title: String
    /// Plain prose for `help` and for the tool's description.
    let description: String
    /// One command line.
    let example: String
    /// The input fields taken from positional arguments, in order; the last may be an array, taking the rest.
    let positional: [String]
    let input: Schema
    let output: Schema
    let annotations: Annotations
    /// Runs with input already checked against `input`.
    let run: (OperationContext, [String: Any]) throws -> [String: Any]
    /// Text-mode stdout from the output; nil prints nothing.
    let text: ([String: Any]) -> String?
}

/// Every operation, the reader's included.
let operations: [Operation] = commandOperations + readerOperations

/// The operation called `name`.
func operation(named name: String) -> Operation? {
    operations.first { $0.name == name }
}

/// The largest input `--input` reads.
private let inputLimit = 1 << 20

/// The global flags.
struct GlobalOptions {
    var json = false
    var noInput = false
    /// `--input`'s file, `-` for stdin.
    var input: String?
}

/// Whether `--input -` took stdin, so that nothing else may read it.
private(set) var inputReadFromStandardInput = false

/// Takes the global flags out of `arguments`: before the command, and after it unless it is `gh`, `as` or
/// `git credential`, whose arguments are another program's.
func splitGlobalOptions(_ arguments: [String]) throws -> (GlobalOptions, [String]) {
    var options = GlobalOptions()
    var rest: [String] = []
    var index = 0
    var passing = false
    while index < arguments.count {
        let argument = arguments[index]
        if passing {
            rest.append(argument)
            index += 1
            continue
        }
        switch argument {
        case "--json":
            options.json = true
        case "--no-input":
            options.noInput = true
        case "--input":
            guard options.input == nil, index + 1 < arguments.count else {
                throw ToolError.usage
            }
            options.input = arguments[index + 1]
            index += 1
        default:
            rest.append(argument)
            passing = rest == ["gh"] || rest == ["as"] || rest == ["git", "credential"]
        }
        index += 1
    }
    return (options, rest)
}

/// The operation `arguments` start with (the one with the most words), and the arguments after its words.
func matchOperation(_ arguments: [String]) -> (Operation, [String])? {
    let matching = operations.filter { arguments.starts(with: $0.words) }
    guard let found = matching.max(by: { $0.words.count < $1.words.count }) else {
        return nil
    }
    return (found, Array(arguments.dropFirst(found.words.count)))
}

/// The declared fields of an object schema.
func fields(of schema: Schema) -> [(name: String, schema: Schema)] {
    if case let .object(properties, _, _) = schema {
        return properties
    }
    return []
}

/// The required fields of an object schema.
func requiredFields(of schema: Schema) -> [String] {
    if case let .object(_, required, _) = schema {
        return required
    }
    return []
}

/// A field's command-line flag: `client_id` is `--client-id`, the array `repos` is `--repo`.
func flagName(_ field: String) -> String {
    field == "repos" ? "--repo" : "--" + field.replacingOccurrences(of: "_", with: "-")
}

/// Switches that are not `--<field>` or `--no-<field>`.
private let switchAliases: [String: (field: String, value: Bool)] = ["--no-open": ("open_browser", false)]

/// The input object of a command line: positional arguments into `operation.positional`; `--<field> <value>` for
/// strings and integers, repeated for arrays; `--<field>` and `--no-<field>` for booleans. Anything else is a usage
/// error; values are checked by the schema afterwards.
func commandLineInput(_ operation: Operation, _ arguments: [String]) throws -> [String: Any] {
    let declared = fields(of: operation.input)
    func schema(_ name: String) -> Schema? {
        declared.first { $0.name == name }?.schema
    }
    var input: [String: Any] = [:]
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        guard argument.hasPrefix("--"), argument.count > 2 else {
            positional.append(argument)
            continue
        }
        if let alias = switchAliases[argument], schema(alias.field) != nil {
            guard input[alias.field] == nil else {
                throw ToolError.input("\(argument) is given more than once")
            }
            input[alias.field] = alias.value
            continue
        }
        var match: (name: String, schema: Schema, negated: Bool)?
        for field in declared where !operation.positional.contains(field.name) && !field.schema.isSecret {
            if flagName(field.name) == argument {
                match = (field.name, field.schema, false)
            } else if case .boolean = field.schema, "--no-" + flagName(field.name).dropFirst(2) == argument {
                match = (field.name, field.schema, true)
            }
        }
        guard let match else {
            throw ToolError.usage
        }
        switch match.schema {
        case .boolean:
            guard input[match.name] == nil else {
                throw ToolError.input("\(argument) is given more than once")
            }
            input[match.name] = !match.negated
        case .array:
            guard index < arguments.count else {
                throw ToolError.usage
            }
            input[match.name] = (input[match.name] as? [String] ?? []) + [arguments[index]]
            index += 1
        default:
            guard index < arguments.count else {
                throw ToolError.usage
            }
            guard input[match.name] == nil else {
                throw ToolError.input("\(argument) is given more than once")
            }
            let value = arguments[index]
            if case .integer = match.schema, let number = Int(value) {
                input[match.name] = number
            } else {
                input[match.name] = value
            }
            index += 1
        }
    }
    for name in operation.positional {
        guard let field = schema(name) else {
            continue
        }
        if case .array = field {
            if !positional.isEmpty {
                input[name] = positional
            }
            positional = []
            break
        }
        guard !positional.isEmpty else {
            guard !requiredFields(of: operation.input).contains(name) else {
                throw ToolError.usage
            }
            continue
        }
        input[name] = positional.removeFirst()
    }
    guard positional.isEmpty else {
        throw ToolError.usage
    }
    return input
}

/// The JSON object `--input` names: a file, or `-` for stdin; at most 1 MiB.
func readInputDocument(_ source: String) throws -> [String: Any] {
    let handle: FileHandle
    if source == "-" {
        inputReadFromStandardInput = true
        handle = FileHandle.standardInput
    } else {
        guard let file = FileHandle(forReadingAtPath: source) else {
            throw ToolError.input("cannot read the input file \(printable(source))")
        }
        handle = file
    }
    var data = Data()
    while data.count <= inputLimit {
        guard let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty else {
            break
        }
        data.append(chunk)
    }
    guard data.count <= inputLimit else {
        throw ToolError.input("the input is larger than 1 MiB")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data), let input = object as? [String: Any] else {
        throw ToolError.input("the input must be one JSON object")
    }
    return input
}

/// What `account add` and `app add` ask at a hidden prompt for a secret not piped to stdin.
private let secretPrompts = ["token": "GitHub token: ", "client_secret": "Client secret: "]

/// Runs `operation` with `input`: reads a required secret the command line left out (from stdin, or at a hidden
/// prompt), checks the input, runs, and prints the output. The exit status.
func perform(
    _ operation: Operation,
    input given: [String: Any],
    options: GlobalOptions,
    fromCommandLine: Bool
) throws -> Int32 {
    var input = given
    let noInput = options.noInput || (isatty(STDIN_FILENO) == 0 && isatty(STDERR_FILENO) == 0)
    let missingSecrets = fields(of: operation.input).filter {
        $0.schema.isSecret && requiredFields(of: operation.input).contains($0.name) && input[$0.name] == nil
    }
    if fromCommandLine, !missingSecrets.isEmpty {
        // everything else is checked before anything is read or asked
        var probe = input
        missingSecrets.forEach { probe[$0.name] = "x" }
        try check(operation.input, probe)
        for secret in missingSecrets {
            if isatty(STDIN_FILENO) != 0, noInput {
                let positional = operation.positional.compactMap { input[$0] as? String }
                let words = (["gh-touchid"] + operation.words + positional).joined(separator: " ")
                throw ToolError.inputNeeded("\(words) < \(secret.name.replacingOccurrences(of: "_", with: "-"))-file")
            }
            input[secret.name] = try readToken(prompt: secretPrompts[secret.name] ?? "Secret: ")
        }
    }
    // secrets come on stdin only: a file named on the command line is one the program opens, and stays on disk
    if let source = options.input, source != "-",
       let secret = fields(of: operation.input).first(where: { $0.schema.isSecret && input[$0.name] != nil }) {
        throw ToolError.input(
            "\(secret.name) is a secret, and secrets come only on stdin: pass the input with --input - instead of a file"
        )
    }
    try check(operation.input, input)
    let json = options.json
    let context = OperationContext(json: json, noInput: noInput) { message in
        if json {
            fputs("\(jsonLine(["progress": ["message": message]]))\n", stderr)
        } else {
            fputs("\(message)\n", stderr)
        }
    }
    if json {
        Notices.keepForResult()
    }
    var output = try operation.run(context, input)
    let notices = Notices.take()
    if !notices.isEmpty {
        output["notices"] = notices
    }
    // checked on every call, as the input is: a result that breaks its schema would mislead whoever reads it
    if let problem = operation.declaredOutput.violation(output, path: "") {
        throw ToolError.outputInvalid(operation: operation.name, problem: problem)
    }
    if json {
        print(jsonLine(output))
        return 0
    }
    if let text = operation.text(output) {
        print(text)
    }
    if let status = output["exit_code"] as? Int {
        return Int32(truncatingIfNeeded: status)
    }
    return 0
}

/// Checks `input` against `schema`.
private func check(_ schema: Schema, _ input: [String: Any]) throws {
    if let problem = schema.violation(input, path: "") {
        throw ToolError.input(problem)
    }
}

/// `value` as one line of JSON, keys sorted.
func jsonLine(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
    ) else {
        return "null"
    }
    return String(decoding: data, as: UTF8.self)
}

/// An error already told in text mode (as `app create` tells a sign-in that failed after the App was stored): text
/// mode only exits with its status, `--json` reports it.
struct ToldError: Error {
    let error: ToolError
}

/// Reports `error` on stderr and returns the exit status: in text mode `gh-touchid: <message>` (usage errors print
/// the usage), with `--json` `{"error": {"code", "message"}}` as the last line.
func report(_ error: Error, json: Bool) -> Int32 {
    // the notices an operation kept for its result, which it will not return now
    Notices.printKept()
    if let told = error as? ToldError {
        if json {
            fputs("\(jsonLine(["error": ["code": told.error.code, "message": told.error.description]]))\n", stderr)
        }
        return told.error.exitStatus
    }
    guard let error = error as? ToolError else {
        let message = "\(error)"
        if json {
            fputs("\(jsonLine(["error": ["code": "error", "message": message]]))\n", stderr)
        } else {
            fputs("gh-touchid: \(message)\n", stderr)
        }
        return 1
    }
    if json {
        let message: String
        switch error {
        case .usage:
            message = "not a gh-touchid command, or a wrong use of one; run `gh-touchid help`"
        case let .commandUsage(command):
            message = "a wrong use of `gh-touchid \(command)`; run `gh-touchid help \(command)`"
        default:
            message = error.description
        }
        fputs("\(jsonLine(["error": ["code": error.code, "message": message]]))\n", stderr)
        return error.exitStatus
    }
    switch error {
    case .usage, .commandUsage:
        fputs("\(error.description)\n", stderr)
    default:
        fputs("gh-touchid: \(error)\n", stderr)
    }
    return error.exitStatus
}

/// `--help --json`: every operation as an MCP tool. A tool with a secret input or output says so in `_meta`.
func toolsDocument() -> [String: Any] {
    let tools = operations.map { operation -> [String: Any] in
        var tool: [String: Any] = [
            "name": operation.name,
            "title": operation.title,
            "description": operation.description,
            "inputSchema": operation.input.jsonSchema,
            "outputSchema": operation.declaredOutput.jsonSchema,
            "annotations": [
                "title": operation.title,
                "readOnlyHint": operation.annotations.readOnly,
                "destructiveHint": operation.annotations.destructive,
                "idempotentHint": operation.annotations.idempotent,
                "openWorldHint": operation.annotations.openWorld,
            ],
        ]
        if operation.input.hasSecret {
            tool["_meta"] = ["gh-touchid/secret": "input"]
        } else if operation.output.hasSecret {
            tool["_meta"] = ["gh-touchid/secret": "output"]
        }
        return tool
    }
    return ["tools": tools]
}

/// The synopsis of an operation as `help` shows it, from its words, positional fields and flags.
func synopsis(_ operation: Operation) -> String {
    var parts = ["gh-touchid"] + operation.words
    var stdin: String?
    let required = requiredFields(of: operation.input)
    for name in operation.positional {
        guard let field = fields(of: operation.input).first(where: { $0.name == name }) else {
            continue
        }
        let placeholder = "<\(name.replacingOccurrences(of: "_", with: "-"))>"
        if case .array = field.schema {
            parts.append("[\(placeholder)...]")
        } else {
            parts.append(required.contains(name) ? placeholder : "[\(placeholder)]")
        }
    }
    for field in fields(of: operation.input) where !operation.positional.contains(field.name) {
        let flag = flagName(field.name)
        let value = "<\(flag.dropFirst(2))>"
        if field.schema.isSecret {
            stdin = "< \(flag.dropFirst(2))"
            continue
        }
        switch field.schema {
        case .boolean:
            switch field.name {
            case "open_browser":
                parts.append("[--no-open]")
            case "git_setup":
                parts.append("[--git-setup|--no-git-setup]")
            default:
                parts.append("[\(flag)]")
            }
        case .array:
            parts.append("[\(flag) \(value)]...")
        default:
            parts.append(required.contains(field.name) ? "\(flag) \(value)" : "[\(flag) \(value)]")
        }
    }
    if let stdin {
        parts.append(stdin)
    }
    return parts.joined(separator: " ")
}
