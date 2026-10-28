import Foundation

/// When RouterBar may log in again with the saved login after losing its session. A wrong password,
/// captcha or lockout never retries: repeating those logins could lock the router's admin account.
public enum ReconnectPolicy {
    /// Immediately, then after 30 s, 90 s and 5 min, then every 10 min.
    public static let delays: [TimeInterval] = [0, 30, 90, 300, 600]
    /// Minimum time between two automatic logins, whatever triggered them.
    public static let minimumSpacing: TimeInterval = 30
    public static func delay(beforeAttempt attempt: Int) -> TimeInterval { delays[min(max(attempt, 0), delays.count - 1)] }
    public static func retries(after error: Error) -> Bool {
        switch error as? RouterError {
        // Unreachable, rebooting or briefly confused routers; none of these submitted a rejected password.
        case .network, .httpStatus, .invalidResponse, .submissionUncertain, .authenticationRequired, .unsupportedLogin: true
        case .invalidCredentials, .captchaRequired, .locked, .invalidAddress, .validation: false
        case nil: error is URLError
        }
    }
}
