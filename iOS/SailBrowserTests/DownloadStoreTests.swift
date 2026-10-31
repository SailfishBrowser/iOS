import Foundation
import Testing
@testable import SailBrowser

struct DownloadStoreTests {
    // The files beside downloads.json, by name.
    private func resumeFiles(_ directories: AppDirectories) -> Set<String> {
        let folder = directories.support.appending(path: "downloads")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
    }

    // A download running at exit with no resume data cannot resume after it, and a finished one whose file was deleted in
    // Files is gone.
    @Test func recordsSurviveAReloadFromDisk() async throws {
        let directories = AppDirectories.temporary()
        let store = DownloadStore(directories: directories)
        let source = URL(string: "https://example.test/a.zip")!
        let finished = DownloadRecord(
            id: UUID(), filename: "a.zip", sourceURL: source, bytes: 3, total: 3, state: .finished,
            date: Date(timeIntervalSince1970: 3))
        let running = DownloadRecord(
            id: UUID(), filename: "b.zip", sourceURL: source, bytes: 1, total: 9, state: .running,
            date: Date(timeIntervalSince1970: 2))
        let missing = DownloadRecord(
            id: UUID(), filename: "gone.zip", sourceURL: source, bytes: 3, total: 3, state: .finished,
            date: Date(timeIntervalSince1970: 1))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: store.fileURL(of: finished))
        store.insertForTesting([missing, running, finished])
        await store.flush()

        let reloaded = DownloadStore(directories: directories)

        var failed = running
        failed.state = .failed
        #expect(reloaded.records == [finished, failed])
        #expect(!reloaded.canRetry(running.id))
    }

    @Test func clashingNamesNumberBeforeTheExtension() {
        let taken: Set<String> = ["a.zip", "a 2.zip", "notes", "archive.tar.gz"]
        #expect(DownloadStore.uniqueName("a.zip") { taken.contains($0) } == "a 3.zip")
        #expect(DownloadStore.uniqueName("b.zip") { taken.contains($0) } == "b.zip")
        #expect(DownloadStore.uniqueName("notes") { taken.contains($0) } == "notes 2")
        #expect(DownloadStore.uniqueName("archive.tar.gz") { taken.contains($0) } == "archive.tar 2.gz")
        // A dotfile has no extension to number before.
        #expect(DownloadStore.uniqueName(".bashrc") { $0 == ".bashrc" } == ".bashrc 2")
        let crowded = Set(["a.zip"] + (2...1000).map { "a \($0).zip" })
        #expect(DownloadStore.uniqueName("a.zip") { crowded.contains($0) } == "a 1001.zip")
    }

    // 500 samples in 50 ms: the first passes, the second books the interval's end, the rest ride on it. A sample after a
    // booked write books the next end; one after a quiet spell passes at once.
    @Test func theGateLetsOneWriteThroughPerInterval() {
        var gate = ProgressGate(interval: .milliseconds(100))
        let start = ContinuousClock.Instant.now
        let verdicts = (0..<500).map { gate.sample(at: start + .microseconds(100 * $0)) }

        #expect(verdicts.first == .now)
        #expect(verdicts[1] == .later(start + .milliseconds(100)))
        #expect(verdicts.dropFirst(2).allSatisfy { $0 == .held })
        #expect(gate.sample(at: start + .milliseconds(105)) == .later(start + .milliseconds(200)))
        #expect(gate.sample(at: start + .milliseconds(150)) == .held)
        #expect(gate.sample(at: start + .milliseconds(700)) == .now)
        #expect(gate.sample(at: start + .milliseconds(701)) == .later(start + .milliseconds(800)))
    }

    // At launch a running record with resume data becomes a failed one with Retry, a failed one keeps its Retry, and a
    // resume file with no failed record goes.
    @Test func resumeFilesAreReadAtLaunchAndOrphansRemoved() async throws {
        let directories = AppDirectories.temporary()
        let store = DownloadStore(directories: directories)
        let source = URL(string: "https://example.test/a.zip")!
        let running = DownloadRecord(
            id: UUID(), filename: "a.zip", sourceURL: source, bytes: 1, total: 9, state: .running,
            date: Date(timeIntervalSince1970: 3))
        let failed = DownloadRecord(
            id: UUID(), filename: "b.zip", sourceURL: source, bytes: 2, total: 9, state: .failed,
            date: Date(timeIntervalSince1970: 2))
        let finished = DownloadRecord(
            id: UUID(), filename: "c.zip", sourceURL: source, bytes: 3, total: 3, state: .finished,
            date: Date(timeIntervalSince1970: 1))
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: store.fileURL(of: finished))
        store.insertForTesting([finished, failed, running])
        await store.flush()
        let folder = directories.support.appending(path: "downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in [running.id, failed.id, finished.id, UUID()] {
            try Data("resume".utf8).write(to: folder.appending(path: "\(id.uuidString).resume"))
        }

        let relaunched = DownloadStore(directories: directories)

        var demoted = running
        demoted.state = .failed
        #expect(relaunched.records == [demoted, failed, finished])
        #expect(relaunched.canRetry(running.id))
        #expect(relaunched.canRetry(failed.id))
        #expect(!relaunched.canRetry(finished.id))
        #expect(resumeFiles(directories) == ["\(running.id.uuidString).resume", "\(failed.id.uuidString).resume"])
    }
}
