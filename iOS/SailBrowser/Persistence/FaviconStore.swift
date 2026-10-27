import Foundation
import UIKit

@Observable
final class FaviconBox {
    // The site's colour for the page menu, worked out once per image: off the main actor where the file is decoded,
    // on it for an icon set directly.
    private var icon: (image: UIImage?, tint: UIColor?) = (nil, nil)

    var image: UIImage? {
        get { icon.image }
        set { icon = (newValue, newValue.flatMap(FaviconTint.dominant)) }
    }

    var tint: UIColor? {
        icon.tint
    }

    func set(image: UIImage, tint: UIColor?) {
        icon = (image, tint)
    }
}

final class FaviconStore {
    nonisolated private struct UndecodableIcon: Error {}
    nonisolated private struct OversizedIcon: Error {}
    nonisolated private static let maxPixels: CGFloat = 64
    nonisolated static let maxBytes = 512 * 1024
    nonisolated private static let schemes: Set<String> = ["http", "https"]

    // One fetch per URL however many hosts ask for it: a later caller joins the running task, and each host writes
    // its own PNG.
    private var downloads: [URL: Task<(image: UIImage, tint: UIColor?, png: Data), Error>] = [:]
    #if DEBUG
    private(set) var joins = 0
    #endif
    private let folder: URL
    let session: URLSession
    // The energy policy's hook; false keeps icons disk only.
    var allowsNetwork: () -> Bool = { true }
    private var boxes: [String: FaviconBox] = [:]
    // The hosts whose icon set was fetched or found fresh on disk this launch.
    private(set) var loaded: [String: [URL]] = [:]

    // Cookie free, off in Low Data Mode, failing fast: a finish-time fetch is fire-and-forget and the next finish
    // retries. Bounded so a stalled icon server cannot hold a task for days.
    nonisolated static func configuration() -> URLSessionConfiguration {
        SessionConfiguration.cookieless(
            requestTimeout: Theme.Network.faviconTimeout, resourceTimeout: Theme.Network.faviconResourceTimeout)
    }

    init(directories: AppDirectories, session: URLSession = URLSession(configuration: FaviconStore.configuration())) {
        folder = directories.caches.appending(path: "favicons")
        self.session = session
    }

    func favicon(for host: String) -> FaviconBox {
        if let box = boxes[host] {
            return box
        }
        let box = FaviconBox()
        boxes[host] = box
        let url = fileURL(host)
        Task {
            if let icon = await Self.read(url), box.image == nil {
                box.set(image: icon.image, tint: icon.tint)
            }
        }
        return box
    }

    var cachedCount: Int {
        boxes.count
    }

    // Every host seen, with no cap: a cap would make archive rows flicker on the globe as hosts scroll back in. A memory
    // warning releases the map; a view still holding a box keeps its icon, and the next favicon(for:) makes a fresh box
    // that reads the disk: a globe for one disk read, on a memory warning only.
    func releaseCache() {
        boxes = [:]
    }

    // The icon at a URL, downscaled with its tint worked out off the main actor, fetched once for every caller that
    // asks while it is in flight.
    func download(_ url: URL) async throws -> (image: UIImage, tint: UIColor?, png: Data) {
        if let running = downloads[url] {
            #if DEBUG
            joins += 1
            #endif
            return try await running.value
        }
        let task = Task { [session] in
            defer { self.downloads[url] = nil }
            return try await Self.fetch(url, with: session)
        }
        downloads[url] = task
        return try await task.value
    }

    // Takes the first icon that loads and decodes, so an SVG or a dead link gives way to the next.
    func update(host: String, iconURLs: [URL]) {
        let candidates = iconURLs.filter { $0.scheme.map { Self.schemes.contains($0.lowercased()) } ?? false }
        guard !candidates.isEmpty else { return }
        let box = favicon(for: host)
        if loaded[host] == candidates { return }
        let url = fileURL(host)
        // Weak: the environment's hooks (allowsNetwork) assume the store never outlives it, so work that resumes after
        // the store is gone ends here.
        Task { [weak self] in
            // On the host's first finish this launch a cached icon younger than faviconFresh is the icon, and the box
            // fills from disk if it has not already; a changed icon set within the launch still fetches.
            if self?.loaded[host] == nil, await Self.isFresh(url) {
                self?.loaded[host] = candidates
                if box.image == nil, let icon = await Self.read(url) {
                    box.set(image: icon.image, tint: icon.tint)
                }
                return
            }
            guard let self, allowsNetwork() else { return }
            for iconURL in candidates {
                let icon: (image: UIImage, tint: UIColor?, png: Data)
                do {
                    icon = try await download(iconURL)
                } catch let error as URLError where error.networkUnavailableReason != nil {
                    // A constrained path fails every candidate the same way.
                    JSONFile.logger.info("Favicon for \(host, privacy: .public) waits for the network: \(error, privacy: .public)")
                    return
                } catch {
                    JSONFile.logger.error(
                        "Favicon \(iconURL, privacy: .public) failed for \(host, privacy: .public): \(error, privacy: .public)")
                    continue
                }
                box.set(image: icon.image, tint: icon.tint)
                loaded[host] = candidates
                do {
                    try await JSONFile.write(icon.png, to: url)
                } catch {
                    JSONFile.logger.error("Favicon write failed for \(host, privacy: .public): \(error, privacy: .public)")
                }
                return
            }
        }
    }

    func clear() async {
        boxes = [:]
        loaded = [:]
        do {
            try await Self.delete(folder)
        } catch {
            JSONFile.logger.error("Favicon cache removal failed: \(error, privacy: .public)")
        }
    }

    private func fileURL(_ host: String) -> URL {
        folder.appending(path: "\(host).png")
    }

    @concurrent private static func read(_ url: URL) async -> (image: UIImage, tint: UIColor?)? {
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        return (image, FaviconTint.dominant(in: image))
    }

    @concurrent private static func isFresh(_ url: URL) async -> Bool {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            guard let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
                return false
            }
            return Date.now.timeIntervalSince(modified) < Theme.Network.faviconFresh
        } catch {
            JSONFile.logger.error("Favicon age check failed: \(error, privacy: .public)")
            return false
        }
    }

    @concurrent private static func delete(_ folder: URL) async throws {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    @concurrent private static func load(_ url: URL, with session: URLSession) async throws -> Data {
        let (bytes, _) = try await session.bytes(from: url)
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw OversizedIcon() }
            data.append(byte)
        }
        return data
    }

    @concurrent private static func downscale(_ data: Data) async throws -> (image: UIImage, png: Data) {
        guard let source = UIImage(data: data) else { throw UndecodableIcon() }
        let pixels = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        let factor = min(1, maxPixels / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = image.pngData() else { throw UndecodableIcon() }
        return (image, png)
    }

    @concurrent private static func fetch(
        _ url: URL, with session: URLSession
    ) async throws -> (image: UIImage, tint: UIColor?, png: Data) {
        let icon = try await downscale(load(url, with: session))
        return (icon.image, FaviconTint.dominant(in: icon.image), icon.png)
    }
}
