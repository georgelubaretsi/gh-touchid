import Foundation

// Words for Touch ID dialogs, which macOS shows as "gh-touchid is trying to <reason>." They name the program that
// asked, the command and the repositories in plain words; the full process chain goes to the access log instead.

/// Processes that only pass a request along: shells, Git, gh, gh-touchid and launchers.
private let plumbingNames: Set<String> = shellNames.union([
    "fish", "git", "git-remote-http", "git-remote-https", "gh", "gh-touchid", "gh-touchid-test",
    "env", "nix", "xargs", "timeout", "nohup", "time", "sudo", "script",
])

/// The program that asked: the nearest ancestor that is not plumbing, e.g. `omp` for
/// `git-remote-https < git < git < omp`.
func requester() -> String {
    for pid in lineage(getppid()) {
        let name = processName(pid)
        if !plumbingNames.contains(name), !name.hasPrefix("git-") {
            return printable(name)
        }
    }
    return "a program"
}

/// `git push`, `git clone`: the Git command a credential request comes from, read from the outermost `git` above
/// the transport that asked; `git` when it cannot be told.
func gitAction() -> String {
    var outermost: pid_t?
    for pid in lineage(getppid()) {
        let name = processName(pid)
        if name == "git" {
            outermost = pid
        } else if !name.hasPrefix("git-") {
            break
        }
    }
    guard let pid = outermost, let arguments = processArguments(pid) else {
        return "git"
    }
    let valued: Set<String> = ["-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"]
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if valued.contains(argument) {
            index += 2
        } else if argument.hasPrefix("-") {
            index += 1
        } else {
            return "git \(printable(argument))"
        }
    }
    return "git"
}

/// `gh pr list`, `gh api repos/o/r/pulls`: gh and its first two words that are not flags (a leading
/// `-R owner/name` is skipped with its value), at most 60 characters.
func ghAction(_ arguments: [String]) -> String {
    var words: [String] = []
    var index = 0
    while index < arguments.count, words.count < 2 {
        let argument = arguments[index]
        if argument == "-R" || argument == "--repo" {
            index += 2
            continue
        }
        if argument == "--" {
            break
        }
        if !argument.hasPrefix("-") {
            words.append(argument)
        } else if !words.isEmpty {
            break // flags after the command: its own options, not more of its name
        }
        index += 1
    }
    let text = (["gh"] + words).joined(separator: " ")
    let shown = text.count > 60 ? String(text.prefix(59)) + "…" : text
    return printable(shown)
}

/// `acme/one, two and three`: the owner once when all share it, at most three names.
func repositoryWords(_ repositories: [String]) -> String {
    let owners = Set(repositories.map(ownerAccount))
    var names = repositories
    if owners.count == 1, let owner = owners.first, repositories.count > 1 {
        names = repositories.map(repositoryName)
        names[0] = "\(owner)/\(names[0])"
    }
    if names.count > 3 {
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
    if names.count <= 1 {
        return names.first ?? "no repository"
    }
    return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
}

/// `15 minutes`, `1 hour 30 minutes`, `1 day`.
func durationWords(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    let parts = [(minutes / 1440, "day"), (minutes % 1440 / 60, "hour"), (minutes % 60, "minute")]
    return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " ")
}
