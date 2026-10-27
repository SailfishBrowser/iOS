import Foundation
import Synchronization
import Testing
@testable import SailBrowser

nonisolated private struct EncodeProbe: Encodable, Sendable {
    static let encodedOnMain = Mutex<Bool?>(nil)

    func encode(to encoder: Encoder) throws {
        Self.encodedOnMain.withLock { $0 = Thread.isMainThread }
        var container = encoder.singleValueContainer()
        try container.encode(1)
    }
}

struct DebouncedWriterTests {
    @Test func encodesOffTheMainThread() async {
        let writer = DebouncedWriter<EncodeProbe>(
            fileURL: URL(filePath: "/dev/null"), delay: .milliseconds(10), write: { _, _ in })
        writer.schedule(EncodeProbe())
        await writer.flush()
        #expect(EncodeProbe.encodedOnMain.withLock { $0 } == false)
    }

    @Test func coalescesBurstIntoSingleWrite() async throws {
        let calls = Mutex<[Data]>([])
        let writer = DebouncedWriter<Int>(
            fileURL: URL(filePath: "/dev/null"), delay: .milliseconds(200),
            write: { data, _ in calls.withLock { $0.append(data) } })

        for value in 1...10 {
            writer.schedule(value)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(600))

        #expect(calls.withLock { $0 } == [Data("10".utf8)])
        await writer.flush()
        #expect(calls.withLock { $0.count } == 1)
    }

    @Test func flushWaitsForWriteInProgress() async throws {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let finished = Mutex(false)
        let writer = DebouncedWriter<Int>(
            fileURL: URL(filePath: "/dev/null"), delay: .milliseconds(10),
            write: { _, _ in
                startedSignal.yield()
                for await _ in gate { break }
                finished.withLock { $0 = true }
            })

        writer.schedule(1)
        for await _ in started { break }
        let flushReturned = Mutex(false)
        let flush = Task {
            await writer.flush()
            flushReturned.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!flushReturned.withLock { $0 })

        release.yield()
        await flush.value
        #expect(finished.withLock { $0 })
    }

    // A write that fails keeps its value pending, so the next flush writes it instead of losing it; a value scheduled
    // meanwhile wins.
    @Test func aFailedWriteStaysPendingUntilTheNextFlush() async {
        struct Failed: Error {}
        let calls = Mutex<[Data]>([])
        let fails = Mutex(true)
        let writer = DebouncedWriter<Int>(
            fileURL: URL(filePath: "/dev/null"), delay: .milliseconds(10),
            write: { data, _ in
                calls.withLock { $0.append(data) }
                if fails.withLock({ $0 }) { throw Failed() }
            })

        writer.schedule(7)
        await writer.flush()
        #expect(calls.withLock { $0 } == [Data("7".utf8)])

        fails.withLock { $0 = false }
        await writer.flush()
        #expect(calls.withLock { $0 } == [Data("7".utf8), Data("7".utf8)])

        fails.withLock { $0 = true }
        writer.schedule(8)
        await writer.flush()
        fails.withLock { $0 = false }
        writer.schedule(9)
        await writer.flush()
        #expect(calls.withLock { $0.suffix(2) } == [Data("8".utf8), Data("9".utf8)])
        await writer.flush()
        #expect(calls.withLock { $0.count } == 4)
    }
}
