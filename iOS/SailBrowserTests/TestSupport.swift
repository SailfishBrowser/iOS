import Foundation

struct WaitTimedOut: Error {}

func waitUntil(
    timeout: Duration = .seconds(5), every interval: Duration = .milliseconds(20), _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
        try await Task.sleep(for: interval)
    }
}
