import Foundation

// Words for Touch ID dialogs. They show what gh-touchid can see itself: the program that asked and its folder, the
// command and its arguments, Git, the repositories and the App; the full process chain goes to the access log.

/// What a Touch ID dialog asks. The approval window shows the rows (`action`, `repo`, …, `scope`) and Touch ID with
/// `allowLabel`; `fallback` is for macOS's own sheet, "gh-touchid is trying to <fallback>.", where no window can be
/// shown, and for the test build's `AUTH:` line.
struct Prompt {
    enum Emphasis {
        case normal
        /// What is asked for and of what: semibold.
        case strong
        /// Scopes and risks: orange.
        case warning
    }

    struct Row {
        /// Lowercase, e.g. `repo`.
        let key: String
        /// One line or several.
        let value: String
        var emphasis = Emphasis.normal
    }

    let rows: [Row]
    /// The words beside Touch ID: `allow once`.
    let allowLabel: String
    let fallback: String
}

/// The program that asked and the folder it runs in.
struct Requester {
    let name: String
    let folder: String?

    /// `agent · ~/code/widget`.
    var from: String {
        folder.map { "\(name) · \(displayFolder($0))" } ?? name
    }
}

/// What a command asks a token for, as far as gh-touchid can tell from its arguments and Git.
struct Use {
    /// `git push`, `gh pr create`: the command in dialog words.
    let command: String
    /// gh only: the command and the rest of its arguments, at most 60 characters.
    var commandLine: String?
    /// git push only: where it pushes, e.g. `fix-login` or `delete old-branch`.
    var branch: String?
    /// gh only: `--title` of a pull request or issue.
    var title: String?
    /// gh only: the first lines of `--body`, or `from <file>` for `--body-file`.
    var body: String?
}

extension Prompt {
    /// One use of an App token outside any session; `app` is the App's slug when it is known.
    static func appUse(by requester: Requester, use: Use, repository: String, app: String?) -> Prompt {
        var rows = [
            Row(key: "action", value: actionWords(use.command), emphasis: .strong),
            Row(key: "repo", value: repository, emphasis: .strong),
        ]
        if use.command == "git push", let branch = use.branch {
            rows.append(Row(key: "branch", value: branch))
        }
        if ["gh pr create", "gh issue create"].contains(use.command), let title = use.title {
            rows.append(Row(key: "title", value: title))
        }
        if let commandLine = use.commandLine {
            rows.append(Row(key: "command", value: commandLine))
        }
        rows += [
            Row(key: "from", value: requester.from),
            Row(key: "as", value: botWords(app, owner: ownerAccount(repository))),
            Row(key: "scope", value: "once", emphasis: .warning),
        ]
        return Prompt(
            rows: rows,
            allowLabel: "allow once",
            fallback: "let \(requester.name) run “\(use.command)” on \(repository)"
        )
    }

    /// The first use of a pending session.
    static func session(program: String, repositories: [String], folder: String, started: Date) -> Prompt {
        let names = repositoryWords(repositories)
        let shownFolder = displayFolder(folder)
        let time = clockTime(started)
        return Prompt(
            rows: [
                Row(key: "action", value: "use github", emphasis: .strong),
                Row(key: "repos", value: repositoryLines(repositories), emphasis: .strong),
                Row(key: "also", value: "open issues in your other repos"),
                Row(key: "from", value: Requester(name: program, folder: folder).from),
                Row(key: "started", value: time),
                Row(key: "scope", value: "until \(program) quits", emphasis: .warning),
            ],
            allowLabel: "allow until \(program) quits",
            fallback: "let \(program) use \(names) until it quits, "
                + "and open issues in your other repos (started \(time) in \(shownFolder))"
        )
    }

    /// A use of an issue-only token for a public repository outside the session, by the session's program.
    static func publicIssue(by requester: Requester, use: Use, repository: String, app: String?) -> Prompt {
        var rows = [
            Row(key: "action", value: issueActionWords(use.command), emphasis: .strong),
            Row(key: "repo", value: repository, emphasis: .strong),
            Row(key: "visibility", value: "public, anyone can read it", emphasis: .warning),
        ]
        if let title = use.title {
            rows.append(Row(key: "title", value: title))
        }
        if let body = use.body {
            rows.append(Row(key: "body", value: body))
        }
        rows += [
            Row(key: "from", value: requester.from),
            Row(key: "as", value: botWords(app, owner: ownerAccount(repository))),
            Row(key: "scope", value: "once", emphasis: .warning),
        ]
        return Prompt(
            rows: rows,
            allowLabel: "allow once",
            fallback: "let \(requester.name) run “\(use.command)” on public \(repository)"
        )
    }

    /// `elevate`: tokens for the repositories include workflows for a while.
    static func elevation(repositories: [String], seconds: TimeInterval, by requester: Requester) -> Prompt {
        let duration = durationWords(seconds)
        return Prompt(
            rows: [
                Row(key: "action", value: "change workflows", emphasis: .strong),
                Row(key: "repos", value: repositoryLines(repositories), emphasis: .strong),
                Row(key: "risk", value: "workflows can read secrets", emphasis: .warning),
                Row(key: "from", value: requester.from),
                Row(key: "scope", value: duration, emphasis: .warning),
            ],
            allowLabel: "allow for \(duration)",
            fallback: "let your agents change workflows in \(repositoryWords(repositories)) for \(duration)"
        )
    }

    /// One use of an account's own token; `repository` is nil for commands outside one, such as `gh api user`.
    static func acting(as account: String, by requester: Requester, use: Use, repository: String?) -> Prompt {
        var rows = [Row(key: "action", value: actionWords(use.command), emphasis: .strong)]
        if let repository {
            rows.append(Row(key: "repo", value: repository, emphasis: .strong))
        }
        rows.append(Row(key: "as", value: "\(account) (your account)", emphasis: .strong))
        if let commandLine = use.commandLine {
            rows.append(Row(key: "command", value: commandLine))
        }
        rows += [
            Row(key: "from", value: requester.from),
            Row(key: "scope", value: "once", emphasis: .warning),
        ]
        return Prompt(
            rows: rows,
            allowLabel: "allow once",
            fallback: "let \(requester.name) act as \(account): “\(use.command)”\(repository.map { " on \($0)" } ?? "")"
        )
    }

    /// `app create`: the App GitHub just made.
    static func newApp(_ slug: String, owner: String) -> Prompt {
        Prompt(
            rows: [
                Row(key: "action", value: "store app key", emphasis: .strong),
                Row(key: "owner", value: owner, emphasis: .strong),
                Row(key: "app", value: slug),
                Row(key: "scope", value: "until removed", emphasis: .warning),
            ],
            allowLabel: "allow",
            fallback: "store the new GitHub App \(slug) for \(owner)"
        )
    }

    /// `app set`: asked before GitHub is, so the App's name is not known yet.
    static func appKey(owner: String) -> Prompt {
        Prompt(
            rows: [
                Row(key: "action", value: "store app key", emphasis: .strong),
                Row(key: "owner", value: owner, emphasis: .strong),
                Row(key: "scope", value: "until removed", emphasis: .warning),
            ],
            allowLabel: "allow",
            fallback: "store the GitHub App key for \(owner)"
        )
    }

    /// `user add`.
    static func accountToken(_ login: String) -> Prompt {
        Prompt(
            rows: [
                Row(key: "action", value: "store token", emphasis: .strong),
                Row(key: "account", value: login, emphasis: .strong),
                Row(key: "scope", value: "until removed", emphasis: .warning),
            ],
            allowLabel: "allow",
            fallback: "store a GitHub token for \(login)"
        )
    }
}

/// `push`, `open pull request`, `run view`: what a command (`git push`, `gh pr create`, `gh run view`) does, in the
/// window's words; otherwise its words without `git` or `gh`.
func actionWords(_ command: String) -> String {
    switch command {
    case "git push":
        return "push"
    case "git clone":
        return "clone"
    case "git fetch", "git pull", "git ls-remote":
        return "read"
    case "gh pr create":
        return "open pull request"
    case "gh pr merge":
        return "merge pull request"
    case "gh issue create":
        return "open issue"
    case "gh issue comment", "gh pr comment":
        return "comment"
    default:
        let words = command.split(separator: " ", maxSplits: 1)
        return words.count == 2 ? String(words[1]) : command
    }
}

/// What a command does with an issue-only token: `open issue`, `comment on issue`, or `use issues`.
private func issueActionWords(_ command: String) -> String {
    switch command {
    case "gh issue create":
        return "open issue"
    case "gh issue comment":
        return "comment on issue"
    case "gh pr comment":
        return "comment on pull request"
    default:
        return "use issues"
    }
}

/// `acme-agent (bot)`, or `acme's app (bot)` when the App's slug is not stored.
private func botWords(_ slug: String?, owner: String) -> String {
    "\(slug ?? "\(owner)'s app") (bot)"
}

/// One repository per line, the owner only on the first when all share it; every repository is listed.
private func repositoryLines(_ repositories: [String]) -> String {
    let owners = Set(repositories.map(ownerAccount))
    var lines = repositories
    if owners.count == 1, repositories.count > 1 {
        lines = [repositories[0]] + repositories.dropFirst().map(repositoryName)
    }
    return lines.joined(separator: "\n")
}

/// Processes that only pass a request along: shells, Git, gh, gh-touchid and launchers.
private let plumbingNames: Set<String> = shellNames.union([
    "fish", "git", "git-remote-http", "git-remote-https", "gh", "gh-touchid", "gh-touchid-test",
    "env", "nix", "xargs", "timeout", "nohup", "time", "sudo", "script",
])

/// The program that asked, and its folder: the nearest ancestor that is not plumbing, e.g. `agent` for
/// `git-remote-https < git < git < agent`.
func requester() -> Requester {
    for pid in lineage(getppid()) {
        let name = processName(pid)
        if !plumbingNames.contains(name), !name.hasPrefix("git-") {
            return Requester(name: printable(name), folder: processFolder(pid))
        }
    }
    return Requester(name: "a program", folder: nil)
}

/// The Git command a credential request comes from (`git push`, `git clone`; `git` when it cannot be told) and, for
/// `git push`, where it pushes; read from the outermost `git` above the transport that asked.
func gitUse() -> Use {
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
        return Use(command: "git")
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
            let command = "git \(printable(argument))"
            guard argument == "push" else {
                return Use(command: command)
            }
            let folder = processFolder(pid)
            return Use(command: command, branch: pushDestination(Array(arguments[(index + 1)...]), folder: folder))
        }
    }
    return Use(command: "git")
}

/// Where `git push <arguments>` pushes: the destinations of its refspecs (`fix-login` for `fix-login`,
/// `HEAD:fix-login` or `+main:fix-login`; `delete x` for `--delete x` or `:x`), or without one the current branch of
/// the repository in `folder`; nil when it cannot be told, as for `--all`.
private func pushDestination(_ arguments: [String], folder: String?) -> String? {
    let valued: Set<String> = ["--repo", "-o", "--push-option", "--receive-pack", "--exec"]
    var deleting = false
    var positional: [String] = []
    var index = 0
    var endOfOptions = false
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        if endOfOptions || !argument.hasPrefix("-") || argument == "-" {
            positional.append(argument)
        } else if argument == "--" {
            endOfOptions = true
        } else if valued.contains(argument) {
            index += 1
        } else if argument == "--delete" || argument == "-d" {
            deleting = true
        } else if ["--all", "--branches", "--mirror", "--tags"].contains(argument) {
            return nil
        }
    }
    let refspecs = positional.dropFirst() // the first is the remote
    func current() -> String? {
        folder.flatMap { gitOutput(["-C", $0, "symbolic-ref", "--short", "-q", "HEAD"]) }
    }
    guard !refspecs.isEmpty else {
        return deleting ? nil : current().map { printable($0) }
    }
    var destinations: [String] = []
    for refspec in refspecs {
        var spec = Substring(refspec)
        if spec.hasPrefix("+") {
            spec = spec.dropFirst()
        }
        var deletes = deleting
        var destination = spec
        if let colon = spec.firstIndex(of: ":") {
            deletes = deletes || colon == spec.startIndex
            destination = spec[spec.index(after: colon)...]
        }
        var name = String(destination)
        if name.hasPrefix("refs/heads/") {
            name.removeFirst("refs/heads/".count)
        }
        if name == "HEAD" || name.isEmpty {
            guard let branch = current() else {
                return nil
            }
            name = branch
        }
        destinations.append(deletes ? "delete \(name)" : name)
    }
    return printable(destinations.joined(separator: ", "))
}

/// `gh pr list`, `gh api repos/o/r/pulls`: gh and its first two words that are not flags (a leading
/// `-R owner/name` is skipped with its value), at most 60 characters.
func ghAction(_ arguments: [String]) -> String {
    let words = ghCommandWords(arguments).map { arguments[$0] }
    return shortened((["gh"] + words).joined(separator: " "))
}

/// Where the words of `ghAction` are in `arguments`.
private func ghCommandWords(_ arguments: [String]) -> [Int] {
    var words: [Int] = []
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
            words.append(index)
        } else if !words.isEmpty {
            break // flags after the command: its own options, not more of its name
        }
        index += 1
    }
    return words
}

/// What `gh <arguments>` asks for: its command, its command line (the command's words, then the other arguments,
/// quoted where needed) and, for creating or commenting, its `--title` and `--body`.
func ghUse(_ arguments: [String]) -> Use {
    let command = ghAction(arguments)
    let words = ghCommandWords(arguments)
    let rest = arguments.indices.filter { !words.contains($0) }.map { shellQuoted(arguments[$0]) }
    var use = Use(
        command: command,
        commandLine: printable((["gh"] + words.map { arguments[$0] } + rest).joined(separator: " "), limit: .max)
    )
    guard ["gh pr create", "gh issue create", "gh issue comment", "gh pr comment"].contains(command) else {
        return use
    }
    let options = arguments.prefix { $0 != "--" }
    // shown whole: for a post, what gets posted is the point of asking
    use.title = textOption(options, long: "title", short: "t").map { printable($0, limit: .max) }
    if let file = textOption(options, long: "body-file", short: "F") {
        use.body = bodyFile(file)
    } else if let body = textOption(options, long: "body", short: "b") {
        use.body = multiline(body)
    }
    return use
}

/// The text of a `--body-file` as gh will read it, relative to the current folder; `-` is standard input, which
/// gh-touchid can't read without taking it from gh.
private func bodyFile(_ path: String) -> String {
    guard path != "-" else {
        return "(from standard input, not shown)"
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
        return "(from \(printable(path)), which can't be read)"
    }
    return multiline(text)
}

/// Every line of `text`, each made printable, line breaks kept.
private func multiline(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { printable(String($0), limit: .max) }
        .joined(separator: "\n")
}

/// The value of the last `--<long> v`, `--<long>=v`, `-<short> v` or `-<short>v` in `arguments`.
private func textOption(_ arguments: ArraySlice<String>, long: String, short: Character) -> String? {
    var value: String?
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        index += 1
        if argument == "--\(long)" || argument == "-\(short)" {
            if index < arguments.endIndex {
                value = arguments[index]
                index += 1
            }
        } else if argument.hasPrefix("--\(long)=") {
            value = String(argument.dropFirst(long.count + 3))
        } else if argument.hasPrefix("-\(short)"), !argument.hasPrefix("--") {
            let inline = argument.dropFirst(2)
            value = String(inline.hasPrefix("=") ? inline.dropFirst() : inline)
        }
    }
    return value
}

/// `'two words'`: an argument as a shell would need it typed; others as they are.
private func shellQuoted(_ argument: String) -> String {
    let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@,+%^"))
    if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) {
        return argument
    }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Printable text on one line, at most `limit` characters (the last an ellipsis when cut).
private func shortened(_ text: String, limit: Int = 60) -> String {
    let line = printable(text, limit: text.count)
    return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
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
