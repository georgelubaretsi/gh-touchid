// What `gh-touchid help` prints: every command's synopsis and description. `help <command>` and `<command> --help`
// print one command's, as does a wrong use of that command (on stderr, exit status 2).

enum Usage {
    private struct Command {
        let name: String
        let synopsis: [String]
        let description: String
    }

    private static let commands = [
        Command(
            name: "app",
            synopsis: [
                "gh-touchid app create <owner> [--name <name>] [--no-open]",
                "gh-touchid app set <owner> --client-id <id> [--no-open] < client-secret",
                "gh-touchid app login <owner> [--no-open]",
            ],
            description: """
            `app create` makes a private GitHub App for an owner from a manifest in your browser (named
            <owner>-touchid unless --name says otherwise), signs you in to it and opens its installation page
            (--no-open prints the first URL instead). `app set` takes an App made by hand: its client ID, and its
            client secret on stdin or at a hidden prompt; it must list the callback URL
            http://127.0.0.1:47911/callback. `app login` signs you in to the owner's App again. Each asks for Touch
            ID before storing anything.
            """
        ),
        Command(
            name: "account",
            synopsis: [
                "gh-touchid account add <login>",
                "gh-touchid account remove <login>",
            ],
            description: """
            `account add` stores a token of one of your GitHub accounts (hidden input or stdin) once GitHub confirms
            its login; `account remove` deletes it. `as` uses it.
            """
        ),
        Command(
            name: "gh",
            synopsis: ["gh-touchid gh <arguments...>"],
            description: """
            `gh` runs GitHub CLI with a token for one repository: the one named with -R/--repo, for `gh api` the one
            its endpoint names, else GH_REPO, else the current repository's origin. The token acts as you through
            the owner's App and lacks the workflows permission unless the repository is elevated; outside a session,
            each use asks for Touch ID. For an owner without an App, it refuses before asking. Everything after `gh`
            goes to GitHub CLI: `gh-touchid gh --help` is its help.
            """
        ),
        Command(
            name: "git",
            synopsis: [
                "gh-touchid git setup <owner>",
                "gh-touchid git credential <get|store|erase>",
            ],
            description: """
            `git setup` makes this gh-touchid the only credential helper Git asks for the owner's repositories, in
            your global Git configuration (write the owner as in your remotes' URLs). `git credential` is that
            helper; it answers only Git's HTTPS transport.
            """
        ),
        Command(
            name: "as",
            synopsis: ["gh-touchid as <login> [--] <command> [arguments...]"],
            description: """
            `as` runs a command as one of your stored accounts, with Touch ID on every use, sessions included:
            `as <login> gh ...` runs GitHub CLI with that account's token, anything else runs with
            GH_TOUCHID_AS=<login>, which gh and Git honour. The `--` before the command is optional.
            """
        ),
        Command(
            name: "session",
            synopsis: ["gh-touchid session [--repo <owner/name>]..."],
            description: """
            `session` registers the program that ran it (looking past shells that only run a command or a script).
            Its first GitHub use asks for Touch ID once; then it and everything it starts get tokens for its
            repositories without Touch ID until it exits, and issue-only tokens for other repositories your Apps are
            installed on (public ones ask per use). Without --repo it takes the outermost Git repository here and
            those nested up to two levels below it whose owner has an App.
            """
        ),
        Command(
            name: "elevate",
            synopsis: ["gh-touchid elevate --for <duration> [--repo <owner/name>]..."],
            description: """
            `elevate` lets tokens for the repositories (without --repo, the current one) include the workflows
            permission for a while: 30m, 8h, 1h30m, at most 1d.
            """
        ),
        Command(
            name: "status",
            synopsis: ["gh-touchid status"],
            description: """
            `status` lists stored Apps with who is signed in to each, your accounts, whether Git goes through this
            gh-touchid for each owner, which `gh` comes first on PATH (and how to put this gh-touchid's first),
            whether another gh is signed in, and sessions and elevations.
            """
        ),
        Command(
            name: "lock",
            synopsis: ["gh-touchid lock"],
            description: "`lock` ends every session approval and elevation now."
        ),
        Command(
            name: "version",
            synopsis: ["gh-touchid version"],
            description: "`version` prints gh-touchid's version."
        ),
        Command(
            name: "help",
            synopsis: ["gh-touchid help [<command>]"],
            description: "`help` prints this, or one command's usage; so does `gh-touchid <command> --help`."
        ),
    ]

    private static let footer = "Every use is logged to ~/Library/Logs/gh-touchid/access.log."

    /// Every command.
    static var all: String {
        let synopses = commands.flatMap(\.synopsis).map { "  \($0)" }.joined(separator: "\n")
        let descriptions = commands.map(\.description).joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(descriptions)\n\(footer)"
    }

    /// One command's; nil for a name that is not one.
    static func of(_ name: String) -> String? {
        guard let command = commands.first(where: { $0.name == name }) else {
            return nil
        }
        let synopses = command.synopsis.map { "  \($0)" }.joined(separator: "\n")
        return "Usage:\n\(synopses)\n\n\(command.description)"
    }
}
