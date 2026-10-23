import Darwin
import Foundation
import Security

// A one-off HTTP server on 127.0.0.1 for the browser's trips back from GitHub: `app create`'s manifest page and the
// sign-in's callback. It answers one connection at a time and only `GET`s.

final class LocalServer {
    let port: Int
    private let listener: Int32

    /// Listens on 127.0.0.1:`port`.
    init(port: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ToolError.input("cannot create a socket")
        }
        // a run that just ended may leave the port in TIME_WAIT; another listener still makes bind fail
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 8) == 0
            }
        }
        guard listening else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw ToolError.input(
                "cannot listen on 127.0.0.1:\(port) (\(reason)); GitHub sends the browser back to that port, so "
                    + "whatever uses it must stop first"
            )
        }
        listener = fd
        self.port = port
    }

    deinit {
        close(listener)
    }

    /// Serves `pages` by path until the first request for one of `paths`, and returns that connection with its path
    /// and query; the caller answers it and closes it.
    func awaitRequest(
        for paths: Set<String>,
        pages: [String: String] = [:],
        deadline: Date
    ) throws -> (client: Int32, path: String, query: [String: String]) {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ToolError.refused("the browser did not come back from GitHub in time; nothing was stored")
            }
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(min(remaining, 60) * 1000)) > 0 else {
                continue
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                continue
            }
            configureSocket(client, timeoutSeconds: 10)
            guard let target = requestTarget(client), let components = URLComponents(string: target) else {
                respond(client, status: 400, text: "Bad request.")
                close(client)
                continue
            }
            if paths.contains(components.path) {
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] {
                    query[item.name] = item.value ?? ""
                }
                return (client, components.path, query)
            }
            if let page = pages[components.path] {
                respond(client, status: 200, html: page)
            } else {
                respond(client, status: 404, text: "Not found.")
            }
            close(client)
        }
    }

    /// The target of a `GET` request (`/callback?code=…`), from its request line.
    private func requestTarget(_ client: Int32) -> String? {
        var head = Data()
        var byte: UInt8 = 0
        let end = Data("\r\n\r\n".utf8)
        while head.count < 16384, !head.hasSuffix(end) {
            guard read(client, &byte, 1) == 1 else {
                return nil
            }
            head.append(byte)
        }
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else {
            return nil
        }
        return String(parts[1])
    }
}

func respond(_ client: Int32, status: Int, html: String) {
    let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
    let body = Data(html.utf8)
    let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
        + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        + "Connection: close\r\n\r\n"
    _ = writeAll(client, Data(head.utf8) + body)
}

func respond(_ client: Int32, status: Int, text: String) {
    respond(client, status: status, html: "<!doctype html><meta charset=\"utf-8\"><p>gh-touchid: \(htmlEscaped(text))</p>")
}

/// Sends the browser on to `location` (HTTP 302).
func redirect(_ client: Int32, to location: String) {
    let head = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nCache-Control: no-store\r\n"
        + "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
    _ = writeAll(client, Data(head.utf8))
}

func htmlEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func randomHex(bytes count: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        fatalError("no random bytes")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    func hasSuffix(_ suffix: Data) -> Bool {
        count >= suffix.count && self.suffix(suffix.count) == suffix
    }
}
