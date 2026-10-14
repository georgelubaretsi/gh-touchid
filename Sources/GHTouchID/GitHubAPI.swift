import Foundation

// Synchronous calls to the GitHub REST API; nothing is cached or stored.

struct APIResponse {
    let status: Int
    let body: Data
    let headers: [String: String]

    var object: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// GitHub's error message, for error reports.
    var message: String {
        if let message = object?["message"] as? String {
            return printable(message)
        }
        return printable(String(decoding: body.prefix(200), as: UTF8.self))
    }

    /// A response header; names are compared case-insensitively.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

/// One request to the GitHub API, with `bearer` as the credential when there is one.
func githubAPI(
    _ method: String,
    _ path: String,
    bearer: String?,
    body: [String: Any]? = nil
) throws -> APIResponse {
    guard let url = URL(string: try apiBaseURL() + path) else {
        throw ToolError.github("cannot build the API URL for \(path)")
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("gh-touchid", forHTTPHeaderField: "User-Agent")
    if let bearer {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let box = ResponseBox()
    let semaphore = DispatchSemaphore(value: 0)
    session.dataTask(with: request) { data, response, error in
        box.data = data
        box.response = response
        box.error = error
        semaphore.signal()
    }.resume()
    semaphore.wait()

    if let error = box.error {
        throw ToolError.github("cannot reach GitHub (\(method) \(path)): \(error.localizedDescription)")
    }
    guard let response = box.response as? HTTPURLResponse else {
        throw ToolError.github("GitHub sent no HTTP response to \(method) \(path)")
    }
    var headers: [String: String] = [:]
    for case let (name as String, value as String) in response.allHeaderFields {
        headers[name] = value
    }
    return APIResponse(status: response.statusCode, body: box.data ?? Data(), headers: headers)
}

/// The account a personal token belongs to (`GET /user`) and its classic scopes (`X-OAuth-Scopes`; fine-grained
/// tokens have none).
func tokenOwner(_ token: String) throws -> (login: String, scopes: String?) {
    let response = try githubAPI("GET", "/user", bearer: token)
    guard response.status == 200, let login = response.object?["login"] as? String else {
        throw ToolError.github("GitHub did not accept the token (HTTP \(response.status): \(response.message))")
    }
    return (login, response.header("X-OAuth-Scopes"))
}

/// Whether `repository` is private (`GET /repos/{owner}/{repo}` with a token that can read it).
func isPrivateRepository(_ repository: String, token: String) throws -> Bool {
    let response = try githubAPI("GET", "/repos/\(repository)", bearer: token)
    guard response.status == 200, let isPrivate = response.object?["private"] as? Bool else {
        throw ToolError.github(
            "cannot tell whether \(repository) is public (HTTP \(response.status): \(response.message))"
        )
    }
    return isPrivate
}
