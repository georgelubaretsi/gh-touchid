import Darwin
import Foundation

// Where gh-touchid keeps its runtime state and which GitHub it talks to. Test builds (`-D GH_TOUCHID_TESTING`) keep
// everything under GH_TOUCHID_TEST_DIR and talk to the mock API at GH_TOUCHID_API_URL; production builds never read
// either variable.

#if GH_TOUCHID_TESTING
let testDirectory: String = {
    guard let directory = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_DIR"], directory.hasPrefix("/") else {
        fputs("gh-touchid: test builds need GH_TOUCHID_TEST_DIR (an absolute path)\n", stderr)
        exit(1)
    }
    return directory
}()
#endif

/// The user's own temporary directory from the system, not $TMPDIR, which development shells change.
let sessionDirectory: String = {
#if GH_TOUCHID_TESTING
    return (testDirectory as NSString).appendingPathComponent("run")
#else
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let base = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    return (base as NSString).appendingPathComponent("gh-touchid")
#endif
}()

let accessLogPath: String = {
#if GH_TOUCHID_TESTING
    return (testDirectory as NSString).appendingPathComponent("access.log")
#else
    return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/gh-touchid/access.log")
#endif
}()

/// GitHub's REST API, without a trailing slash.
func apiBaseURL() throws -> String {
#if GH_TOUCHID_TESTING
    guard let url = ProcessInfo.processInfo.environment["GH_TOUCHID_API_URL"], !url.isEmpty else {
        throw ToolError.input("test builds need GH_TOUCHID_API_URL")
    }
    return url.hasSuffix("/") ? String(url.dropLast()) : url
#else
    return "https://api.github.com"
#endif
}

/// GitHub's web pages, without a trailing slash (in test builds: the mock API, which plays them too).
func webBaseURL() throws -> String {
#if GH_TOUCHID_TESTING
    return try apiBaseURL()
#else
    return "https://github.com"
#endif
}

/// The port of the local page GitHub sends the browser back to after you authorize an App. It is fixed because GitHub
/// matches an App's callback URLs exactly, port included (test builds: GH_TOUCHID_TEST_CALLBACK_PORT when set).
let callbackPort: Int = {
#if GH_TOUCHID_TESTING
    if let port = ProcessInfo.processInfo.environment["GH_TOUCHID_TEST_CALLBACK_PORT"].flatMap(Int.init),
       (1 ... 65535).contains(port) {
        return port
    }
#endif
    return 47911
}()

/// The callback URL every App of gh-touchid lists, and the one the sign-in asks GitHub to send the browser back to.
let callbackURL = "http://127.0.0.1:\(callbackPort)/callback"

/// Opens `url` in the default browser; test builds print `OPEN: <url>` instead.
func openInBrowser(_ url: String) {
#if GH_TOUCHID_TESTING
    fputs("OPEN: \(url)\n", stderr)
#else
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    guard (try? process.run()) != nil else {
        return
    }
    process.waitUntilExit()
#endif
}

/// Whether Git asks for a github.com credential over HTTPS (in test builds: for the mock API's own host).
func isGitHubCredentialRequest(protocol scheme: String?, host: String?) -> Bool {
#if GH_TOUCHID_TESTING
    guard let base = try? apiBaseURL(),
          let components = URLComponents(string: base),
          let mockHost = components.host else {
        return false
    }
    let authority = components.port.map { "\(mockHost):\($0)" } ?? mockHost
    return scheme == components.scheme && host == authority
#else
    return scheme == "https" && host?.lowercased() == "github.com"
#endif
}

func appendAccessLog(_ message: String) {
    let directory = (accessLogPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let stamp = ISO8601DateFormatter.string(
        from: Date(),
        timeZone: .current,
        formatOptions: [.withInternetDateTime]
    )
    let fd = open(accessLogPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else {
        return
    }
    defer { close(fd) }
    _ = writeAll(fd, Data("\(stamp) \(message)\n".utf8))
}
