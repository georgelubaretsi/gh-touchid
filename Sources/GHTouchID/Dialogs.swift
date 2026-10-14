import Foundation

// Words for Touch ID dialogs. They name the program that asked, the command and the repositories in plain words; the
// full process chain goes to the access log instead.

/// What a Touch ID dialog asks. The approval window shows the title (a question), the message (one short sentence)
/// and the rows; `fallback` is for macOS's own sheet, "gh-touchid is trying to <fallback>.", where no window can be
/// shown, and for the test build's `AUTH:` line.
struct Prompt {
    struct Row {
        /// An SF Symbol.
        let symbol: String
        let text: String
        var monospaced = false
        /// What VoiceOver says before the text, when the text alone does not say what it is.
        var label: String?
    }

    let title: String
    let message: String
    var rows: [Row] = []
    let fallback: String
}

extension Prompt {
    /// One use of an App token outside any session.
    static func appUse(by who: String, command: String, repository: String) -> Prompt {
        Prompt(
            title: "Allow \(who) to \(repositoryVerb(command)) \(repository)?",
            message: "As your \(ownerAccount(repository)) bot, for this command only.",
            rows: [Row(symbol: "terminal", text: command, monospaced: true, label: "Command")],
            fallback: "let \(who) run “\(command)” on \(repository)"
        )
    }

    /// The first use of a pending session.
    static func session(program: String, repositories: [String], folder: String, started: Date) -> Prompt {
        let repositories = repositoryWords(repositories)
        let folder = displayFolder(folder)
        let started = clockTime(started)
        return Prompt(
            title: "Allow \(program) to work on \(repositories)?",
            message: "Until it quits. It can also open issues in your other repositories.",
            rows: [
                Row(symbol: "folder", text: folder, label: "Folder"),
                Row(symbol: "clock", text: "Started at \(started)"),
            ],
            fallback: "let \(program) use \(repositories) until it quits, "
                + "and open issues in your other repos (started \(started) in \(folder))"
        )
    }

    /// A use of an issue-only token for a public repository outside the session.
    static func publicIssue(program: String, command: String, repository: String) -> Prompt {
        Prompt(
            title: "Allow \(program) to post in \(repository)?",
            message: "This repository is public: anyone can see what it posts.",
            rows: [Row(symbol: "terminal", text: command, monospaced: true, label: "Command")],
            fallback: "let \(program) run “\(command)” on public \(repository)"
        )
    }

    /// `elevate`: tokens for the repositories include workflows for a while.
    static func elevation(repositories: [String], seconds: TimeInterval) -> Prompt {
        let names = repositoryWords(repositories)
        let secrets = repositories.count == 1 ? "your repository’s secrets" : "your repositories’ secrets"
        return Prompt(
            title: "Allow your agents to change workflows in \(names)?",
            message: "For \(durationWords(seconds)). Workflows can use \(secrets).",
            fallback: "let your agents change workflows in \(names) for \(durationWords(seconds))"
        )
    }

    /// One use of an account's own token; `repository` is nil for commands outside one, such as `gh api user`.
    static func acting(as account: String, by who: String, command: String, repository: String?) -> Prompt {
        var rows = [Row(symbol: "terminal", text: command, monospaced: true, label: "Command")]
        if let repository {
            rows.append(Row(symbol: "book.closed", text: repository, label: "Repository"))
        }
        return Prompt(
            title: "Allow \(who) to act as \(account)?",
            message: "With \(account)’s own token, for this command only.",
            rows: rows,
            fallback: "let \(who) act as \(account): “\(command)”\(repository.map { " on \($0)" } ?? "")"
        )
    }

    /// `app create`: the App GitHub just made.
    static func newApp(_ slug: String, owner: String) -> Prompt {
        Prompt(
            title: "Store the GitHub App \(slug) for \(owner)?",
            message: "Agents will act as this App on \(owner)’s repositories.",
            fallback: "store the new GitHub App \(slug) for \(owner)"
        )
    }

    /// `app set`: asked before GitHub is, so the App's name is not known yet.
    static func appKey(owner: String) -> Prompt {
        Prompt(
            title: "Store a GitHub App for \(owner)?",
            message: "Agents will act as this App on \(owner)’s repositories.",
            fallback: "store the GitHub App key for \(owner)"
        )
    }

    /// `user add`.
    static func accountToken(_ login: String) -> Prompt {
        Prompt(
            title: "Store \(login)’s GitHub token?",
            message: "Every use will ask for Touch ID.",
            fallback: "store a GitHub token for \(login)"
        )
    }
}

/// "push to", "clone", "read": what a command (`git push`, `gh pr create`) does to a repository; "use" when it cannot
/// be told.
func repositoryVerb(_ command: String) -> String {
    switch command {
    case "git push":
        return "push to"
    case "git clone":
        return "clone"
    case "git fetch", "git pull", "git ls-remote":
        return "read"
    case "gh pr create":
        return "open a pull request in"
    case "gh pr merge":
        return "merge a pull request in"
    case "gh issue create":
        return "open an issue in"
    default:
        return "use"
    }
}

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
