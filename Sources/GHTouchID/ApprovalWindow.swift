import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

// The approval window: what a prompt asks in labelled rows, Touch ID embedded in the window (LAAuthenticationView)
// instead of macOS's small sheet, and Deny (Esc). A floating panel that takes the keyboard without activating
// gh-touchid, so the app in front stays in front. Production builds show it from authenticate(_:); test builds only
// lay it out for snapshots.

/// Asks `prompt` in the approval window with Touch ID on `context`, which can evaluate biometrics. Returns once Touch
/// ID allows; throws when it fails, on Deny or Esc, and when nobody answers within `touchIDTimeout`. The window is
/// gone when this returns or throws.
@MainActor
func approveInWindow(_ prompt: Prompt, context: LAContext) throws {
    let answer = Answer()
    let touchID = LAAuthenticationView(context: context, controlSize: .regular)
    let window = approvalWindow(prompt, touchID: touchID) {
        context.invalidate()
        answer.give(.authentication("denied"))
    }
    window.orderFrontRegardless()
    window.makeKey()

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

/// A panel that takes the keyboard (for Esc) without activating gh-touchid.
private final class ApprovalPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// The approval window for `prompt`, sized to its content and centred, not yet on screen. `touchID` is the Touch ID
/// control; it is drawn at most 22 points square.
@MainActor
func approvalWindow(_ prompt: Prompt, touchID: NSView, deny: @escaping @MainActor () -> Void) -> NSWindow {
    let content = NSHostingView(rootView: ApprovalView(prompt: prompt, touchID: touchID, deny: deny))
    content.safeAreaRegions = [] // the hidden titlebar is part of the layout, not above it
    let window = ApprovalPanel(
        contentRect: .zero,
        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    window.title = "gh-touchid: approval needed" // not shown; VoiceOver reads it
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
    }
    window.isFloatingPanel = true
    window.becomesKeyOnlyIfNeeded = false
    window.isMovableByWindowBackground = true
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.setContentSize(content.fittingSize)
    window.center()
    return window
}

/// gh-touchid and "approval needed", the prompt's rows, then Touch ID with what it allows and Deny (Esc).
private struct ApprovalView: View {
    let prompt: Prompt
    let touchID: NSView
    let deny: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("gh-touchid")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("approval needed")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 12)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Self.margin, verticalSpacing: 9) {
                ForEach(Array(prompt.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.key)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(keepingNamesWhole(row.value, font: Self.valueFont(row.emphasis)))
                            .font(.system(size: 14, weight: row.emphasis == .strong ? .semibold : .regular,
                                          design: .monospaced))
                            .foregroundStyle(
                                row.emphasis == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("\(row.key): \(row.value)")
                    }
                }
            }
            .padding(Self.margin)
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    TouchIDControl(view: touchID)
                        .frame(width: TouchIDControl.side, height: TouchIDControl.side)
                    Text(prompt.allowLabel)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
                Spacer()
                Button {
                    deny()
                } label: {
                    HStack(spacing: 6) {
                        Text("esc")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
                        Text("deny")
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Deny")
            }
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 12)
        }
        .frame(width: Self.width)
    }

    private static let width: CGFloat = 440
    private static let margin: CGFloat = 18
    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static func valueFont(_ emphasis: Prompt.Emphasis) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 14, weight: emphasis == .strong ? .semibold : .regular)
    }

    /// The width of the value column: the window less its margins, the widest key and the gap after it.
    private var valueWidth: CGFloat {
        let keys = prompt.rows.map {
            NSAttributedString(string: $0.key, attributes: [.font: Self.keyFont]).size().width
        }
        return Self.width - 3 * Self.margin - (keys.max() ?? 0)
    }

    /// Names stay whole when a value wraps: no line break after a hyphen or a slash (U+2060 WORD JOINER) in a word
    /// that fits on a line, so `octo-org/hello-world` moves to the next line as one. A word too long for a line
    /// breaks after its slashes, or else after its hyphens, rather than between two letters.
    private func keepingNamesWhole(_ text: String, font: NSFont) -> String {
        let width = valueWidth
        func fits(_ word: Substring) -> Bool {
            NSAttributedString(string: String(word), attributes: [.font: font]).size().width <= width
        }
        func joined(_ word: Substring, after marks: Set<Character>) -> String {
            word.reduce(into: "") { result, character in
                result.append(character)
                if marks.contains(character) {
                    result.append("\u{2060}")
                }
            }
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word in
                if fits(word) {
                    return joined(word, after: ["-", "/"])
                }
                return word.split(separator: "/", omittingEmptySubsequences: false)
                    .map { fits($0) ? joined($0, after: ["-"]) : String($0) }
                    .joined(separator: "/")
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

/// The Touch ID control in a container of exactly `side` points that clips it: LAAuthenticationView draws itself as
/// large as it is allowed to, so its size is fixed by constraints rather than left to SwiftUI.
private struct TouchIDControl: NSViewRepresentable {
    static let side: CGFloat = 22

    let view: NSView

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.side),
            container.heightAnchor.constraint(equalToConstant: Self.side),
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.side),
            view.heightAnchor.constraint(equalToConstant: Self.side),
        ])
        return container
    }

    func updateNSView(_: NSView, context _: Context) {}

    func sizeThatFits(_: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        CGSize(width: Self.side, height: Self.side)
    }
}
