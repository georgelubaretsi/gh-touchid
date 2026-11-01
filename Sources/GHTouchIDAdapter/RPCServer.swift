import Foundation

// `gh-touchid rpc`: JSON-RPC 2.0, one message per line on standard input and output. The method is the operation's
// name, the params its input (`params._meta` is protocol metadata, taken off before the core sees the input), the
// result its output. The MCP SDK's JSON-RPC types are internal to it, so the framing is Foundation's JSON.
//
// Errors: -32700 for a line that is not JSON (and the loop goes on), -32600 for a message that is not a request,
// -32601 for an unknown method, -32602 for params that are not an object and for the core's invalid-input failures
// (exit status 2), -32000 for the core's other failures and the adapter's refusals, -32603 when the core could not run,
// -32800 (as in LSP) for a request the client cancelled. `data` is `{"code", "message"}` with the core's code.
// Progress goes out as notifications/progress when params._meta.progressToken is set; notifications/cancelled with a
// requestId ends that call's core. When standard input closes, the calls still running are answered, then it exits.

/// Serves JSON-RPC on standard input and output until standard input closes and every call has been answered.
func runRPC(core: String, catalog: Catalog) -> Never {
    let calls = Calls()
    endCallsOnSignals(calls)
    let server = RPCServer(core: core, catalog: catalog, calls: calls)
    while let line = readLine(strippingNewline: true) {
        server.handle(line)
    }
    calls.waitForAll()
    exit(0)
}

private final class RPCServer: @unchecked Sendable {
    private let core: String
    private let catalog: Catalog
    private let calls: Calls
    private let outputLock = NSLock()

    init(core: String, catalog: Catalog, calls: Calls) {
        self.core = core
        self.catalog = catalog
        self.calls = calls
    }

    /// One line from the client: a request (answered when its call ends), a notification, or something to refuse.
    func handle(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        else {
            respond(id: NSNull(), error: -32700, "parse error: the line is not JSON", code: "parse_error")
            return
        }
        guard let object = message as? [String: Any] else {
            respond(id: NSNull(), error: -32600, "invalid request: send one JSON-RPC object per line",
                    code: "invalid_request")
            return
        }
        let hasID = object["id"] != nil
        let validID = object["id"].flatMap(requestKey) != nil
        let id: Any = validID ? object["id"]! : NSNull()
        guard object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String, !hasID || validID
        else {
            respond(id: id, error: -32600, "invalid request: needs \"jsonrpc\": \"2.0\", a method, and a string or "
                + "number id (none for a notification)", code: "invalid_request")
            return
        }
        guard hasID else {
            notification(method, params: object["params"])
            return
        }
        request(id: id, method: method, params: object["params"])
    }

    private func request(id: Any, method: String, params: Any?) {
        var input: [String: Any] = [:]
        if let params {
            guard let object = params as? [String: Any] else {
                respond(id: id, error: -32602, "invalid params: params must be an object", code: "invalid_params")
                return
            }
            input = object
        }
        let progressToken = (input.removeValue(forKey: "_meta") as? [String: Any])?["progressToken"]
            .flatMap { (token: Any) -> Any? in token is String || isNumber(token) ? token : nil }
        guard let operation = catalog.operation(method) else {
            respond(id: id, error: -32601, "method not found: \(method)", code: "method_not_found")
            return
        }
        if operation.takesSecret {
            respond(id: id, failure: operation.secretRefusal)
            return
        }
        guard let arguments = try? JSONSerialization.data(withJSONObject: input) else {
            respond(id: id, error: -32602, "invalid params: params must be JSON", code: "invalid_params")
            return
        }
        let call = CoreCall(core: core, words: operation.words, arguments: arguments)
        let key = requestKey(id)!
        guard calls.add(call, key: key) else {
            respond(id: id, error: -32600, "invalid request: a call with this id is still running",
                    code: "invalid_request")
            return
        }
        DispatchQueue.global().async { [self] in
            var count = 0
            let outcome = call.run { message in
                guard let progressToken else {
                    return
                }
                count += 1
                self.send([
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": ["progressToken": progressToken, "progress": count, "message": message],
                ])
            }
            switch outcome {
            case .success(let value, _):
                send(["jsonrpc": "2.0", "id": id, "result": value])
            case .failure(let failure):
                respond(id: id, failure: failure)
            case .cancelled:
                respond(id: id, error: -32800, "request cancelled", code: "cancelled")
            }
            calls.remove(key)
        }
    }

    /// notifications/cancelled ends the call it names; other notifications need nothing.
    private func notification(_ method: String, params: Any?) {
        guard method == "notifications/cancelled",
              let requestID = (params as? [String: Any])?["requestId"],
              let key = requestKey(requestID) else {
            return
        }
        calls.cancel(key)
    }

    private func respond(id: Any, failure: CallFailure) {
        let number = failure.code == "adapter" ? -32603 : failure.invalidInput ? -32602 : -32000
        respond(id: id, error: number, failure.message, code: failure.code)
    }

    private func respond(id: Any, error number: Int, _ message: String, code: String) {
        send([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": number, "message": message, "data": ["code": code, "message": message]],
        ])
    }

    /// Writes `message` as one line, keys sorted; whole lines only, whichever call finishes first.
    private func send(_ message: [String: Any]) {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: options) else {
            return
        }
        data.append(UInt8(ascii: "\n"))
        outputLock.withLock {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

/// A JSON-RPC id as a key unique among ids: `s:` and the string, or `n:` and the number; nil for anything else
/// (null, booleans, objects), which this server does not accept as an id.
private func requestKey(_ id: Any) -> String? {
    if let string = id as? String {
        return "s:" + string
    }
    if isNumber(id), let number = id as? NSNumber {
        return "n:" + number.stringValue
    }
    return nil
}

/// Whether a JSONSerialization value is a number (not a boolean, which JSONSerialization also gives as NSNumber).
private func isNumber(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else {
        return false
    }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
}
