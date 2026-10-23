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

/// Runs `git <arguments>` and returns its exit status and standard output, or nil when Git cannot start. Git's
/// standard error is dropped unless `showErrors`.
func runGit(_ arguments: [String], showErrors: Bool = false) -> (status: Int32, output: Data)? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.standardOutput = output
    process.standardError = showErrors ? FileHandle.standardError : FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
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

/// The repository a `gh` command is for: `-R`/`--repo`, else for `gh api` the repository its endpoint names, else
/// GH_REPO, else the current repository. gh's flag definitions are read only when a flag before the selector may take
/// it as its value; when they cannot be read, only `-R`/`--repo` is known to take a value (a wrong guess only yields a
/// token gh cannot use). With `exact`, for a token not limited to one repository (an account's), it refuses instead of
/// guessing.
func requestedRepository(_ arguments: [String], exact: Bool) throws -> String {
    var flags = CommandFlags()
    if repositorySelectorIsAmbiguous(arguments) {
        if let known = gitHubCommandFlags(arguments) {
            flags = known
        } else if exact {
            throw ToolError.refused(
                "cannot tell which repository this command acts on: gh help reference does not settle "
                    + "whether a flag takes the -R/--repo after it"
            )
        }
    }
    if let selector = try repositorySelector(arguments, flags: flags) {
        return try repositorySpecification(selector)
    }
    if let repository = apiEndpointRepository(arguments) {
        return repository
    }
    if let repository = ProcessInfo.processInfo.environment["GH_REPO"], !repository.isEmpty {
        return try repositorySpecification(repository)
    }
    return try repositoryIdentifier()
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

/// `gh api`'s flags that take a value (gh 2.x: `-X`, `-H`, `-F`, `-f`, `--input`, `-q`, `-t`, `--hostname`, `--cache`,
/// `-p`); the others are switches.
private let apiValueFlags: (long: Set<String>, short: Set<Character>) = (
    ["method", "header", "field", "raw-field", "input", "jq", "template", "hostname", "cache", "preview"],
    ["X", "H", "F", "f", "q", "t", "p"]
)

/// For `gh api <endpoint>`: `OWNER/REPO` when the endpoint is `repos/OWNER/REPO[/…]`, with or without a leading slash
/// or as a full URL of the API, and names them without `{owner}`/`{repo}` placeholders; nil otherwise, as for
/// `graphql` or `user`, which gh resolves (or needs no repository for) on its own.
func apiEndpointRepository(_ arguments: [String]) -> String? {
    guard arguments.first == "api" else {
        return nil
    }
    var endpoint: String?
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            endpoint = index + 1 < arguments.count ? arguments[index + 1] : nil
            break
        }
        if argument.hasPrefix("--") {
            let name = String(argument.dropFirst(2).prefix { $0 != "=" })
            index += !argument.contains("=") && apiValueFlags.long.contains(name) ? 2 : 1
        } else if argument.count > 1, argument.hasPrefix("-") {
            // a group such as `-iH`: its first flag that takes a value takes the rest of the group, or else the next
            // argument
            var group = argument.dropFirst()
            var takesNext = false
            while let shorthand = group.first {
                group = group.dropFirst()
                if apiValueFlags.short.contains(shorthand) {
                    takesNext = group.isEmpty
                    break
                }
            }
            index += takesNext ? 2 : 1
        } else {
            endpoint = argument
            break
        }
    }
    guard var path = endpoint, !path.contains("{") else {
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
