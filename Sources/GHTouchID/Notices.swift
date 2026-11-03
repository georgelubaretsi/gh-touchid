import Foundation

// What gh-touchid tells whoever called it besides an operation's result: that the reader is in use and must not
// create or change anything, a token it could not revoke, how to approve a session, why a session may not help, a
// problem with the background agent, which repository a failed gh had its token for when its command line named none
// that gh-touchid reads. Without `--json` each goes to stderr as it happens, as `gh-touchid: <notice>`.
// With `--json` they are kept and returned in the result's `notices`, since a caller that reads JSON (an agent, through
// `rpc` and `mcp` too, whose adapter passes on only the result) does not read stderr's other lines; when the operation
// fails instead, they go to stderr ahead of the error line. Messages that only repeat the result stay text-mode lines.

enum Notices {
    private static let lock = NSLock()
    /// The notices kept for the result; nil while each is printed as it comes.
    private static var kept: [String]?

    /// From now on, notices are kept for the result instead of printed.
    static func keepForResult() {
        lock.lock()
        defer { lock.unlock() }
        kept = kept ?? []
    }

    /// Tells the caller `notice`, a sentence without the `gh-touchid: ` that text mode puts before it.
    static func tell(_ notice: String) {
        lock.lock()
        if kept != nil {
            kept?.append(notice)
            lock.unlock()
            return
        }
        lock.unlock()
        fputs("gh-touchid: \(notice)\n", stderr)
    }

    /// The notices kept so far, which are no longer kept.
    static func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = kept ?? []
        if kept != nil {
            kept = []
        }
        return taken
    }

    /// Prints the notices kept so far, for an operation that fails instead of returning them.
    static func printKept() {
        for notice in take() {
            fputs("gh-touchid: \(notice)\n", stderr)
        }
    }
}

/// `notices` in every operation's result: present when gh-touchid has something to tell besides it.
let noticesSchema = Schema.array(
    .string(),
    description: "What gh-touchid tells the caller besides the result, in order: that the reader is in use and must "
        + "not create or change anything, a token it could not revoke, which repository a failed gh had its token "
        + "for, a warning. Present only when there is any."
)

extension Operation {
    /// `output` with `notices`, which any operation's result may carry.
    var declaredOutput: Schema {
        guard case let .object(properties, required, description) = output else {
            return output
        }
        return .object(
            properties: properties + [("notices", noticesSchema)],
            required: required,
            description: description
        )
    }
}
