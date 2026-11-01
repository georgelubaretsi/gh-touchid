import Darwin
import Foundation

// The calls of the core still running, so that the adapter never leaves one behind: a client that cancels ends its
// call, and a client that goes away or a signal to the adapter ends them all before the adapter exits.

/// The running calls, by a key unique while they run (a JSON-RPC id, or a UUID).
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: CoreCall] = [:]
    private let group = DispatchGroup()

    /// Adds `call` under `key`; false when a call runs under that key already.
    func add(_ call: CoreCall, key: String) -> Bool {
        lock.withLock {
            guard running[key] == nil else {
                return false
            }
            running[key] = call
            group.enter()
            return true
        }
    }

    /// Removes the call under `key`, once it has ended.
    func remove(_ key: String) {
        lock.withLock {
            if running.removeValue(forKey: key) != nil {
                group.leave()
            }
        }
    }

    /// Cancels the call under `key`, if one runs.
    func cancel(_ key: String) {
        lock.withLock { running[key] }?.cancel()
    }

    /// Waits until no call runs.
    func waitForAll() {
        group.wait()
    }

    /// Cancels every call (SIGTERM to each core) and waits up to 6 seconds for them to end; a core still revoking a
    /// token then finishes on its own after the adapter exits.
    func endAll() {
        lock.withLock { Array(running.values) }.forEach { $0.cancel() }
        _ = group.wait(timeout: .now() + 6)
    }
}

/// Ends every running call, then the adapter, on SIGTERM, SIGINT or SIGHUP, with the status a shell gives a process
/// ended by that signal.
func endCallsOnSignals(_ calls: Calls) {
    for number in [SIGTERM, SIGINT, SIGHUP] {
        catchSignal(number)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            calls.endAll()
            exit(128 + number)
        }
        source.resume()
        signalSources.append(source)
    }
}

/// Catches `number` with a handler that does nothing, so that it no longer ends the adapter (a dispatch source or an
/// error return takes over) while the core, whose exec resets caught signals, still gets the default; SIG_IGN would be
/// inherited by the core and by gh.
func catchSignal(_ number: Int32) {
    _ = signal(number) { _ in }
}

/// The signal sources, kept alive for the life of the adapter.
private var signalSources: [DispatchSourceSignal] = []
