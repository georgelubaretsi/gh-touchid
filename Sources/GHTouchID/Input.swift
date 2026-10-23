import Darwin
import Foundation

/// The longest `elevate`.
let longestElevation: TimeInterval = 24 * 60 * 60

/// `--name value` options; each name maps to its values in order.
func parseOptions(_ arguments: [String], allowed: Set<String>) throws -> [String: [String]] {
    var options: [String: [String]] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard allowed.contains(name), index + 1 < arguments.count else {
            throw ToolError.usage
        }
        options[name, default: []].append(arguments[index + 1])
        index += 2
    }
    return options
}

/// `30m`, `8h`, `1h30m`, `1d`: at most one day.
func parseDuration(_ text: String) throws -> TimeInterval {
    let pattern = #"^(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?$"#
    let range = NSRange(text.startIndex..., in: text)
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: range) else {
        throw ToolError.input("--for takes a duration like 30m, 8h, 1h30m or 1d")
    }
    func part(_ index: Int) -> Double {
        guard let range = Range(match.range(at: index), in: text) else {
            return 0
        }
        return Double(text[range]) ?? 0
    }
    let seconds = part(1) * 86400 + part(2) * 3600 + part(3) * 60
    guard seconds > 0 else {
        throw ToolError.input("--for takes a duration like 30m, 8h, 1h30m or 1d")
    }
    guard seconds <= longestElevation else {
        throw ToolError.input("the longest duration is 1d")
    }
    return seconds
}

func localTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func clockTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

/// A path with the home directory shown as `~`.
func displayFolder(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

/// One line of at most 180 characters, for the log.
func commandSummary(_ arguments: [String]) -> String {
    let summary = arguments
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    return String(summary.prefix(180))
}

/// Printable text of at most `limit` characters from something another process sent.
func printable(_ text: String, limit: Int = 200) -> String {
    String(String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }).prefix(limit))
}

func normalizeToken(_ raw: String) throws -> String {
    var token = raw
    while token.last == "\n" || token.last == "\r" {
        token.removeLast()
    }

    let pasteStart = "\u{1B}[200~"
    let pasteEnd = "\u{1B}[201~"
    if token.hasPrefix(pasteStart), token.hasSuffix(pasteEnd) {
        token.removeFirst(pasteStart.count)
        token.removeLast(pasteEnd.count)
    }

    guard !token.isEmpty,
          token.unicodeScalars.allSatisfy({ (0x21 ... 0x7E).contains($0.value) }) else {
        throw ToolError.invalidToken
    }
    return token
}

/// A token or secret from hidden terminal input, after `prompt`, or from stdin when it is not a terminal.
func readToken(prompt: String = "GitHub token: ") throws -> String {
    if isatty(STDIN_FILENO) == 0 {
        return try normalizeToken(readStandardInputText())
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        throw ToolError.input("cannot read terminal settings")
    }

    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
        throw ToolError.input("cannot disable terminal echo")
    }

    defer {
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        fputs("\n", stderr)
    }

    fputs(prompt, stderr)
    fflush(stderr)
    guard let token = readLine(strippingNewline: true) else {
        throw ToolError.input("no token was provided")
    }
    return try normalizeToken(token)
}

func readStandardInputText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw ToolError.input("stdin is not valid UTF-8")
    }
    return text
}

func discardStandardInput() {
    _ = FileHandle.standardInput.readDataToEndOfFile()
}
