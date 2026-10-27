import Foundation
import Testing
import UIKit
@testable import SailBrowser

struct SnapshotStoreTests {
    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
    }

    @Test func trimDropsFullImagesKeepsSmall() async throws {
        let store = SnapshotStore(directories: .temporary())
        let kept = UUID()
        let dropped = UUID()
        store.store(image(.red), for: kept)
        store.store(image(.blue), for: dropped)
        #expect(store.thumbnail(for: kept).image != nil)
        #expect(store.thumbnail(for: dropped) === store.thumbnail(for: dropped))
        try await waitUntil { store.thumbnail(for: kept).small != nil && store.thumbnail(for: dropped).small != nil }

        store.trim(keeping: [kept])

        #expect(store.thumbnail(for: kept).image != nil)
        #expect(store.thumbnail(for: dropped).image == nil)
        #expect(store.thumbnail(for: dropped).small != nil)
    }

    @Test func preloadDecodesStoredFiles() async throws {
        let directories = AppDirectories.temporary()
        let id = UUID()
        let file = directories.caches.appending(path: "snapshots/\(id.uuidString).jpg")
        let writer = SnapshotStore(directories: directories)
        writer.store(image(.green), for: id)
        try await waitUntil { FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) }

        let reader = SnapshotStore(directories: directories)
        reader.preload([id, UUID()])
        try await waitUntil { reader.thumbnail(for: id).image != nil && reader.thumbnail(for: id).small != nil }
    }

    // Beyond the spare, the least recently stored picture loses its full image and keeps its small one; a retained id
    // is never the one to go.
    @Test func aStoreEvictsTheLeastRecentBeyondTheSpare() async throws {
        let spare = Theme.Snapshot.spareDecoded
        for retainFirstTwo in [false, true] {
            let store = SnapshotStore(directories: .temporary())
            let retained = retainFirstTwo ? 2 : 0
            let ids = (0..<(spare + 2 + retained)).map { _ in UUID() }
            store.retain(Array(ids.prefix(retained)))
            for id in ids {
                store.store(image(.red), for: id)
            }
            #expect(store.decodedCount == spare + retained)
            let gone = Array(ids[retained..<(retained + 2)])
            for id in gone {
                #expect(store.thumbnail(for: id).image == nil)
            }
            try await waitUntil { gone.allSatisfy { store.thumbnail(for: $0).small != nil } }
            for id in ids where !gone.contains(id) {
                #expect(store.thumbnail(for: id).image != nil)
            }
        }
    }

    // A read of a decoded picture moves it to the back of the line, and leaving the retained set joins the back.
    @Test func readsAndRetainOrderTheLine() async throws {
        let store = SnapshotStore(directories: .temporary())
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID(), g = UUID(), h = UUID()
        for id in [a, b, c, d, e] {
            store.store(image(.red), for: id)
        }
        _ = store.thumbnail(for: a)
        store.store(image(.blue), for: f)
        store.store(image(.blue), for: g)
        #expect(store.thumbnail(for: b).image == nil)
        #expect(store.thumbnail(for: c).image == nil)
        #expect(store.thumbnail(for: a).image != nil)
        store.retain([b])
        #expect(store.thumbnail(for: b).image == nil)
        store.retain([a])
        store.retain([])
        store.store(image(.green), for: h)
        #expect(store.thumbnail(for: d).image == nil)
        #expect(store.thumbnail(for: a).image != nil)
        #expect(store.decodedCount == Theme.Snapshot.spareDecoded)
    }

    // Pictures leaving the retained set drain in the order they were named, not in hash order.
    @Test func releasedPicturesDrainInTheOrderTheyWereRetained() {
        let store = SnapshotStore(directories: .temporary())
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] {
            store.store(image(.red), for: id)
        }
        store.retain([a, b, c])
        store.retain([])
        for _ in 0..<(Theme.Snapshot.spareDecoded - 1) {
            store.store(image(.blue), for: UUID())
        }
        #expect(store.thumbnail(for: a).image == nil)
        #expect(store.thumbnail(for: b).image == nil)
        #expect(store.thumbnail(for: c).image != nil)
    }

    // A preload landing touches the line but never evicts: a deck drag preloads every card it builds.
    @Test func aPreloadLandingNeverEvicts() async throws {
        let directories = AppDirectories.temporary()
        let spare = Theme.Snapshot.spareDecoded
        let reader = SnapshotStore(directories: directories)
        for _ in 0..<spare {
            reader.store(image(.red), for: UUID())
        }
        let writer = SnapshotStore(directories: directories)
        let x = UUID(), y = UUID()
        writer.store(image(.blue), for: x)
        writer.store(image(.green), for: y)
        await writer.flush()
        reader.preload([x, y])
        try await waitUntil { reader.thumbnail(for: x).image != nil && reader.thumbnail(for: y).image != nil }
        #expect(reader.decodedCount == spare + 2)
        reader.store(image(.red), for: UUID())
        #expect(reader.decodedCount == spare)
    }

    // A preload landing for a tab removed meanwhile leaves the line alone, so a later store's trim finds every id in
    // the line with a thumbnail. The folder is read-only across the removal, so its delete fails and the decode still
    // finds the file, as a decode that opened the file before the delete does.
    @Test func aPreloadLandingAfterARemovalIsForgotten() async throws {
        let directories = AppDirectories.temporary()
        let writer = SnapshotStore(directories: directories)
        let x = UUID()
        writer.store(image(.blue), for: x)
        await writer.flush()
        let folder = directories.caches.appending(path: "snapshots").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        let reader = SnapshotStore(directories: directories)
        reader.preload([x])
        let orphan = reader.thumbnail(for: x)
        reader.remove(x)
        try await waitUntil { orphan.image != nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        for _ in 0..<(Theme.Snapshot.spareDecoded + 1) {
            reader.store(image(.red), for: UUID())
        }
        #expect(reader.decodedCount == Theme.Snapshot.spareDecoded)
    }

    @Test func flushWaitsForTheQueuedWrite() async throws {
        let directories = AppDirectories.temporary()
        let store = SnapshotStore(directories: directories)
        let id = UUID()
        store.store(image(.red), for: id)
        await store.flush()
        let file = directories.caches.appending(path: "snapshots/\(id.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(store.thumbnail(for: id).small != nil)
    }

    // A held picture is shown from memory and never written, even after a later stored one has landed.
    @Test func aHeldPictureNeverReachesDisk() async throws {
        let directories = AppDirectories.temporary()
        let store = SnapshotStore(directories: directories)
        let held = UUID(), stored = UUID()
        store.hold(image(.red), for: held)
        store.store(image(.blue), for: stored)
        #expect(store.thumbnail(for: held).image != nil)
        let folder = directories.caches.appending(path: "snapshots")
        try await waitUntil {
            FileManager.default.fileExists(atPath: folder.appending(path: "\(stored.uuidString).jpg").path(percentEncoded: false))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["\(stored.uuidString).jpg"])
    }
}
