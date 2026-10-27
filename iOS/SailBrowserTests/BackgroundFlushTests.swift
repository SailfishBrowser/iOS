import Foundation
import Testing
import UIKit
@testable import SailBrowser

// One ordered event list shared by a recording assertion and a session write that parks until the test releases it.
@MainActor final class FlushLog {
    enum Event: Equatable {
        case begin, entered, released, end
    }

    private(set) var events: [Event] = []
    private(set) var expired: [@MainActor @Sendable () -> Void] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var open = false

    var assertion: BackgroundAssertion {
        BackgroundAssertion(begin: { [self] _, expired in
            events.append(.begin)
            self.expired.append(expired)
            return { self.events.append(.end) }
        })
    }

    var writer: @Sendable (Data, URL) async throws -> Void {
        { [self] data, url in
            await park()
            try await JSONFile.write(data, to: url)
        }
    }

    func count(_ event: Event) -> Int {
        events.count { $0 == event }
    }

    func release() {
        open = true
        gate?.resume()
        gate = nil
    }

    private func park() async {
        events.append(.entered)
        if !open {
            await withCheckedContinuation { gate = $0 }
        }
        events.append(.released)
    }
}

@MainActor
struct BackgroundFlushTests {
    private func settled(_ env: AppEnvironment) async throws -> WebTabController {
        env.open(page("a"))
        let controller = env.activeController!
        try await waitUntil { controller.hasSettled }
        return controller
    }

    // The resign begins the assertion, the background adds no second one, the flush waits for the session queue, and
    // the assertion ends once, after everything landed; the expiration handler afterwards ends nothing again.
    @Test func theAssertionEndsOnceAfterEveryQueueDrains() async throws {
        let log = FlushLog()
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories, assertion: log.assertion)
        env.sessions.write = log.writer
        let controller = try await settled(env)
        env.sceneWillResignActive()
        let before = Date()
        env.sceneDidEnterBackground()
        try await waitUntil { log.events.contains(.entered) }
        #expect(log.count(.end) == 0)
        log.release()
        try await waitUntil { log.count(.end) == 1 }
        #expect(log.events == [.begin, .entered, .released, .end])
        let state = directories.support.appending(path: "state.json").path(percentEncoded: false)
        let modified = try FileManager.default.attributesOfItem(atPath: state)[.modificationDate] as! Date
        // The file clock and Date() share the realtime clock; the write came at or after the background call.
        #expect(modified.timeIntervalSince(before) >= 0)
        let session = directories.support.appending(path: "sessions/\(controller.tabID.uuidString).session")
        #expect(FileManager.default.fileExists(atPath: session.path(percentEncoded: false)))
        log.expired.first!()
        #expect(log.count(.end) == 1)
    }

    // An expiry while the write is still parked ends the assertion then, and the completion ends nothing again.
    @Test func anExpiryEndsTheAssertionAndTheCompletionEndsNothingAgain() async throws {
        let log = FlushLog()
        let env = makeEnvironment(assertion: log.assertion)
        env.sessions.write = log.writer
        _ = try await settled(env)
        env.sceneWillResignActive()
        env.sceneDidEnterBackground()
        try await waitUntil { log.events.contains(.entered) }
        log.expired.first!()
        #expect(log.count(.end) == 1)
        log.release()
        try await waitUntil { log.events.contains(.released) }
        await env.sessions.flush()
        await env.snapshots.flush()
        await nextDisplayFrame()
        await nextDisplayFrame()
        #expect(log.count(.end) == 1)
    }

    @Test func activeEndsAnIdleAssertionAndADirectBackgroundBeginsBeforeItEnds() async throws {
        let log = FlushLog()
        let env = makeEnvironment(assertion: log.assertion)
        env.sceneWillResignActive()
        env.sceneDidBecomeActive()
        #expect(log.events == [.begin, .end])

        let direct = FlushLog()
        let fresh = makeEnvironment(assertion: direct.assertion)
        fresh.sceneDidEnterBackground()
        #expect(direct.events.first == .begin)
        try await waitUntil { direct.count(.end) == 1 }
        #expect(direct.events == [.begin, .end])
    }
}
