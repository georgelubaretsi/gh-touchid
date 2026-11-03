import Foundation

private let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

/// `owner/name` of the github.com `origin` of the Git repository in `folder` (by default the current one).
func repositoryIdentifier(in folder: String? = nil) throws -> String {
    let arguments = (folder.map { ["-C", $0] } ?? []) + ["remote", "get-url", "origin"]
    guard let remote = gitOutput(arguments), let repository = gitHubRepository(remote) else {
        throw ToolError.missingRepository
    }
    return repository
}

/// What `git <arguments>` prints, trimmed, when it succeeds; nil otherwise.
func gitOutput(_ arguments: [String]) -> String? {
    guard let result = runGit(arguments), result.status == 0,
          let text = String(data: result.output, encoding: .utf8) else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Runs `git <arguments>` and returns its exit status and standard output, or nil when Git cannot start or an argument
/// contains a NUL. Git's standard error is dropped unless `showErrors`.
func runGit(_ arguments: [String], showErrors: Bool = false) -> (status: Int32, output: Data)? {
    runReadingOutput(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, showErrors: showErrors)
}

/// `owner/name` from a github.com URL (`https://github.com/o/r.git`, `git@github.com:o/r`), or nil. Test builds also
/// take URLs on the mock API's host and port, where their Git remotes point.
private func gitHubRepository(_ remote: String) -> String? {
    if remote.hasPrefix("git@github.com:") {
        return validRepository(String(remote.dropFirst("git@github.com:".count)))
    }
    guard let url = URL(string: remote), url.scheme != nil else {
        return nil
    }
    if url.host?.lowercased() == "github.com" {
        return validRepository(url.path)
    }
#if GH_TOUCHID_TESTING
    if let base = try? apiBaseURL(), let mock = URL(string: base), url.host == mock.host, url.port == mock.port {
        return validRepository(url.path)
    }
#endif
    return nil
}

/// `owner/name` with a trailing `.git` and surrounding slashes removed, or nil when it is not one.
func validRepository(_ raw: String) -> String? {
    var repository = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if repository.hasSuffix(".git") {
        repository.removeLast(4)
    }

    let components = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2,
          components.allSatisfy({ !$0.isEmpty }),
          components.joined().unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else {
        return nil
    }
    return repository
}

/// A lowercase GitHub account name, or nil when `raw` is not one.
func validOwner(_ raw: String) -> String? {
    guard !raw.isEmpty, raw.count <= 100, raw.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else {
        return nil
    }
    return raw.lowercased()
}

/// The lowercase owner of `owner/name`: the account under which its App is stored.
func ownerAccount(_ repository: String) -> String {
    String(repository.split(separator: "/")[0]).lowercased()
}

func repositoryName(_ repository: String) -> String {
    String(repository.split(separator: "/")[1])
}

/// The repositories named by `--repo` options, or the current one when there are none.
func repositoriesOption(_ options: [String: [String]]) throws -> [String] {
    guard let values = options["--repo"] else {
        return [try repositoryIdentifier()]
    }
    var repositories: [String] = []
    for value in values {
        guard let repository = validRepository(value) else {
            throw ToolError.input("--repo takes owner/name")
        }
        if !repositories.contains(where: { $0.lowercased() == repository.lowercased() }) {
            repositories.append(repository)
        }
    }
    return repositories
}

/// The repository a gh command's token is for.
struct RequestedRepository {
    let name: String
    /// What to tell the caller when gh fails: set when `name` came from GH_REPO or the current folder although gh may
    /// act on a repository the command line names where gh-touchid does not read it.
    let hint: String?
}

/// The `gh repo` commands whose first argument is the repository they act on, `OWNER/REPO`, `HOST/OWNER/REPO` or a
/// URL; they take no `-R`, and gh ignores GH_REPO for them. Not `set-default`: its argument picks one of the current
/// folder's remotes, which it looks up through the API.
private let repositoryArgumentCommands: Set<[String]> = [
    ["repo", "archive"], ["repo", "clone"], ["repo", "delete"], ["repo", "edit"], ["repo", "fork"], ["repo", "sync"],
    ["repo", "unarchive"], ["repo", "view"],
]

/// The repository a gh command is for: `-R`/`--repo`; else for `gh api` the repository its endpoint names, and for
/// `gh repo view` and the like their repository argument; else GH_REPO; else the current repository. Its flags are read
/// as gh reads them, with the command's own definitions.
func requestedRepository(_ command: GitHubCommandLine) throws -> RequestedRepository {
    if let selector = try repositorySelector(command.rest, flags: command.flags) {
        return RequestedRepository(name: try repositorySpecification(selector), hint: nil)
    }
    // why gh may act on another repository than the one taken below, said if gh fails
    var unread: String?
    if command.path == ["api"] {
        let call = APICall(command)
        if let repository = apiEndpointRepository(call) {
            return RequestedRepository(name: repository, hint: nil)
        }
        // gh fills placeholders from GH_REPO and the current folder too
        if let endpoint = call.endpoint, !apiPlaceholders.contains(where: endpoint.lowercased().contains) {
            unread = "gh-touchid reads no repository from a GraphQL query or an endpoint outside repos/OWNER/REPO; "
                + "for another, set GH_REPO=OWNER/REPO"
        }
    } else if repositoryArgumentCommands.contains(command.path), let argument = firstPositional(command) {
        // gh completes a name without `/` (`clone`: nor `:`) with your login, which gh-touchid cannot know beforehand
        if argument.contains("/") || argument.contains(":") {
            return RequestedRepository(name: try repositorySpecification(argument), hint: nil)
        }
        unread = "the repository given to \(command.name) has no owner; write it as OWNER/REPO"
    }
    let name: String
    let source: String
    if let repository = ProcessInfo.processInfo.environment["GH_REPO"], !repository.isEmpty {
        name = try repositorySpecification(repository)
        source = "from GH_REPO"
    } else {
        name = try repositoryIdentifier()
        source = "the current folder's repository"
    }
    let hint = unread.map { "gh failed with a token for \(name) only, \(source): \($0)" }
    return RequestedRepository(name: name, hint: hint)
}

/// The first argument of a gh command that is not a flag or a flag's value, after `--` too, as gh passes it on.
private func firstPositional(_ command: GitHubCommandLine) -> String? {
    for case let .positional(value) in parsedArguments(command.rest, flags: command.flags) {
        return value
    }
    return nil
}

/// gh's repository syntax: `OWNER/REPO`, `HOST/OWNER/REPO` or a URL; the host must be github.com.
private func repositorySpecification(_ raw: String) throws -> String {
    if raw.contains(":") {
        if let repository = gitHubRepository(raw) {
            return repository
        }
    } else {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let repository = validRepository(raw) {
            return repository
        }
        if parts.count == 3, parts[0].lowercased() == "github.com",
           let repository = validRepository(parts[1...].joined(separator: "/")) {
            return repository
        }
    }
    throw ToolError.input("\(raw) is not a github.com repository (OWNER/REPO, HOST/OWNER/REPO or a github.com URL)")
}

/// For `gh api <endpoint>`: `OWNER/REPO` when the endpoint is `repos/OWNER/REPO[/…]`, with or without a leading slash
/// or as a full URL of the API, and names them without `{owner}`/`{repo}` placeholders; nil otherwise, as for
/// `graphql` or `user`, which gh resolves (or needs no repository for) on its own.
private func apiEndpointRepository(_ call: APICall) -> String? {
    guard var path = call.endpoint, !path.contains("{") else {
        return nil
    }
    if path.contains("://") {
        guard let url = URLComponents(string: path), let base = try? apiBaseURL(),
              let api = URLComponents(string: base), url.host?.lowercased() == api.host?.lowercased() else {
            return nil
        }
        path = url.path
    }
    if let query = path.firstIndex(of: "?") {
        path = String(path[..<query])
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 3, parts[0] == "repos" else {
        return nil
    }
    return validRepository("\(parts[1])/\(parts[2])")
}
