import Foundation
import Testing

// The app's own sessions keep nothing between requests and never wait for the network to come back.
func expectCookieless(
    _ configuration: URLSessionConfiguration, requestTimeout: TimeInterval, resourceTimeout: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(configuration.httpCookieStorage == nil, sourceLocation: sourceLocation)
    #expect(!configuration.httpShouldSetCookies, sourceLocation: sourceLocation)
    #expect(configuration.urlCache == nil, sourceLocation: sourceLocation)
    #expect(configuration.urlCredentialStorage == nil, sourceLocation: sourceLocation)
    #expect(!configuration.allowsConstrainedNetworkAccess, sourceLocation: sourceLocation)
    #expect(configuration.allowsExpensiveNetworkAccess, sourceLocation: sourceLocation)
    #expect(!configuration.waitsForConnectivity, sourceLocation: sourceLocation)
    #expect(configuration.timeoutIntervalForRequest == requestTimeout, sourceLocation: sourceLocation)
    #expect(configuration.timeoutIntervalForResource == resourceTimeout, sourceLocation: sourceLocation)
}

extension Trait where Self == ConditionTrait {
    // Off when xcodebuild runs with TEST_RUNNER_SAIL_CI set, as CI does: a slow runner misses the real-time window.
    static var timingSensitive: Self {
        .disabled(if: ProcessInfo.processInfo.environment["SAIL_CI"] != nil, "Timing-sensitive; runs locally")
    }
}
