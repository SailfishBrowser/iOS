import Foundation
@testable import SailBrowser

// The Translation framework's session, faked: the real one needs the languages installed on the device.
final class RecordingSession: nonisolated PageTranslationSession {
    private(set) var batches: [[PageText]] = []
    private(set) var prepared = false
    private let failingAfter: Int?

    init(failingAfter: Int? = nil) {
        self.failingAfter = failingAfter
    }

    func prepareTranslation() async throws {
        prepared = true
    }

    func translate(_ batch: [PageText]) async throws -> [PageText] {
        if batches.count == failingAfter {
            throw CancellationError()
        }
        batches.append(batch)
        return batch.reversed().map { PageText(id: $0.id, text: "t:" + $0.text) }
    }
}

final class GatedSession: nonisolated PageTranslationSession {
    private(set) var isWaiting = false
    private var gate: CheckedContinuation<Void, Never>?

    func prepareTranslation() async throws {}

    func translate(_ batch: [PageText]) async throws -> [PageText] {
        await withCheckedContinuation {
            gate = $0
            isWaiting = true
        }
        return batch.map { PageText(id: $0.id, text: "translated") }
    }

    func release() {
        gate!.resume()
    }
}
