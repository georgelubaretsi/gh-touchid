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

/// `owner/name` from a github.com URL (`https://github.com/o/r.git`, `git@github.com:o/r`), or nil.
private func gitHubRepository(_ remote: String) -> String? {
    if remote.hasPrefix("git@github.com:") {
        return validRepository(String(remote.dropFirst("git@github.com:".count)))
    }
    if let url = URL(string: remote), url.scheme != nil, url.host?.lowercased() == "github.com" {
        return validRepository(url.path)
    }
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

/// The repository a `gh` command is for: `-R`/`--repo`, else GH_REPO, else the current repository. gh's flag
/// definitions are read only when a flag before the selector may take it as its value; when they cannot be read, only
/// `-R`/`--repo` is known to take a value (a wrong guess only yields a token gh cannot use). With `exact`, for a token
/// not limited to one repository (an account's), it refuses instead of guessing.
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
