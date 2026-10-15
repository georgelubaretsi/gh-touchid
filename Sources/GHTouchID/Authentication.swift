import AppKit
import Foundation
import LocalAuthentication

/// How long a Touch ID dialog waits for an answer before it is withdrawn.
let touchIDTimeout: TimeInterval = 5 * 60

private final class AuthenticationResult: @unchecked Sendable {
    var success = false
    var error: Error?
}

/// Touch ID for `prompt`: in the approval window, or in macOS's own sheet (with `prompt.fallback`) where no window
/// can be shown. Test builds print `AUTH: <fallback>` instead and never show either.
func authenticate(_ prompt: Prompt) throws {
#if GH_TOUCHID_TESTING
    let environment = ProcessInfo.processInfo.environment
    if environment["GH_TOUCHID_TEST_SCREEN_LOCKED"] == "1" {
        throw ToolError.screenLocked
    }
    fputs("AUTH: \(prompt.fallback)\n", stderr)
    if let delay = environment["GH_TOUCHID_TEST_AUTH_DELAY"].flatMap(Double.init) {
        Thread.sleep(forTimeInterval: delay)
    }
    if environment["GH_TOUCHID_TEST_DENY"] == "1" {
        throw ToolError.authentication("denied (GH_TOUCHID_TEST_DENY)")
    }
#else
    // a locked screen would cancel any dialog at once, which reads as if someone had said no
    guard !isScreenLocked() else {
        throw ToolError.screenLocked
    }
    let context = LAContext()
    context.localizedFallbackTitle = ""
    context.touchIDAuthenticationAllowableReuseDuration = 0

    var availabilityError: NSError?
    guard context.canEvaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        error: &availabilityError
    ) else {
        throw ToolError.authentication(
            availabilityError?.localizedDescription ?? "biometrics are unavailable"
        )
    }

    do {
        if Thread.isMainThread, isOnConsole() {
            let shown = try MainActor.assumeIsolated {
                // false when AppKit cannot start, e.g. without a connection to the window server
                guard NSApplication.shared.setActivationPolicy(.accessory) else {
                    return false
                }
                try approveInWindow(prompt, context: context)
                return true
            }
            if shown {
                return
            }
        }
        try authenticateInSheet(reason: prompt.fallback, context: context)
    } catch {
        // the screen locked while the dialog was up: macOS cancelled it, nobody declined
        if isScreenLocked() {
            throw ToolError.screenLocked
        }
        throw error
    }
#endif
}

/// Whether this process runs in the login session on the Mac's own display, where a window can be shown: not over
/// SSH, and not in another user's session after a switch.
private func isOnConsole() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }
    return session[kCGSessionOnConsoleKey] as? Bool == true
}

/// Whether the login session's screen is locked (the session dictionary's `CGSSessionScreenIsLocked`).
private func isScreenLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
}

/// macOS's own Touch ID sheet, "gh-touchid is trying to <reason>."
private func authenticateInSheet(reason: String, context: LAContext) throws {
    let result = AuthenticationResult()
    let semaphore = DispatchSemaphore(value: 0)

    context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
    ) { success, error in
        result.success = success
        result.error = error
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + touchIDTimeout) == .timedOut {
        // withdraws the dialog; the reply handler then runs with an error nobody waits for
        context.invalidate()
        throw ToolError.authenticationNotAnswered
    }
    guard result.success else {
        throw ToolError.authentication(
            result.error?.localizedDescription ?? "authentication was denied"
        )
    }
}
