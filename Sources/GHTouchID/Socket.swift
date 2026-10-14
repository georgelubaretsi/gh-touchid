import Darwin
import Foundation

// Daemon and clients talk over a unix socket in the user's private directory, one newline-terminated JSON message
// each way per connection. The socket is named after the executable's path, so every build has its own daemon.

/// 64-bit FNV-1a of `text`'s UTF-8 bytes as 16 hex digits.
private func fnv1a(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

let agentSocketPath = (sessionDirectory as NSString)
    .appendingPathComponent("agent-\(fnv1a(ownExecutablePath ?? "")).sock")

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

/// Ask this build's daemon; nil when none answers. A socket served by anything other than this very executable,
/// running as this user, is not trusted.
func agentRequest(_ request: [String: Any]) -> [String: Any]? {
    guard let ownPath = ownExecutablePath,
          var address = try? socketAddress(agentSocketPath) else {
        return nil
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return nil
    }
    defer { close(fd) }
    configureSocket(fd, timeoutSeconds: 5)
    guard withSocketAddress(&address, { connect(fd, $0, $1) }) == 0 else {
        return nil
    }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
          let peer = peerProcess(fd), executablePath(peer) == ownPath,
          sendMessage(fd, request),
          let line = readMessage(fd),
          let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        return nil
    }
    return reply
}
