#if GH_TOUCHID_TESTING
import AppKit

// Test builds only: GH_TOUCHID_TEST_RENDER=<dir> lays out every kind of prompt in the approval window, light and
// dark, and writes <dir>/<kind>-<light|dark>.png. No Touch ID (a symbol stands in for the control) and no window on
// screen: the windows are drawn without ever being ordered in.

func renderPrompts(into directory: String) throws -> Int32 {
    let host = "/System/Applications/Utilities/Terminal.app"
    let folder = NSHomeDirectory() + "/code/widget"
    let started = Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: Date()) ?? Date()
    let widget = "acme/widget"
    let hello = "octo-org/hello-world"
    let prompts: [(String, Prompt, String?)] = [
        ("use-push", .appUse(by: "omp", command: "git push", repository: widget), host),
        ("use-push-no-app", .appUse(by: "omp", command: "git push", repository: widget), nil),
        ("use-read", .appUse(by: "omp", command: "git fetch", repository: hello), host),
        ("use-pull-request", .appUse(by: "omp", command: "gh pr create", repository: hello), host),
        ("use-merge", .appUse(by: "agent", command: "gh pr merge", repository: "acme/gadget"), host),
        ("use-long-names", .appUse(
            by: "agent-harness-runner",
            command: "git push",
            repository: "an-organization-with-a-long-name/a-repository-with-an-even-longer-name"
        ), host),
        ("use-issue", .appUse(by: "omp", command: "gh issue create", repository: widget), host),
        ("use-other", .appUse(by: "omp", command: "gh api repos/\(hello)/pulls/12/files", repository: hello), host),
        ("session-one", .session(program: "omp", repositories: [widget], folder: folder, started: started), host),
        ("session-three", .session(
            program: "omp",
            repositories: [widget, "acme/gadget", "acme/docs"],
            folder: folder,
            started: started
        ), host),
        ("session-many", .session(
            program: "omp",
            repositories: [widget, "acme/gadget", "acme/docs", hello, "octo-org/octo-repo"],
            folder: folder,
            started: started
        ), host),
        ("public-issue", .publicIssue(program: "omp", command: "gh issue create", repository: "acme/docs"), host),
        ("elevate-one", .elevation(repositories: [widget], seconds: 30 * 60), host),
        ("elevate-two", .elevation(repositories: [widget, "acme/gadget"], seconds: 90 * 60), host),
        ("account", .acting(as: "octocat", by: "omp", command: "gh pr merge", repository: "octo-org/octo-repo"), host),
        ("account-no-repository", .acting(as: "mona", by: "omp", command: "gh api user", repository: nil), host),
        ("app-create", .newApp("acme-agent", owner: "acme"), host),
        ("app-set", .appKey(owner: "acme"), host),
        ("user-add", .accountToken("octocat"), host),
    ]
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return try MainActor.assumeIsolated {
        guard NSApplication.shared.setActivationPolicy(.accessory) else {
            throw ToolError.input("AppKit cannot start here")
        }
        for (kind, prompt, host) in prompts {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let symbol = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)!)
                symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .controlAccentColor))
                let window = approvalWindow(prompt, host: host, touchID: symbol) {}
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
