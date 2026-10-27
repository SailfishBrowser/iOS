import Foundation
import Testing
import WebKit
@testable import SailBrowser

// Downloads mid-transfer: resume data that survives a relaunch, a retry that fails again, a delete that races the
// retry, and progress that reaches the list once per interval.
@Suite(.serialized)
struct DownloadResilienceTests {
    private static let body = Data((0..<2_097_152).map { UInt8($0 % 251) })
    // Small enough to be on disk before the stall; the rest comes with the resume.
    private static let partial = 65_536

    // The files beside downloads.json, by name.
    private func resumeFiles(_ directories: AppDirectories) -> Set<String> {
        let folder = directories.support.appending(path: "downloads")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
    }

    // A download of the stalling attachment, cancelled once some of it is on disk.
    private func cancelled(
        _ env: AppEnvironment, _ server: LocalPageServer, isPrivate: Bool = false
    ) async throws -> DownloadRecord {
        server.routes["/b.zip"] = LocalPageServer.resumable(Self.body, named: "b.zip", stallingAfter: Self.partial)
        env.open(server.url("/b.zip"), isPrivate: isPrivate)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.bytes ?? 0 > 0 }
        let id = try #require(env.downloads.records.first?.id)
        env.downloads.cancel(id)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .failed }
        return try #require(env.downloads.records.first)
    }

    // Like waitUntil, but a timeout records the records and the requests with the failure.
    private func wait(
        for what: String, _ store: DownloadStore, _ server: LocalPageServer, _ condition: () -> Bool
    ) async {
        do {
            try await waitUntil(timeout: .seconds(10), condition)
        } catch {
            Issue.record("\(what): records \(store.records), requests \(server.requestedPaths)")
        }
    }

    // Cancelled, then the app relaunched: the new store finds the resume data beside downloads.json, and Retry asks the
    // server for the rest and finishes the same file.
    @Test func resumeDataSurvivesARelaunch() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        let record = try await cancelled(env, server)
        #expect(env.downloads.canRetry(record.id))
        await env.downloads.flush()
        #expect(resumeFiles(directories) == ["\(record.id.uuidString).resume"])
        let resumable = server.routes["/b.zip"]!
        var requests: [String] = []
        server.routes["/b.zip"] = { request in
            requests.append(request)
            return resumable(request)
        }

        let relaunched = DownloadStore(directories: directories)
        #expect(relaunched.records.map(\.id) == [record.id])
        #expect(relaunched.canRetry(record.id))
        relaunched.retry(record.id)
        await wait(for: "finish after the relaunch", relaunched, server) { relaunched.records.first?.state == .finished }

        #expect(!relaunched.canRetry(record.id))
        #expect(resumeFiles(directories).isEmpty)
        #expect(requests.count == 1)
        #expect(requests.first?.contains("Range: bytes=") == true)
        let file = relaunched.folder.appending(path: "b.zip")
        #expect(FileManager.default.contents(atPath: file.path(percentEncoded: false)) == Self.body)
    }

    // A private download keeps no source and writes no resume data, so a relaunch has nothing of it to retry.
    @Test func aPrivateDownloadWritesNoResumeData() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        let record = try await cancelled(env, server, isPrivate: true)

        #expect(record.sourceURL == nil)
        #expect(!env.downloads.canRetry(record.id))
        await env.downloads.flush()
        #expect(resumeFiles(directories).isEmpty)
        let relaunched = DownloadStore(directories: directories)
        #expect(relaunched.records.isEmpty)
        #expect(!relaunched.canRetry(record.id))
    }

    // Deleted between Retry and WebKit's answer: the answer is cancelled and leaves no record, file or resume data.
    @Test func deleteWhileARetryIsPendingWritesNothing() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        let record = try await cancelled(env, server)

        env.downloads.retry(record.id)
        env.downloads.delete(record.id)
        #expect(env.downloads.records.isEmpty)
        // WebKit's answer to the resume has nothing to tell the store, so this waits it out.
        try await Task.sleep(for: .milliseconds(500))

        #expect(env.downloads.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)))
        #expect(resumeFiles(directories).isEmpty)
    }

    // The server has lost the file by the time of Retry: WebKit saves the 404 page as the rest and calls it finished, so
    // a resume that ends short of the first response's total is failed, with Retry following what WebKit hands back.
    @Test func aRetryAgainstAGoneFileFailsAgain() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        let record = try await cancelled(env, server)
        server.routes["/b.zip"] = { _ in
            LocalPageServer.Reply(status: "404 Not Found", headers: ["Content-Type": "text/plain"], body: Data("gone".utf8))
        }

        env.downloads.retry(record.id)
        await wait(for: "the second request", env.downloads, server) { server.requestedPaths.count == 2 }
        await wait(for: "the retry's end", env.downloads, server) { env.downloads.records.first?.state != .running }

        #expect(env.downloads.records.first?.state == .failed)
        #expect(env.downloads.records.map(\.id) == [record.id])
        #expect(env.downloads.canRetry(record.id) == resumeFiles(directories).contains("\(record.id.uuidString).resume"))
        #expect(env.downloads.records.first?.total == Int64(Self.body.count))
    }

    // Progress reaches the list once per interval, not once per chunk, and the final count lands with the finish.
    @Test func progressReachesTheListOncePerInterval() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        server.routes["/a.zip"] = { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=a.zip"],
                body: Self.body, pieces: 64, gap: 0.002)
        }
        let writes = Writes { _ = env.downloads.records }
        let start = ContinuousClock.now

        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        let elapsed = ContinuousClock.now - start

        // The insert, the first sample, one per interval and the finish.
        #expect(writes.count <= 3 + Int(elapsed / Theme.Downloads.progressInterval))
        let record = try #require(env.downloads.records.first)
        #expect(record.bytes == Int64(Self.body.count))
        #expect(record.total == Int64(Self.body.count))
    }

    // 500 samples in 50 ms: the first passes, the second books the interval's end, the rest ride on it. A sample after a
    // booked write books the next end; one after a quiet spell passes at once.
    @Test func theGateLetsOneWriteThroughPerInterval() {
        #expect(Theme.Downloads.progressInterval == .milliseconds(100))
        var gate = ProgressGate(interval: Theme.Downloads.progressInterval)
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

// A download whose folder cannot be made gets no destination and no record; WebKit's cancel of it reaches nothing.
@Suite(.serialized)
struct DownloadDestinationTests {
    @Test func aDownloadRefusedADestinationLeavesNoRecord() async throws {
        let temporary = AppDirectories.temporary()
        // Documents is a file, so the Downloads folder cannot be created under it.
        try FileManager.default.createDirectory(at: temporary.support, withIntermediateDirectories: true)
        let blocked = temporary.support.appending(path: "documents")
        try Data().write(to: blocked)
        let env = makeEnvironment(AppDirectories(support: temporary.support, caches: temporary.caches, documents: blocked))
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        defer { withExtendedLifetime(server) {} }
        server.routes["/a.zip"] = { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=a.zip"],
                body: Data("zip".utf8))
        }

        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.haptics.records.contains { $0.interaction == .settingsChange } }
        // The refusal's cancel reports back to the store on a later turn with nothing else to wait on.
        try await Task.sleep(for: .milliseconds(500))

        #expect(env.downloads.records.isEmpty)
    }
}
