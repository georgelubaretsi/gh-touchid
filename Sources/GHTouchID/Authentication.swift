import Foundation
import LocalAuthentication

/// How long a Touch ID dialog waits for an answer before it is withdrawn.
let touchIDTimeout: TimeInterval = 5 * 60

private final class AuthenticationResult: @unchecked Sendable {
    var success = false
    var error: Error?
}

/// Touch ID; `reason` completes the dialog's "gh-touchid is trying to …".
func authenticate(reason: String) throws {
#if GH_TOUCHID_TESTING
    let environment = ProcessInfo.processInfo.environment
    fputs("AUTH: \(reason)\n", stderr)
    if let delay = environment["GH_TOUCHID_TEST_AUTH_DELAY"].flatMap(Double.init) {
        Thread.sleep(forTimeInterval: delay)
    }
    if environment["GH_TOUCHID_TEST_DENY"] == "1" {
        throw ToolError.authentication("denied (GH_TOUCHID_TEST_DENY)")
    }
#else
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
#endif
}
