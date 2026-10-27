import Foundation

final class DebouncedWriter<Value: Encodable & Sendable> {
    private let fileURL: URL
    private let delay: Duration
    private let write: @Sendable (Data, URL) async throws -> Void
    private var pending: Value?
    private var timer: Task<Void, Error>?
    private var inFlight: Task<Void, Never>?

    init(
        fileURL: URL, delay: Duration = .milliseconds(500),
        write: @escaping @Sendable (Data, URL) async throws -> Void = { try await JSONFile.write($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.delay = delay
        self.write = write
    }

    // A value scheduled and not yet written.
    var isPending: Bool {
        pending != nil
    }

    func schedule(_ value: Value) {
        pending = value
        timer?.cancel()
        timer = Task {
            try await Task.sleep(for: delay)
            await writePending()
        }
    }

    func flush() async {
        timer?.cancel()
        timer = nil
        await writePending()
        await inFlight?.value
    }

    // A failed write leaves its value pending for the next schedule or flush; a value scheduled meanwhile wins.
    private func writePending() async {
        guard let value = pending else { return }
        pending = nil
        let previous = inFlight
        let task = Task { [fileURL, write] in
            await previous?.value
            do {
                let data = try await Self.encode(value)
                try await write(data, fileURL)
            } catch {
                JSONFile.logger.error("Write failed for \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                if self.pending == nil {
                    self.pending = value
                }
            }
        }
        inFlight = task
        await task.value
    }

    @concurrent private static func encode(_ value: Value) async throws -> Data {
        try JSONEncoder().encode(value)
    }
}
