import CoreGraphics
import Foundation
import Synchronization
import Testing
import UIKit
@testable import SailBrowser

nonisolated final class StubIconProtocol: URLProtocol {
    // A parked load, carried through the mutex until release(_:) starts it again.
    nonisolated private struct Held: @unchecked Sendable {
        let load: StubIconProtocol
    }

    private static let bodies = Mutex<[URL: Data]>([:])
    // Loads of a parked URL are held, uncounted, until release(_:) starts them again.
    private static let parked = Mutex<[URL: [Held]]>([:])
    private static let requests = Mutex<[URL]>([])
    private static let failures = Mutex<[URL: URLError]>([:])

    static func answer(_ url: URL, with body: Data) {
        bodies.withLock { $0[url] = body }
    }

    static func fail(_ url: URL, with error: URLError) {
        failures.withLock { $0[url] = error }
    }

    static var requested: [URL] {
        requests.withLock { $0 }
    }

    static func park(_ url: URL) {
        parked.withLock { $0[url] = [] }
    }

    static func release(_ url: URL) {
        for held in parked.withLock({ $0.removeValue(forKey: url) }) ?? [] {
            held.load.startLoading()
        }
    }

    static func session() -> URLSession {
        let configuration = FaviconStore.configuration()
        configuration.protocolClasses = [StubIconProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if Self.parked.withLock({ $0[url]?.append(Held(load: self)) != nil }) { return }
        Self.requests.withLock { $0.append(url) }
        if let error = Self.failures.withLock({ $0[url] }) {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let body = Self.bodies.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct FaviconStoreTests {
    private func host() -> String {
        "icons-\(UUID().uuidString.lowercased()).test"
    }

    private func png(side: Int) -> Data {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }

    private func noisyPNG(side: Int) -> Data {
        let bytes = (0..<side * side * 4).map { _ in UInt8.random(in: .min ... .max) }
        let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        return UIImage(cgImage: image).pngData()!
    }

    @Test func fetchesOnceUntilTheIconURLChanges() async throws {
        let host = host()
        let first = URL(string: "https://\(host)/a.png")!
        let second = URL(string: "https://\(host)/b.png")!
        StubIconProtocol.answer(first, with: png(side: 10))
        StubIconProtocol.answer(second, with: png(side: 20))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let box = store.favicon(for: host)

        store.update(host: host, iconURLs: [first])
        try await waitUntil { box.image?.size.width == 10 }
        store.update(host: host, iconURLs: [first])
        store.update(host: host, iconURLs: [second])
        try await waitUntil { box.image?.size.width == 20 }

        #expect(StubIconProtocol.requested.filter { $0.host() == host } == [first, second])
    }

    // Hacker News offers only an SVG, which does not decode; its /favicon.ico does.
    @Test func anIconThatDoesNotDecodeGivesWayToTheNext() async throws {
        let host = host()
        let svg = URL(string: "https://\(host)/y18.svg")!
        let ico = URL(string: "https://\(host)/favicon.ico")!
        StubIconProtocol.answer(svg, with: Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8))
        StubIconProtocol.answer(ico, with: png(side: 10))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let box = store.favicon(for: host)

        store.update(host: host, iconURLs: [svg, ico])
        try await waitUntil { box.image?.size.width == 10 }
        store.update(host: host, iconURLs: [svg, ico])
        try await Task.sleep(for: .milliseconds(200))

        #expect(StubIconProtocol.requested.filter { $0.host() == host } == [svg, ico])
    }

    @Test func refetchesWhileTheBoxIsEmpty() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: Data("not an image".utf8))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())

        store.update(host: host, iconURLs: [url])
        try await waitUntil { StubIconProtocol.requested.filter { $0 == url }.count == 1 }
        store.update(host: host, iconURLs: [url])
        try await waitUntil { StubIconProtocol.requested.filter { $0 == url }.count == 2 }
    }

    @Test func ignoresNonHTTPIconURLs() async throws {
        let host = host()
        let good = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(good, with: png(side: 10))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())

        for bad in ["data:image/png;base64,iVBORw0KGgo=", "file:///etc/hosts", "javascript:void(0)", "ftp://\(host)/icon.png"] {
            store.update(host: host, iconURLs: [URL(string: bad)!])
        }
        store.update(host: host, iconURLs: [good])
        try await waitUntil { store.favicon(for: host).image != nil }

        #expect(StubIconProtocol.requested.filter { $0.host() == host || $0.scheme != "https" } == [good])
    }

    // A warning empties the map and nothing else: a held box keeps its icon, and the host's next box reads the disk.
    @Test func releaseCacheEmptiesTheMapAndKeepsHeldBoxes() async throws {
        let directories = AppDirectories.temporary()
        let hosts = [host(), host(), host()]
        let folder = directories.caches.appending(path: "favicons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png(side: 10).write(to: folder.appending(path: "\(hosts[0]).png"))
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())
        let held = store.favicon(for: hosts[0])
        for host in hosts.dropFirst() {
            _ = store.favicon(for: host)
        }
        #expect(store.cachedCount == 3)
        try await waitUntil { held.image != nil }

        store.releaseCache()

        #expect(store.cachedCount == 0)
        #expect(held.image != nil)
        let fresh = store.favicon(for: hosts[0])
        #expect(fresh !== held)
        try await waitUntil { fresh.image != nil }
        #expect(StubIconProtocol.requested.filter { $0.host() == hosts[0] }.isEmpty)
    }

    // Two callers for one URL share its fetch: the second joins the first's task and one request goes out; the task
    // leaves the map when it lands, so a later call fetches again.
    @Test func concurrentDownloadsOfOneURLShareTheFetch() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 10))
        StubIconProtocol.park(url)
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let first = Task { try await store.download(url) }
        let second = Task { try await store.download(url) }
        try await waitUntil { store.joins == 1 }
        StubIconProtocol.release(url)
        for task in [first, second] {
            let icon = try await task.value
            #expect(icon.image.size.width == 10)
            #expect(icon.tint != nil)
        }
        #expect(StubIconProtocol.requested.filter { $0 == url } == [url])
        _ = try await store.download(url)
        #expect(StubIconProtocol.requested.filter { $0 == url }.count == 2)
        #expect(store.joins == 1)
    }

    // Two hosts naming one icon URL in one turn share its fetch: one request goes out and the second host joins it.
    @Test func twoHostsNamingOneIconURLMakeOneRequest() async throws {
        let hosts = [host(), host()]
        let url = URL(string: "https://cdn.icons.test/\(UUID().uuidString.lowercased()).png")!
        StubIconProtocol.answer(url, with: png(side: 10))
        StubIconProtocol.park(url)
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let boxes = hosts.map(store.favicon(for:))

        for host in hosts {
            store.update(host: host, iconURLs: [url])
        }
        try await waitUntil { store.joins == 1 }
        StubIconProtocol.release(url)
        try await waitUntil { boxes.allSatisfy { $0.image?.size.width == 10 } }

        #expect(StubIconProtocol.requested.filter { $0 == url } == [url])
        #expect(hosts.allSatisfy { store.loaded[$0] == [url] })
    }

    // A fetched icon lands with its tint in one write, the tint worked out with the fetch, off the main actor.
    @Test func aFetchedIconArrivesWithItsTintInOneWrite() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 10))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let box = store.favicon(for: host)
        let writes = Writes { _ = box.image }

        store.update(host: host, iconURLs: [url])
        try await waitUntil { box.image != nil }

        #expect(box.tint != nil)
        #expect(writes.count == 1)
    }

    // A store released before its update resumes runs no more of it: the environment wires allowsNetwork over an
    // unowned energy policy, and a read from work that outlived them both crashed the test host on the farm.
    @Test func anUpdateStopsOnceItsStoreIsGone() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 10))
        let asked = NetworkAsks()
        var store: FaviconStore? = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        weak var freed = store
        store!.allowsNetwork = {
            asked.count += 1
            return true
        }

        store!.update(host: host, iconURLs: [url])
        store = nil

        #expect(freed == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked.count == 0)
        #expect(!StubIconProtocol.requested.contains(url))
    }

    // The tint is worked out where the file is decoded, so it lands in the same turn as the image.
    @Test func theTintArrivesWithTheImage() async throws {
        let directories = AppDirectories.temporary()
        let host = host()
        let folder = directories.caches.appending(path: "favicons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png(side: 16).write(to: folder.appending(path: "\(host).png"))
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())
        let box = store.favicon(for: host)
        try await waitUntil { box.image != nil }
        #expect(box.tint != nil)
    }

    @Test func defaultSessionIsEphemeralAndCookieFree() {
        let configuration = FaviconStore(directories: .temporary()).session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.allowsConstrainedNetworkAccess)
        #expect(configuration.allowsExpensiveNetworkAccess)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.timeoutIntervalForRequest == Theme.Network.faviconTimeout)
        #expect(configuration.timeoutIntervalForResource == Theme.Network.faviconResourceTimeout)
    }

    @Test func stubSessionKeepsTheStoresFlags() {
        let configuration = StubIconProtocol.session().configuration
        #expect(!configuration.allowsConstrainedNetworkAccess)
        #expect(configuration.httpCookieStorage == nil)
    }

    // Writes a cached icon for the host before the store exists, as an earlier launch would have.
    private func cache(_ host: String, in directories: AppDirectories, side: Int, age: TimeInterval = 0) throws -> String {
        let folder = directories.caches.appending(path: "favicons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(path: "\(host).png").path(percentEncoded: false)
        try png(side: side).write(to: URL(filePath: path))
        try FileManager.default.setAttributes([.modificationDate: Date.now - age], ofItemAtPath: path)
        return path
    }

    // The wait is on loaded, the fresh path's own completion: favicon(for:) fills the box from disk whether or not a
    // fetch also runs, so a box wait could pass a wrong store.
    @Test func aFreshCachedIconIsNotFetched() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 20))
        let directories = AppDirectories.temporary()
        _ = try cache(host, in: directories, side: 10)
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())

        store.update(host: host, iconURLs: [url])

        try await waitUntil { store.loaded[host] == [url] }
        #expect(!StubIconProtocol.requested.contains(url))
        #expect(store.favicon(for: host).image?.size.width == 10)
    }

    @Test func aStaleCachedIconIsFetchedAgain() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 20))
        let directories = AppDirectories.temporary()
        let path = try cache(host, in: directories, side: 10, age: Theme.Network.faviconFresh + 1)
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())

        store.update(host: host, iconURLs: [url])

        try await waitUntil { StubIconProtocol.requested.contains(url) }
        try await waitUntil { UIImage(contentsOfFile: path)?.size.width == 20 }
    }

    // A constrained path fails every candidate the same way, so the loop ends at the first; a plain offline failure
    // still gives way to the next candidate. The plain case runs second so its second request proves the first host's
    // loop had every chance to go on.
    @Test func aConstrainedPathEndsTheCandidateLoopAfterOneRequest() async throws {
        let constrained = host()
        let first = URL(string: "https://\(constrained)/a.png")!
        let second = URL(string: "https://\(constrained)/b.png")!
        StubIconProtocol.fail(
            first,
            with: URLError(
                .notConnectedToInternet,
                userInfo: [NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.constrained.rawValue]))
        StubIconProtocol.answer(second, with: png(side: 10))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        store.update(host: constrained, iconURLs: [first, second])
        try await waitUntil { StubIconProtocol.requested.contains(first) }

        let offline = host()
        let third = URL(string: "https://\(offline)/a.png")!
        let fourth = URL(string: "https://\(offline)/b.png")!
        StubIconProtocol.fail(third, with: URLError(.notConnectedToInternet))
        StubIconProtocol.answer(fourth, with: png(side: 10))
        store.update(host: offline, iconURLs: [third, fourth])
        try await waitUntil { store.loaded[offline] == [third, fourth] }

        #expect(StubIconProtocol.requested.filter { $0.host() == offline } == [third, fourth])
        #expect(StubIconProtocol.requested.filter { $0.host() == constrained } == [first])
        #expect(store.loaded[constrained] == nil)
    }

    @Test func networkOffKeepsIconsDiskOnly() async throws {
        let bare = host()
        let bareURL = URL(string: "https://\(bare)/icon.png")!
        let fresh = host()
        let freshURL = URL(string: "https://\(fresh)/icon.png")!
        StubIconProtocol.answer(bareURL, with: png(side: 20))
        StubIconProtocol.answer(freshURL, with: png(side: 20))
        let directories = AppDirectories.temporary()
        _ = try cache(fresh, in: directories, side: 10)
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())
        store.allowsNetwork = { false }

        store.update(host: bare, iconURLs: [bareURL])
        store.update(host: fresh, iconURLs: [freshURL])

        try await waitUntil { store.loaded[fresh] == [freshURL] }
        try await waitUntil { store.favicon(for: fresh).image != nil }
        #expect(store.favicon(for: fresh).image?.size.width == 10)
        #expect(store.loaded[bare] == nil)
        #expect(!StubIconProtocol.requested.contains(bareURL))
        #expect(!StubIconProtocol.requested.contains(freshURL))
    }

    @Test func abortsOversizedIconsBeforeDecoding() async throws {
        let host = host()
        let big = URL(string: "https://\(host)/big.png")!
        let small = URL(string: "https://\(host)/small.png")!
        let body = noisyPNG(side: 500)
        #expect(body.count > FaviconStore.maxBytes)
        #expect(UIImage(data: body) != nil)
        StubIconProtocol.answer(big, with: body)
        StubIconProtocol.answer(small, with: png(side: 10))
        let store = FaviconStore(directories: .temporary(), session: StubIconProtocol.session())
        let box = store.favicon(for: host)

        store.update(host: host, iconURLs: [big])
        try await waitUntil { StubIconProtocol.requested.contains(big) }
        try await Task.sleep(for: .seconds(1))
        #expect(box.image == nil)

        store.update(host: host, iconURLs: [small])
        try await waitUntil { box.image?.size.width == 10 }
    }

    @Test func clearDropsCachedIconsAndTheirFiles() async throws {
        let host = host()
        let url = URL(string: "https://\(host)/icon.png")!
        StubIconProtocol.answer(url, with: png(side: 10))
        let directories = AppDirectories.temporary()
        let folder = directories.caches.appending(path: "favicons")
        let file = folder.appending(path: "\(host).png").path(percentEncoded: false)
        let store = FaviconStore(directories: directories, session: StubIconProtocol.session())
        let box = store.favicon(for: host)
        store.update(host: host, iconURLs: [url])
        try await waitUntil { FileManager.default.fileExists(atPath: file) }

        await store.clear()

        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(store.favicon(for: host) !== box)
        store.update(host: host, iconURLs: [url])
        try await waitUntil { StubIconProtocol.requested.filter { $0 == url }.count == 2 }
    }
}

private final class NetworkAsks { var count = 0 }
