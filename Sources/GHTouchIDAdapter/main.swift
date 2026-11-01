// gh-touchid-adapter: what `gh-touchid rpc` and `gh-touchid mcp` exec into. It serves JSON-RPC (rpc) or MCP (mcp) on
// standard input and output and answers each call by running the core, gh-touchid, once with `--json --input -`. It is
// a separate program so that the core links no third-party code (this one uses the official MCP Swift SDK). It holds
// no secrets: it never reads the Keychain, never talks to gh-touchid's agent, and refuses operations whose input is a
// secret, which only the CLI's standard input may carry. The agent does not trust it; approvals still come only from
// the core's Touch ID.
//
//   gh-touchid-adapter rpc|mcp --core <absolute path of gh-touchid>

import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, ["rpc", "mcp"].contains(arguments[0]), arguments[1] == "--core",
      arguments[2].hasPrefix("/") else {
    writeStandardError("""
        usage: gh-touchid-adapter rpc|mcp --core <absolute path of gh-touchid>
        run it as `gh-touchid rpc` or `gh-touchid mcp`, which start it

        """)
    exit(2)
}
let mode = arguments[0]
let core = arguments[2]

// A client that goes away must not end the adapter mid-write; the write fails instead.
catchSignal(SIGPIPE)

let catalog: Catalog = {
    do {
        return try Catalog.load(core: core)
    } catch let failure as CallFailure {
        writeStandardError("gh-touchid-adapter: could not read gh-touchid's operations: \(failure.message)\n")
    } catch {
        writeStandardError("gh-touchid-adapter: could not read gh-touchid's operations: \(error)\n")
    }
    exit(1)
}()

if mode == "rpc" {
    runRPC(core: core, catalog: catalog)
} else {
    await runMCP(core: core, catalog: catalog)
}
