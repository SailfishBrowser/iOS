import Foundation
import UIKit

@Observable
final class Thumbnail {
    var image: UIImage?
    var small: UIImage?
}

final class SnapshotStore {
    nonisolated private struct EncodingFailed: Error {}

    nonisolated private static let smallSize = CGSize(width: 66, height: 90)
    nonisolated private static let jpegQuality: CGFloat = 0.7

    private let folder: URL
    private var thumbnails: [Tab.ID: Thumbnail] = [:]
    private var lastOperation: Task<Void, Never>?
    // Full pictures that stay decoded whatever else is stored: the active tab, its deck neighbours and the previous
    // tab. The rest of the decoded full pictures stand in a line, least recent first, that a capture landing trims to
    // Theme.Snapshot.spareDecoded; a preload landing joins the line but never trims it, so a deck drag can build
    // every card it wants.
    private var retained: [Tab.ID] = []
    private var recent: [Tab.ID] = []

    init(directories: AppDirectories) {
        folder = directories.caches.appending(path: "snapshots")
    }

    var decodedCount: Int {
        thumbnails.values.count { $0.image != nil }
    }

    // A read of a decoded picture keeps it recent: a drawn card is never the one to go.
    func thumbnail(for id: Tab.ID) -> Thumbnail {
        if let thumbnail = thumbnails[id] {
            if thumbnail.image != nil {
                touch(id)
            }
            return thumbnail
        }
        let thumbnail = Thumbnail()
        thumbnails[id] = thumbnail
        return thumbnail
    }

    func store(_ image: UIImage, for id: Tab.ID) {
        let thumbnail = thumbnail(for: id)
        thumbnail.image = image
        touch(id)
        enforceBudget()
        let url = fileURL(id)
        enqueue {
            thumbnail.small = await image.byPreparingThumbnail(ofSize: Self.smallSize)
            try await Self.writeJPEG(image, to: url)
        }
    }

    // A private tab's picture: shown from memory, never written, gone with its tab or a trim.
    func hold(_ image: UIImage, for id: Tab.ID) {
        thumbnail(for: id).image = image
        touch(id)
        enforceBudget()
    }

    func remove(_ id: Tab.ID) {
        thumbnails[id] = nil
        retained.removeAll { $0 == id }
        recent.removeAll { $0 == id }
        let url = fileURL(id)
        enqueue { try await Self.delete(url) }
    }

    func preload(_ ids: [Tab.ID]) {
        for id in ids where thumbnail(for: id).image == nil {
            let thumbnail = thumbnail(for: id)
            let url = fileURL(id)
            // A landing for a tab removed meanwhile touches nothing: its id would stand in the line with no
            // thumbnail for the budget to trim.
            Task { [weak self] in
                guard let decoded = await Self.decode(url), thumbnail.image == nil else { return }
                thumbnail.image = decoded.image
                thumbnail.small = decoded.small
                guard let self, thumbnails[id] === thumbnail else { return }
                touch(id)
            }
        }
    }

    // Ids entering the set leave the line; ids leaving it that still have a picture join the back in the order they
    // were named, so they drain one at a time. Nothing is decoded or trimmed here.
    func retain(_ ids: [Tab.ID]) {
        let released = retained.filter { !ids.contains($0) }
        retained = ids
        recent.removeAll { ids.contains($0) }
        for id in released where thumbnails[id]?.image != nil {
            recent.append(id)
        }
    }

    func trim(keeping ids: Set<Tab.ID>) {
        for (id, thumbnail) in thumbnails where !ids.contains(id) {
            thumbnail.image = nil
        }
        recent.removeAll { !ids.contains($0) }
    }

    func flush() async {
        await lastOperation?.value
    }

    private func touch(_ id: Tab.ID) {
        guard !retained.contains(id) else { return }
        recent.removeAll { $0 == id }
        recent.append(id)
    }

    private func enforceBudget() {
        while recent.count > Theme.Snapshot.spareDecoded {
            thumbnails[recent.removeFirst()]!.image = nil
        }
    }

    private func fileURL(_ id: Tab.ID) -> URL {
        folder.appending(path: "\(id.uuidString).jpg")
    }

    private func enqueue(_ operation: @escaping () async throws -> Void) {
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            do {
                try await operation()
            } catch {
                JSONFile.logger.error("Snapshot file operation failed: \(error, privacy: .public)")
            }
        }
    }

    @concurrent private static func writeJPEG(_ image: UIImage, to url: URL) async throws {
        guard let data = image.jpegData(compressionQuality: jpegQuality) else { throw EncodingFailed() }
        try await JSONFile.write(data, to: url)
    }

    @concurrent private static func decode(_ url: URL) async -> (image: UIImage, small: UIImage?)? {
        guard let file = UIImage(contentsOfFile: url.path(percentEncoded: false)),
            let image = await file.byPreparingForDisplay()
        else { return nil }
        return (image, await file.byPreparingThumbnail(ofSize: smallSize))
    }

    @concurrent private static func delete(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
