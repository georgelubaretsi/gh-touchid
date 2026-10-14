import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import UniformTypeIdentifiers

// The approval window: a prompt's question, its facts, Deny, and Touch ID embedded in the window
// (LAAuthenticationView) instead of macOS's small sheet. Production builds show it from authenticate(_:); test
// builds only lay it out for snapshots.

/// Asks `prompt` in the approval window with Touch ID on `context`, which can evaluate biometrics. Returns once Touch
/// ID allows; throws when it fails, on Deny or Esc, and when nobody answers within `touchIDTimeout`. The window is
/// gone when this returns or throws.
@MainActor
func approveInWindow(_ prompt: Prompt, context: LAContext) throws {
    let answer = Answer()
    let touchID = LAAuthenticationView(context: context, controlSize: .large)
    let window = approvalWindow(prompt, host: hostApplication(), touchID: touchID) {
        context.invalidate()
        answer.give(.authentication("denied"))
    }
    if NSApp.isHidden {
        NSApp.unhide(nil) // an earlier prompt of this process hid it
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: prompt.fallback
    ) { success, error in
        let failure = success
            ? nil
            : ToolError.authentication(error?.localizedDescription ?? "authentication was denied")
        DispatchQueue.main.async {
            answer.give(failure)
        }
    }
    let timeout = DispatchWorkItem {
        context.invalidate()
        answer.give(.authenticationNotAnswered)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + touchIDTimeout, execute: timeout)

    NSApp.runModal(for: window)
    timeout.cancel()
    window.orderOut(nil)
    NSApp.hide(nil) // hands the keyboard back to the app that was in front
    if let failure = answer.failure {
        throw failure
    }
}

/// The first answer to the window (allowed, or why not), which ends its modal loop; later ones, such as the reply
/// to an invalidated evaluation after Deny, are ignored.
@MainActor
private final class Answer {
    private(set) var failure: ToolError?
    private var given = false

    func give(_ failure: ToolError?) {
        guard !given else {
            return
        }
        given = true
        self.failure = failure
        NSApp.stopModal()
    }
}

/// The approval window for `prompt`, sized to its content and centred, not yet on screen. `host` is the app bundle
/// whose icon it shows (the generic program icon when nil); `touchID` is the Touch ID control.
@MainActor
func approvalWindow(
    _ prompt: Prompt,
    host: String?,
    touchID: NSView,
    deny: @escaping @MainActor () -> Void
) -> NSWindow {
    let icon = host.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
    let name = host.map { FileManager.default.displayName(atPath: $0) }
    let content = NSHostingView(rootView: ApprovalView(
        prompt: prompt,
        icon: icon,
        iconLabel: name,
        touchID: touchID,
        deny: deny
    ))
    content.safeAreaRegions = [] // the hidden titlebar is part of the layout's margin, not above it
    let window = NSWindow(
        contentRect: .zero,
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = prompt.title // not shown; VoiceOver reads it
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
    }
    window.isMovableByWindowBackground = true
    window.level = .floating
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.setContentSize(content.fittingSize)
    window.center()
    return window
}

/// The app the request comes from as the Dock shows it, e.g. /System/Applications/Utilities/Terminal.app for
/// `git < zsh < login < Terminal`: the outermost app bundle around the nearest ancestor that runs as an app (from
/// `….app/Contents/MacOS/`, which leaves out tools that merely live in a bundle, like Xcode's `git`); nil when none
/// does.
func hostApplication() -> String? {
    for pid in lineage(getppid()) {
        if let path = executablePath(pid), path.contains(".app/Contents/MacOS/"), let bundle = path.range(of: ".app/") {
            return String(path[..<bundle.lowerBound]) + ".app"
        }
    }
    return nil
}

/// Layout B: the host app's icon, the question, one sentence, the facts, then Deny and Touch ID.
private struct ApprovalView: View {
    let prompt: Prompt
    let icon: NSImage
    let iconLabel: String?
    let touchID: NSView
    let deny: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityLabel(iconLabel ?? "")
                .accessibilityHidden(iconLabel == nil)
            Text(keepingNamesWhole(prompt.title, style: .title3, weight: .semibold))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 12)
            Text(keepingNamesWhole(prompt.message, style: .body))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if !prompt.rows.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(Array(prompt.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Image(systemName: row.symbol)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.center)
                                .accessibilityHidden(true)
                            Text(row.text)
                                .font(row.monospaced ? .body.monospaced() : .body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(row.label.map { "\($0): \(row.text)" } ?? row.text)
                        }
                    }
                }
                .padding(.top, 16)
            }
            HStack(spacing: 10) {
                Button("Deny") {
                    deny()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                Spacer()
                Text("Touch ID to Allow")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TouchIDControl(view: touchID)
                    .frame(width: 44, height: 44)
            }
            .padding(.top, 22)
        }
        .padding(Self.margin)
        .frame(width: Self.width, alignment: .leading)
    }

    private static let width: CGFloat = 420
    private static let margin: CGFloat = 24

    /// Names stay whole when the text wraps: no line break after a hyphen or a slash (U+2060 WORD JOINER) in a word
    /// that fits on a line, so `octo-org/hello-world` moves to the next line as one. A word too long for a line
    /// breaks after its slash, or else after its hyphens, rather than between two letters.
    private func keepingNamesWhole(
        _ text: String,
        style: NSFont.TextStyle,
        weight: NSFont.Weight = .regular
    ) -> String {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        func fits(_ word: Substring) -> Bool {
            NSAttributedString(string: String(word), attributes: [.font: font]).size().width
                <= Self.width - 2 * Self.margin
        }
        func joined(_ word: Substring, after marks: Set<Character>) -> String {
            word.reduce(into: "") { result, character in
                result.append(character)
                if marks.contains(character) {
                    result.append("\u{2060}")
                }
            }
        }
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            if fits(word) {
                return joined(word, after: ["-", "/"])
            }
            return word.split(separator: "/", omittingEmptySubsequences: false)
                .map { fits($0) ? joined($0, after: ["-"]) : String($0) }
                .joined(separator: "/")
        }.joined(separator: " ")
    }
}

private struct TouchIDControl: NSViewRepresentable {
    let view: NSView

    func makeNSView(context _: Context) -> NSView {
        view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
