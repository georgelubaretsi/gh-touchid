import Darwin
import Foundation

// The adapter's only way to act: run the core (gh-touchid) once per call, the same way a script would, with
// `--json --input -` and the arguments as JSON on its standard input. The core does every check, every Touch ID dialog
// and every Keychain read; the adapter only carries its JSON and its progress lines, and ends it when a client cancels.

/// A failure as the core reports it in its last line of standard error, `{"error": {"code": …, "message": …}}`, or one
/// of the adapter's own: `adapter` when the core could not run or said nothing readable, `secret_needs_stdin`.
struct CallFailure: Error {
    let code: String
    let message: String
    /// The core's exit status 2: the input was invalid, so the call cannot succeed as asked.
    let invalidInput: Bool
}

/// How one call of the core ended.
enum CallOutcome {
    /// The one JSON value the core printed on standard output (a JSONSerialization value), and the text it came as.
    case success(value: Any, text: String)
    case failure(CallFailure)
    /// A client cancelled the call and the core was ended.
    case cancelled
}

/// One run of the core: started by `run`, which blocks until it ends, and ended early by `cancel` from any thread with
/// SIGTERM, which the core handles (see `cancel`).
final class CoreCall: @unchecked Sendable {
    private let core: String
    private let arguments: [String]
    private let input: Data
    private let process = Process()
    private let lock = NSLock()
    private var started = false
    private var exited = false
    private var cancelled = false

    /// A call of the core at `core` with `arguments`, given `input` on standard input.
    init(core: String, arguments: [String], input: Data) {
        self.core = core
        self.arguments = arguments
        self.input = input
    }

    /// The core with `--json --input -` and the operation's words, given `arguments` as one JSON object.
    convenience init(core: String, words: [String], arguments: Data) {
        self.init(core: core, arguments: ["--json", "--input", "-"] + words, input: arguments)
    }

    /// Runs the core to its end. `progress` gets the message of each `{"progress": {"message": …}}` line of its
    /// standard error, in order, on one queue; every other line goes on to the adapter's standard error.
    func run(progress: @escaping (String) -> Void = { _ in }) -> CallOutcome {
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: core)
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { [self] _ in
            lock.withLock { exited = true }
            ended.signal()
        }
        let streams = DispatchGroup()
        let output = Collected()
        let errors = StandardErrorLines(progress: progress)
        streams.enter()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streams.leave()
            } else {
                output.append(data)
            }
        }
        streams.enter()
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errors.finish()
                streams.leave()
            } else {
                errors.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            return .failure(CallFailure(
                code: "adapter",
                message: "could not run gh-touchid at \(core): \(error.localizedDescription)",
                invalidInput: false
            ))
        }
        let cancelledEarly = lock.withLock { () -> Bool in
            started = true
            return cancelled
        }
        if cancelledEarly {
            terminate()
        }
        // On its own queue: a core that exits before reading all of its input must not hold up the call (EPIPE is
        // an error here, since main ignores SIGPIPE).
        let input = self.input
        DispatchQueue.global().async {
            let writer = standardInput.fileHandleForWriting
            try? writer.write(contentsOf: input)
            try? writer.close()
        }

        ended.wait()
        // The core's output ends with it, unless something it started kept a copy of the pipes; then what came in
        // the next 5 seconds is all there is.
        _ = streams.wait(timeout: .now() + 5)
        if lock.withLock({ cancelled }) {
            return .cancelled
        }
        return outcome(output: output.data, lastError: errors.lastLine)
    }

    /// Ends the call: SIGTERM to the core now (or as soon as it has started). Never SIGKILL: the core passes SIGTERM on
    /// to gh and then revokes the token it handed out, a request that may take up to its 30-second timeout, and a
    /// forced kill in between would leave the token valid until it expires. The call ends when the core does.
    func cancel() {
        let running = lock.withLock { () -> Bool in
            cancelled = true
            return started && !exited
        }
        if running {
            terminate()
        }
    }

    private func terminate() {
        kill(process.processIdentifier, SIGTERM)
    }

    /// The call's result: the core's error line when it failed with one, else its one JSON value on standard output
    /// (`gh` and `as` exit with gh's status and still print one), else an `adapter` failure saying what happened.
    private func outcome(output: Data, lastError: String?) -> CallOutcome {
        let status = process.terminationStatus
        let exitedNormally = process.terminationReason == .exit
        if !(exitedNormally && status == 0), let failure = lastError.flatMap(errorEnvelope) {
            return .failure(CallFailure(code: failure.code, message: failure.message, invalidInput: status == 2))
        }
        if let value = try? JSONSerialization.jsonObject(with: output, options: [.fragmentsAllowed]) {
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(value: value, text: text)
        }
        let how = exitedNormally ? "exited with status \(status)" : "was ended by signal \(status)"
        return .failure(CallFailure(
            code: "adapter",
            message: "gh-touchid \(how) without a JSON result",
            invalidInput: false
        ))
    }
}

/// `{"error": {"code": …, "message": …}}`, read; nil for any other line.
private func errorEnvelope(_ line: String) -> (code: String, message: String)? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let error = object["error"] as? [String: Any],
          let code = error["code"] as? String,
          let message = error["message"] as? String else {
        return nil
    }
    return (code, message)
}

/// Bytes collected from one pipe, under a lock.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    func append(_ data: Data) {
        lock.withLock { collected.append(data) }
    }

    var data: Data {
        lock.withLock { collected }
    }
}

/// The core's standard error, split into lines as it comes: progress lines to `progress`, every other line to the
/// adapter's standard error; the last non-empty line kept, which is the error line when the core failed.
private final class StandardErrorLines: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (String) -> Void
    private var pending = Data()
    private var last: String?

    init(progress: @escaping (String) -> Void) {
        self.progress = progress
    }

    var lastLine: String? {
        lock.withLock { last }
    }

    func append(_ data: Data) {
        let lines = lock.withLock { () -> [Data] in
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(pending[pending.startIndex..<newline])
                pending = pending[(newline + 1)...]
            }
            return lines
        }
        lines.forEach(take)
    }

    func finish() {
        let rest = lock.withLock { () -> Data in
            defer { pending = Data() }
            return pending
        }
        if !rest.isEmpty {
            take(rest)
        }
    }

    private func take(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        lock.withLock { last = line }
        if let message = progressMessage(line) {
            progress(message)
        } else {
            writeStandardError(line + "\n")
        }
    }
}

/// `{"progress": {"message": …}}`, read; nil for any other line.
private func progressMessage(_ line: String) -> String? {
    guard line.hasPrefix("{"),
          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let progress = object["progress"] as? [String: Any] else {
        return nil
    }
    return progress["message"] as? String
}

private let standardErrorLock = NSLock()

/// Writes `text` to the adapter's standard error, whole, and never fails the caller: the client may have closed it,
/// and the MCP SDK makes standard output non-blocking, which on a terminal is standard error too.
func writeStandardError(_ text: String) {
    standardErrorLock.withLock {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}
