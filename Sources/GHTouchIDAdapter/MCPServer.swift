import Foundation
import MCP

// `gh-touchid mcp`: the official MCP Swift SDK's server over stdio. Its tools are the core's operations as the core
// declares them; each call runs the core once. A result's JSON is the structured content and, for clients that read
// only text, one text block; a failure is a tool error carrying the core's code. Progress lines become
// notifications/progress when the request asked for them, and notifications/cancelled ends the core (the SDK cancels
// the handler's task; the cancellation handler signals the core).

/// Serves MCP on standard input and output until the client closes standard input, then ends any call still running
/// and exits.
func runMCP(core: String, catalog: Catalog) async -> Never {
    let calls = Calls()
    endCallsOnSignals(calls)
    let server = Server(
        name: "gh-touchid",
        version: catalog.version,
        title: "gh-touchid",
        instructions: "Each tool runs gh-touchid once. Approvals come only from gh-touchid's own Touch ID dialog on "
            + "this Mac; tools whose input is a secret are refused here and run in a terminal instead.",
        capabilities: .init(tools: .init(listChanged: false))
    )
    let tools = catalog.operations.map(\.tool)
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
        guard let operation = catalog.operation(parameters.name) else {
            throw MCPError.invalidParams("unknown tool: \(parameters.name)")
        }
        if operation.takesSecret {
            return errorResult(operation.secretRefusal)
        }
        return try await call(
            operation,
            arguments: parameters.arguments ?? [:],
            progressToken: parameters._meta?.progressToken,
            core: core,
            calls: calls,
            server: server
        )
    }
    do {
        try await server.start(transport: StdioTransport())
    } catch {
        writeStandardError("gh-touchid-adapter: could not serve MCP on standard input and output: \(error)\n")
        exit(1)
    }
    await server.waitUntilCompleted()
    // Standard input is closed: nobody is left to answer, so the calls still running end now.
    calls.endAll()
    exit(0)
}

/// Runs `operation` with `arguments`: progress to the client while it runs (when it gave `progressToken`), the result
/// or the core's failure when it ends; throws CancellationError when the client cancelled, so that the SDK sends no
/// response.
private func call(
    _ operation: CoreOperation,
    arguments: [String: Value],
    progressToken: ProgressToken?,
    core: String,
    calls: Calls,
    server: Server
) async throws -> CallTool.Result {
    let input: Data
    do {
        input = try JSONEncoder().encode(arguments)
    } catch {
        throw MCPError.invalidParams("the arguments are not JSON: \(error)")
    }
    let coreCall = CoreCall(core: core, words: operation.words, arguments: input)
    let key = UUID().uuidString
    _ = calls.add(coreCall, key: key)
    defer { calls.remove(key) }

    // One sender, so that notifications go out in the order the core wrote its lines.
    let (messages, sink) = AsyncStream<String>.makeStream()
    let sender = Task {
        var count = 0
        for await message in messages {
            guard let progressToken else {
                continue
            }
            count += 1
            let progress = ProgressNotification.Parameters(
                progressToken: progressToken,
                progress: Double(count),
                message: message
            )
            try? await server.notify(ProgressNotification.message(progress))
        }
    }
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: coreCall.run { sink.yield($0) })
            }
        }
    } onCancel: {
        coreCall.cancel()
    }
    sink.finish()
    await sender.value

    switch outcome {
    case .success(_, let text):
        // Typed as optional: a plain Value would pick the SDK's generic, throwing initializer instead.
        let structured: Value? = try? JSONDecoder().decode(Value.self, from: Data(text.utf8))
        return CallTool.Result(content: [.text(text)], structuredContent: structured)
    case .failure(let failure):
        return errorResult(failure)
    case .cancelled:
        throw CancellationError()
    }
}

/// A tool error: `{"error": {"code", "message"}}` as its text, and the same object under `_meta["gh-touchid/error"]`.
private func errorResult(_ failure: CallFailure) -> CallTool.Result {
    let error: Value = .object(["code": .string(failure.code), "message": .string(failure.message)])
    let envelope: Value = .object(["error": error])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = (try? encoder.encode(envelope)).map { String(decoding: $0, as: UTF8.self) } ?? failure.message
    return CallTool.Result(
        content: [.text(text)],
        isError: true,
        _meta: Metadata(additionalFields: ["gh-touchid/error": error])
    )
}
