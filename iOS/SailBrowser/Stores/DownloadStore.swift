import Foundation
import Observation
import os
import WebKit

nonisolated struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, finished, failed }

    let id: UUID
    let filename: String
    let sourceURL: URL?
    var bytes: Int64
    var total: Int64
    var state: State
    let date: Date
}

// The keys downloads shipped with are required. A key added later decodes with decodeIfPresent and a default, so a
// record saved before it existed still loads.
nonisolated extension DownloadRecord {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        total = try container.decode(Int64.self, forKey: .total)
        state = try container.decode(State.self, forKey: .state)
        date = try container.decode(Date.self, forKey: .date)
    }
}

// Lets a download's progress through to the list at most once per interval: the first sample passes at once, the
// next one books a write for the interval's end, and the rest ride on that write.
nonisolated struct ProgressGate: Sendable {
    enum Verdict: Equatable, Sendable { case now, later(ContinuousClock.Instant), held }

    let interval: Duration
    private var nextWrite: ContinuousClock.Instant?
    private var booked: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    mutating func sample(at now: ContinuousClock.Instant) -> Verdict {
        guard let next = nextWrite, now < next else {
            nextWrite = now + interval
            return .now
        }
        if let booked, now < booked {
            return .held
        }
        booked = next
        nextWrite = next + interval
        return .later(next)
    }
}

// Downloads go to Documents/Downloads, which the Files app shows under On My iPhone. Records are newest first.
@Observable final class DownloadStore: NSObject, WKDownloadDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "downloads")

    let folder: URL
    // Resume data beside downloads.json, one file per failed download, so Retry survives a relaunch.
    let resumeFolder: URL
    private(set) var records: [DownloadRecord]
    // What WebKit hands back on a failure or a cancel, for Retry; mirrored in resumeFolder.
    private var resumeData: [UUID: Data]
    @ObservationIgnored private var running: [UUID: WKDownload] = [:]
    @ObservationIgnored private var ids: [ObjectIdentifier: UUID] = [:]
    // A private download keeps no source and no resume data (a retry would resume on the default store's cookies), and
    // its record lives only in memory; the file itself lands where the user asked.
    @ObservationIgnored private var privateDownloads: Set<ObjectIdentifier> = []
    @ObservationIgnored private var privateRecords: Set<UUID> = []
    @ObservationIgnored private var observations: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private let writer: DebouncedWriter<[DownloadRecord]>
    // WebKit resumes a download only through a web view; this one shares the pool's default data store.
    @ObservationIgnored private lazy var resumer = WKWebView()
    // The system's leave to keep downloading after the app has left the foreground, held while any download runs. At
    // its expiry the running downloads are cancelled, which collects their resume data, so Retry works on return.
    @ObservationIgnored private let assertion: BackgroundAssertion
    @ObservationIgnored private var endAssertion: (@MainActor () -> Void)?
    // The downloads the expiry cut short; they start again on their own at the next foreground.
    @ObservationIgnored private var expired: Set<UUID> = []

    init(directories: AppDirectories, assertion: BackgroundAssertion = .live) {
        self.assertion = assertion
        let folder = directories.documents.appending(path: "Downloads", directoryHint: .isDirectory)
        self.folder = folder
        let resumeFolder = directories.support.appending(path: "downloads", directoryHint: .isDirectory)
        self.resumeFolder = resumeFolder
        let fileURL = directories.support.appending(path: "downloads.json")
        writer = DebouncedWriter(fileURL: fileURL)
        let saved = JSONFile.load([DownloadRecord].self, from: fileURL) ?? []
        let loaded = saved.compactMap { record -> DownloadRecord? in
            switch record.state {
            case .running:
                var failed = record
                failed.state = .failed
                return failed
            case .finished:
                let path = folder.appending(path: record.filename).path(percentEncoded: false)
                return FileManager.default.fileExists(atPath: path) ? record : nil
            case .failed:
                return record
            }
        }
        records = loaded
        resumeData = Self.savedResumeData(in: resumeFolder, for: Set(loaded.compactMap { $0.state == .failed ? $0.id : nil }))
        super.init()
    }

    // The resume data of the failed records given; a file belonging to no such record is stale and goes.
    private static func savedResumeData(in folder: URL, for ids: Set<UUID>) -> [UUID: Data] {
        let path = folder.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        var data: [UUID: Data] = [:]
        do {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                if let id, ids.contains(id), let saved = FileManager.default.contents(atPath: file.path(percentEncoded: false)) {
                    data[id] = saved
                } else {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            logger.error("Could not read the resume data: \(error, privacy: .public)")
        }
        return data
    }

    func fileURL(of record: DownloadRecord) -> URL {
        folder.appending(path: record.filename)
    }

    func canRetry(_ id: UUID) -> Bool {
        resumeData[id] != nil
    }

    func track(_ download: WKDownload, isPrivate: Bool) {
        download.delegate = self
        if isPrivate {
            privateDownloads.insert(ObjectIdentifier(download))
        }
    }

    func cancel(_ id: UUID) {
        running[id]!.cancel { [weak self] data in
            // The file may have finished, or a swipe deleted the row, before WebKit answered.
            guard let self, running[id] != nil else { return }
            failed(id, resumeData: data)
        }
    }

    // The downloads the expiry cut short go on from where they stopped. One whose cancel has not answered yet, or
    // answered with nothing to resume, keeps its row as it is.
    func resumeExpired() {
        let ids = expired
        expired = []
        for id in ids where canRetry(id) {
            retry(id)
        }
    }

    // The resume file stays until the download finishes, so a relaunch mid-resume still offers Retry.
    func retry(_ id: UUID) {
        let data = resumeData.removeValue(forKey: id)!
        let file = fileURL(of: records.first { $0.id == id }!)
        resumer.resumeDownload(fromResumeData: data) { [weak self] download in
            // A swipe may have deleted the row before WebKit answered. The resume has brought the deleted file back by
            // then, so it goes again once the cancel lets go of it, unless a newer record has taken the name.
            guard let self, records.contains(where: { $0.id == id }) else {
                download.cancel { [weak self] _ in
                    guard let self, !records.contains(where: { fileURL(of: $0) == file }) else { return }
                    removeFile(file)
                }
                return
            }
            download.delegate = self
            update(id) { $0.state = .running }
            start(download, as: id)
        }
    }

    func delete(_ id: UUID) {
        if running[id] != nil {
            let download = stop(id)
            // Detached first, so a finish or failure already on its way never reaches a deleted row.
            download.delegate = nil
            download.cancel()
        }
        keepResumeData(nil, for: id)
        removeFile(fileURL(of: records.remove(at: records.firstIndex { $0.id == id }!)))
        save()
    }

    private func removeFile(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Self.logger.error("Could not delete \(file.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    func flush() async {
        await writer.flush()
    }

    // " 2", " 3" and so on go before the extension until the name is free.
    nonisolated static func uniqueName(_ suggested: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(suggested) else { return suggested }
        let name = suggested as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !isTaken(candidate) {
                return candidate
            }
            number += 1
        }
    }

    #if DEBUG
    func insertForTesting(_ added: [DownloadRecord]) {
        records.insert(contentsOf: added.reversed(), at: 0)
        save()
    }
    #endif

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Could not create the downloads folder: \(error, privacy: .public)")
            return nil
        }
        let names = Set(records.map(\.filename))
        let filename = Self.uniqueName(suggestedFilename) { [folder] name in
            names.contains(name) || FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false))
        }
        let isPrivate = privateDownloads.remove(ObjectIdentifier(download)) != nil
        let record = DownloadRecord(
            id: UUID(), filename: filename, sourceURL: isPrivate ? nil : download.originalRequest?.url, bytes: 0,
            total: max(0, response.expectedContentLength), state: .running, date: .now)
        if isPrivate {
            privateRecords.insert(record.id)
        }
        records.insert(record, at: 0)
        save()
        start(download, as: record.id)
        return fileURL(of: record)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ids[ObjectIdentifier(download)]!
        // Progress reaches here on a later turn, so the final count is read from the download.
        let bytes = stop(id).progress.completedUnitCount
        keepResumeData(nil, for: id)
        update(id) {
            // A resume answered with something other than the rest of the file (a 404 page, say) ends short of the
            // total the first response gave: a failure, not the file.
            $0.state = $0.total > bytes ? .failed : .finished
            $0.bytes = bytes
            $0.total = max($0.total, bytes)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        Self.logger.error("Download failed: \(error, privacy: .public)")
        // A download refused a destination has no record; WebKit reports its cancel here all the same.
        guard let id = ids[ObjectIdentifier(download)] else { return }
        failed(id, resumeData: resumeData)
    }

    private func start(_ download: WKDownload, as id: UUID) {
        ids[ObjectIdentifier(download)] = id
        running[id] = download
        if endAssertion == nil {
            endAssertion = assertion.begin("downloads") { [weak self] in self?.expire() }
        }
        // Chunks land hundreds of times a second on a fast file; the gate lets one list write through per interval, and
        // each write reads the count as it stands then.
        let gate = OSAllocatedUnfairLock(initialState: ProgressGate(interval: Theme.Downloads.progressInterval))
        observations[id] = download.progress.observe(\.completedUnitCount) { @Sendable _, _ in
            switch gate.withLock({ $0.sample(at: .now) }) {
            case .now:
                Task { @MainActor [weak self] in self?.progressed(id) }
            case .later(let deadline):
                Task { @MainActor [weak self] in
                    try await Task.sleep(until: deadline)
                    self?.progressed(id)
                }
            case .held:
                break
            }
        }
    }

    private func stop(_ id: UUID) -> WKDownload {
        observations.removeValue(forKey: id)!.invalidate()
        let download = running.removeValue(forKey: id)!
        ids[ObjectIdentifier(download)] = nil
        if running.isEmpty {
            endDownloadAssertion()
        }
        return download
    }

    // The system's leave is up: every running download is cancelled for its resume data and the assertion is let go
    // at once, as the system asks. WebKit's answers land before the app suspends or, at the latest, on its return.
    private func expire() {
        expired = Set(running.keys)
        for id in running.keys {
            cancel(id)
        }
        endDownloadAssertion()
    }

    private func endDownloadAssertion() {
        endAssertion?()
        endAssertion = nil
    }

    private func progressed(_ id: UUID) {
        // Finished, failed or deleted before this turn.
        guard let progress = running[id]?.progress else { return }
        update(id, saving: false) {
            $0.bytes = progress.completedUnitCount
            $0.total = max($0.total, progress.totalUnitCount)
        }
    }

    // A cancel and the failure WebKit may report for it both land here.
    private func failed(_ id: UUID, resumeData data: Data?) {
        let bytes = stop(id).progress.completedUnitCount
        if !privateRecords.contains(id) {
            keepResumeData(data, for: id)
        }
        update(id) {
            $0.state = .failed
            $0.bytes = bytes
        }
    }

    // In memory and on disk alike; nil clears both.
    private func keepResumeData(_ data: Data?, for id: UUID) {
        resumeData[id] = data
        let file = resumeFolder.appending(path: "\(id.uuidString).resume")
        do {
            if let data {
                try FileManager.default.createDirectory(at: resumeFolder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            Self.logger.error("Could not keep the resume data of \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func update(_ id: UUID, saving: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        change(&records[records.firstIndex { $0.id == id }!])
        if saving {
            save()
        }
    }

    private func save() {
        writer.schedule(records.filter { !privateRecords.contains($0.id) })
    }
}
