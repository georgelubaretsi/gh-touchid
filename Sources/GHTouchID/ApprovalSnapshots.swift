#if GH_TOUCHID_TESTING
import AppKit

// Test builds only: GH_TOUCHID_TEST_RENDER=<dir> lays out every kind of prompt in the approval window, light and
// dark, and writes <dir>/<kind>-<light|dark>.png. No Touch ID (the touchid symbol stands in for the control) and no
// window on screen: the windows are drawn without ever being ordered in.

func renderPrompts(into directory: String) throws -> Int32 {
    let folder = NSHomeDirectory() + "/code/widget"
    let agent = Requester(name: "agent", folder: folder)
    let started = Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: Date()) ?? Date()
    let widget = "acme/widget"
    let hello = "octo-org/hello-world"
    let push = Use(command: "git push", branch: "fix-login")
    let prompts: [(String, Prompt)] = [
        ("use-push", .appUse(by: agent, use: push, repository: widget, app: "acme-agent", login: "octocat")),
        ("use-push-no-slug", .appUse(by: agent, use: push, repository: widget, app: nil, login: nil)),
        ("use-push-delete", .appUse(
            by: agent,
            use: Use(command: "git push", branch: "delete old-login"),
            repository: widget,
            app: "acme-agent",
            login: "octocat"
        )),
        ("use-read", .appUse(
            by: agent,
            use: Use(command: "git fetch"),
            repository: hello,
            app: "octo-agent",
            login: "octocat"
        )),
        ("use-pull-request", .appUse(
            by: agent,
            use: ghUse(["pr", "create", "--title", "Fix the login form", "--body", "Closes #12."]),
            repository: widget,
            app: "acme-agent",
            login: "octocat"
        )),
        ("use-merge", .appUse(
            by: agent,
            use: ghUse(["pr", "merge", "12", "--squash", "--delete-branch"]),
            repository: "acme/gadget",
            app: "acme-agent",
            login: "octocat"
        )),
        ("use-long-names", .appUse(
            by: Requester(name: "agent-harness-runner", folder: NSHomeDirectory() + "/code/a-folder/with/a/long/path"),
            use: Use(command: "git push", branch: "a-branch-with-a-rather-long-name-for-a-small-fix"),
            repository: "an-organization-with-a-long-name/a-repository-with-an-even-longer-name",
            app: "an-organization-with-a-long-name-agent",
            login: "a-person-with-a-rather-long-login"
        )),
        ("use-issue", .appUse(
            by: agent,
            use: ghUse(["issue", "create", "-t", "Login fails on Safari", "-b", "Steps to reproduce: …"]),
            repository: widget,
            app: "acme-agent",
            login: "octocat"
        )),
        ("use-other", .appUse(
            by: agent,
            use: ghUse(["api", "repos/\(hello)/pulls/12/files", "--paginate"]),
            repository: hello,
            app: "octo-agent",
            login: "octocat"
        )),
        ("session-one", .session(program: "agent", repositories: [widget], folder: folder, started: started)),
        ("session-three", .session(
            program: "agent",
            repositories: [widget, "acme/gadget", "acme/docs"],
            folder: folder,
            started: started
        )),
        ("session-many", .session(
            program: "agent",
            repositories: [widget, "acme/gadget", "acme/docs", hello, "octo-org/octo-repo"],
            folder: folder,
            started: started
        )),
        ("session-nine", .session(
            program: "agent",
            repositories: (1 ... 9).map { "acme/service-\($0)" },
            folder: folder,
            started: started
        )),
        ("public-long", .publicIssue(
            by: agent,
            use: ghUse([
                "issue", "create", "--title", "The install guide skips the step that sets up the cache folder",
                "--body", (1 ... 60).map { "Line \($0) of the report: what happened, what was expected." }
                    .joined(separator: "\n"),
            ]),
            repository: "acme/docs",
            app: "acme-agent",
            login: "octocat"
        )),
        ("public-issue", .publicIssue(
            by: agent,
            use: ghUse([
                "issue", "create", "--title", "Typo in the README",
                "--body", "The install section says `brew instal`.\nIt should say `brew install`.\nThanks!\nmona",
            ]),
            repository: "acme/docs",
            app: "acme-agent",
            login: "octocat"
        )),
        ("public-comment", .publicIssue(
            by: agent,
            use: ghUse(["issue", "comment", "7", "--body-file", "notes.md"]),
            repository: "acme/docs",
            app: nil,
            login: "octocat"
        )),
        ("elevate-one", .elevation(repositories: [widget], seconds: 30 * 60, by: agent)),
        ("elevate-two", .elevation(repositories: [widget, "acme/gadget"], seconds: 90 * 60, by: agent)),
        ("account", .acting(
            as: "octocat",
            by: agent,
            use: ghUse(["pr", "merge", "12", "--rebase"]),
            repository: "octo-org/octo-repo"
        )),
        ("account-no-repository", .acting(as: "mona", by: agent, use: ghUse(["api", "user"]), repository: nil)),
        ("app-create", .newApp("acme-agent", owner: "acme")),
        ("app-create-sign-in", .signIn("octocat", owner: "acme", app: "acme-agent", storesApp: true)),
        ("app-set", .signIn("octocat", owner: "acme", app: nil, storesApp: true)),
        ("app-login", .signIn("octocat", owner: "acme", app: "acme-agent", storesApp: false)),
        ("user-add", .accountToken("octocat")),
    ]
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return try MainActor.assumeIsolated {
        guard NSApplication.shared.setActivationPolicy(.accessory) else {
            throw ToolError.input("AppKit cannot start here")
        }
        for (kind, prompt) in prompts {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let symbol = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)!)
                symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemPink))
                let window = approvalWindow(prompt, touchID: symbol) {}
                window.appearance = NSAppearance(named: appearance)
                let frame = window.contentView!.superview!
                frame.layoutSubtreeIfNeeded()
                guard let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    throw ToolError.input("cannot draw the \(kind) window")
                }
                frame.cacheDisplay(in: frame.bounds, to: image)
                let path = (directory as NSString).appendingPathComponent("\(kind)-\(suffix).png")
                try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("\(path) \(Int(window.frame.width))x\(Int(window.frame.height))")
                window.close()
            }
        }
        return 0
    }
}
#endif
