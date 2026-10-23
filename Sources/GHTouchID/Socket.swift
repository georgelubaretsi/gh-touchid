import Darwin
import Foundation

// Agent and clients talk over a unix socket in the user's private directory, one newline-terminated JSON message
// each way per connection. Builds that share an agent (`sharesAgentSocket`) use `agent.sock`; every other build has
// an agent of its own, at a socket named after its executable's path. Each socket has a lock file beside it, held
// while an agent probes, binds or removes the socket, so that agents starting or stopping at once never remove a
// socket another one serves.

/// 64-bit FNV-1a of `text`'s UTF-8 bytes as 16 hex digits.
private func fnv1a(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

private let agentSocketName = sharesAgentSocket ? "agent" : "agent-\(fnv1a(ownExecutablePath ?? ""))"

let agentSocketPath = (sessionDirectory as NSString).appendingPathComponent("\(agentSocketName).sock")

let agentLockPath = (sessionDirectory as NSString).appendingPathComponent("\(agentSocketName).lock")

/// Runs `body` holding the agent's lock file (`flock`); nil when the lock file cannot be opened or locked.
func withAgentLock<T>(_ body: () throws -> T) rethrows -> T? {
    let fd = open(agentLockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
        return nil
    }
    defer { close(fd) } // closing it releases the lock
    while flock(fd, LOCK_EX) != 0 {
        guard errno == EINTR else {
            return nil
        }
    }
    return try body()
}

/// A file's identity, to tell the socket an agent bound from one bound later at the same path.
struct FileNode: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return nil
        }
        device = status.st_dev
        inode = status.st_ino
    }
}

func ensureSessionDirectory() throws {
    if mkdir(sessionDirectory, 0o700) != 0 && errno != EEXIST {
        throw ToolError.agent("cannot create \(sessionDirectory)")
    }
    var status = stat()
    guard lstat(sessionDirectory, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(),
          status.st_mode & 0o077 == 0 else {
        throw ToolError.agent("\(sessionDirectory) must be a private directory owned by you")
    }
}

func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw ToolError.agent("socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in bytes.enumerated() {
            raw[index] = byte
        }
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

func withSocketAddress<T>(
    _ address: inout sockaddr_un,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func configureSocket(_ fd: Int32, timeoutSeconds: Int) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else {
            return true
        }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base + offset, raw.count - offset)
            if written <= 0 {
                return false
            }
            offset += written
        }
        return true
    }
}

/// One newline-terminated message, at most 64 KiB.
func readMessage(_ fd: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 65536 {
        let count = read(fd, &byte, 1)
        if count <= 0 {
            return nil
        }
        if byte == 0x0A {
            return data
        }
        data.append(byte)
    }
    return nil
}

func sendMessage(_ fd: Int32, _ message: [String: Any]) -> Bool {
    guard let body = try? JSONSerialization.data(withJSONObject: message) else {
        return false
    }
    return writeAll(fd, body + Data([0x0A]))
}

/// A connection to the socket at `path`; nil when nothing accepts it.
func connectSocket(_ path: String, timeoutSeconds: Int) -> Int32? {
    guard var address = try? socketAddress(path) else {
        return nil
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return nil
    }
    configureSocket(fd, timeoutSeconds: timeoutSeconds)
    guard withSocketAddress(&address, { connect(fd, $0, $1) }) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// The program at the other end of a socket, as messages name it: `/path/to/program[pid]`.
func socketHolder(_ fd: Int32) -> String {
    guard let pid = peerProcess(fd) else {
        return "an unknown process"
    }
    return "\(executablePath(pid) ?? "?")[\(pid)]"
}

/// How one request to a socket went.
enum Exchange {
    /// Nothing accepted the connection.
    case absent
    /// A peer that `accepts` takes answered with `reply`.
    case answered([String: Any], PeerIdentity)
    /// The peer is not one `accepts` takes; its reply, if any, was ignored.
    case rejected(PeerIdentity, holder: String)
    /// A peer that `accepts` takes did not answer.
    case failed
}

/// One request to the socket at `path` and its reply, from a peer that `accepts` takes; nothing is sent before the
/// peer's identity is settled. A peer whose kernel cdhash decides who it is gets the request only if `accepts` takes
/// it. One that meets the newer-release requirement is a newer release only if the version it states is later: it is
/// asked for its status (which changes nothing) on this connection, and gets the request on a second one only if
/// that identity is accepted and the second connection reaches the very same process.
func exchange(_ path: String, _ request: [String: Any], accepts: (PeerIdentity) -> Bool) -> Exchange {
    guard let fd = connectSocket(path, timeoutSeconds: 5) else {
        return .absent
    }
    defer { close(fd) }
    switch examinePeer(fd) {
    case let .decided(peer):
        guard accepts(peer) else {
            return .rejected(peer, holder: socketHolder(fd))
        }
        return roundTrip(fd, request).map { .answered($0, peer) } ?? .failed
    case let .meetsRequirement(process):
        // only worth asking when a newer release is one `accepts` could take at all
        guard accepts(.newer(toolVersion)) else {
            let peer = PeerIdentity.untrusted("it meets the release requirement, which is not enough here")
            return .rejected(peer, holder: socketHolder(fd))
        }
        let asksStatus = request["op"] as? String == "status"
        let probe: [String: Any] = ["op": "status", "protocol": agentProtocol, "version": toolVersion]
        let status = roundTrip(fd, asksStatus ? request : probe)
        let peer = identity(of: .meetsRequirement(process), statedVersion: status?["version"])
        guard accepts(peer) else {
            return .rejected(peer, holder: socketHolder(fd))
        }
        if asksStatus, let status {
            return .answered(status, peer)
        }
        guard let second = connectSocket(path, timeoutSeconds: 5) else {
            return .failed
        }
        defer { close(second) }
        guard case let .meetsRequirement(again) = examinePeer(second), again == process else {
            return .failed
        }
        return roundTrip(second, request).map { .answered($0, peer) } ?? .failed
    }
}

/// `request` on `fd` and the reply; nil when there is none.
private func roundTrip(_ fd: Int32, _ request: [String: Any]) -> [String: Any]? {
    guard sendMessage(fd, request), let line = readMessage(fd) else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
}
