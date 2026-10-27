import Foundation

// The one builder of the app's own sessions: ephemeral, cookie free, cache free, off in Low Data Mode (the task fails
// at once with networkUnavailableReason .constrained), failing fast rather than waiting for connectivity, and bounded.
nonisolated enum SessionConfiguration {
    static func cookieless(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}
