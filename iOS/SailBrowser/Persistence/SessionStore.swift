import Foundation

final class SessionStore {
    // The file write, a seam for tests that gate it.
    var write: @Sendable (Data, URL) async throws -> Void = { try await JSONFile.write($0, to: $1) }

    private let folder: URL
    // A saved state stays in memory only until its own write lands; a later load reads the file.
    private var cache: [UUID: Data] = [:]
    private var savedIDs: Set<UUID>
    private var lastOperation: Task<Void, Never>?

    init(directories: AppDirectories) {
        folder = directories.support.appending(path: "sessions")
        savedIDs = Self.savedIDs(in: folder)
    }

    private static func savedIDs(in folder: URL) -> Set<UUID> {
        let path = folder.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: path)
            return Set(files.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
        } catch {
            JSONFile.logger.error("Session folder listing failed: \(error, privacy: .public)")
            return []
        }
    }

    var cachedCount: Int {
        cache.count
    }

    func save(_ data: Data, for id: UUID) {
        cache[id] = data
        savedIDs.insert(id)
        let url = fileURL(id)
        let write = write
        enqueue {
            try await write(data, url)
        } landed: { [weak self] in
            guard let self, cache[id] == data else { return }
            cache[id] = nil
        }
    }

    func flush() async {
        await lastOperation?.value
    }

    func load(_ id: UUID) -> Data? {
        guard savedIDs.contains(id) else { return nil }
        return cache[id] ?? FileManager.default.contents(atPath: fileURL(id).path(percentEncoded: false))
    }

    func remove(_ id: UUID) {
        cache[id] = nil
        savedIDs.remove(id)
        let url = fileURL(id)
        enqueue { try await Self.delete(url) }
    }

    private func fileURL(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).session")
    }

    private func enqueue(
        _ operation: @escaping @Sendable () async throws -> Void, landed: @escaping @MainActor () -> Void = {}
    ) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            do {
                try await operation()
                landed()
            } catch {
                JSONFile.logger.error("Session file operation failed: \(error, privacy: .public)")
            }
        }
    }

    @concurrent private static func delete(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
