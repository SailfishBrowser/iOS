import Foundation
import Testing
@testable import SailBrowser

// A session write that parks until released, counting the writes that landed.
@MainActor final class ParkedWriter {
    private(set) var landed = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var open = false

    var writer: @Sendable (Data, URL) async throws -> Void {
        { [self] data, url in
            await park()
            try await JSONFile.write(data, to: url)
            await land()
        }
    }

    func release() {
        open = true
        gates.forEach { $0.resume() }
        gates = []
    }

    private func park() async {
        guard !open else { return }
        await withCheckedContinuation { gates.append($0) }
    }

    private func land() {
        landed += 1
    }
}

struct SessionStoreTests {
    // The cache holds a state only until its own write lands; a newer save for the id keeps its entry, and flush
    // returns only once the parked writes are through.
    @Test func aNewerSaveKeepsItsEntryUntilItLands() async throws {
        let directories = AppDirectories.temporary()
        let store = SessionStore(directories: directories)
        let gate = ParkedWriter()
        store.write = gate.writer
        let id = UUID()
        store.save(Data("a".utf8), for: id)
        store.save(Data("b".utf8), for: id)
        #expect(store.load(id) == Data("b".utf8))
        #expect(store.cachedCount == 1)
        gate.release()
        await store.flush()
        #expect(gate.landed == 2)
        #expect(store.cachedCount == 0)
        #expect(store.load(id) == Data("b".utf8))
    }

    @Test func aLandedSaveIsReadFromDiskNotMemory() async throws {
        let directories = AppDirectories.temporary()
        let store = SessionStore(directories: directories)
        let id = UUID()
        store.save(Data("state".utf8), for: id)
        await store.flush()
        let file = directories.support.appending(path: "sessions/\(id.uuidString).session")
        try FileManager.default.removeItem(at: file)
        #expect(store.load(id) == nil)
    }

    @Test func savedSessionsSurviveARelaunchAndUnknownIDsNeverReadDisk() async throws {
        let directories = AppDirectories.temporary()
        let saved = UUID()
        let folder = directories.support.appending(path: "sessions")
        SessionStore(directories: directories).save(Data("state".utf8), for: saved)
        try await waitUntil {
            FileManager.default.fileExists(atPath: folder.appending(path: "\(saved.uuidString).session").path(percentEncoded: false))
        }

        let relaunched = SessionStore(directories: directories)
        #expect(relaunched.load(saved) == Data("state".utf8))

        let fresh = UUID()
        try Data("stray".utf8).write(to: folder.appending(path: "\(fresh.uuidString).session"))
        #expect(relaunched.load(fresh) == nil)
    }
}
