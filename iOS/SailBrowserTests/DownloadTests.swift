import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct DownloadTests {
    private static let zip = Data((0..<4096).map { UInt8($0 % 251) })

    private func attachment(_ name: String, body: Data = zip) -> (String) -> LocalPageServer.Reply {
        { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=\(name)"],
                body: body)
        }
    }

    @Test func anAttachmentLandsInDownloadsWithOneFinishedRecord() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")

        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        let file = env.downloads.folder.appending(path: "a.zip")
        #expect(env.downloads.folder.path().hasSuffix("/Downloads/"))
        #expect(FileManager.default.contents(atPath: file.path(percentEncoded: false)) == Self.zip)
        let record = try #require(env.downloads.records.first)
        #expect(env.downloads.records.count == 1)
        #expect(record.filename == "a.zip")
        #expect(record.sourceURL == server.url("/a.zip"))
        #expect(record.bytes == Int64(Self.zip.count))
        #expect(record.total == Int64(Self.zip.count))
        #expect(env.haptics.records.filter { $0.interaction == .settingsChange }.count == 1)
    }

    // The download's own new tab, on the pool's prewarmed blank page as after launch, closes and leaves nothing in the
    // archive.
    @Test func aDownloadFromABlankTabClosesIt() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.open(server.url("/page"))
        let pageTab = try #require(env.browser.activeTabID)
        try await waitUntil(timeout: .seconds(10)) { env.activeController?.hasSettled == true }
        env.pool.prewarm()
        let prewarmed = try #require(env.pool.prewarmed)
        try await waitUntil(timeout: .seconds(10)) { prewarmed.url != nil && !prewarmed.isLoading }

        env.open(server.url("/a.zip"))
        #expect(env.activeController?.webView === prewarmed)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        #expect(env.browser.tabs.map(\.id) == [pageTab])
        #expect(env.browser.activeTabID == pageTab)
        #expect(env.browser.archived.isEmpty)
    }

    @Test func aTargetBlankDownloadClosesItsWindowAndLandsOnTheOpener() async throws {
        let env = makeEnvironment()
        env.pool.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let server = try await LocalPageServer { _ in "<p>opener</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.open(server.url("/page"))
        let opener = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(10)) { opener.hasSettled }

        _ = try await opener.webView.evaluateJavaScript("window.open('/a.zip'); 1")
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        #expect(env.browser.tabs.map(\.id) == [opener.tabID])
        #expect(env.browser.activeTabID == opener.tabID)
        #expect(env.activeController === opener)
        #expect(env.browser.archived.isEmpty)
    }

    // A file URL submitted from search leaves no tab: the user lands back on the tab they were on.
    @Test func aFileSubmittedFromSearchLeavesNoTab() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.open(server.url("/page"))
        let pageTab = try #require(env.browser.activeTabID)
        try await waitUntil(timeout: .seconds(10)) { env.activeController?.hasSettled == true }
        #expect(env.ui.open(.search, animated: false))

        env.submit(server.url("/a.zip"), via: .searchSubmit)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        env.ui.submitHidden()

        #expect(env.browser.tabs.map(\.id) == [pageTab])
        #expect(env.browser.activeTabID == pageTab)
        #expect(env.activeController?.tabID == pageTab)
        #expect(env.browser.archived.isEmpty)
        #expect(!env.ui.isBarIntroPending)
        #expect(env.ui.deckProgress == 0)
    }

    // With no other tab, the deck shows the switcher.
    @Test func aFileSubmittedWithNoOtherTabLandsOnTheDeck() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.search, animated: false))

        env.submit(server.url("/a.zip"), via: .searchSubmit)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        env.ui.submitHidden()

        #expect(env.browser.tabs.isEmpty)
        #expect(env.activeController == nil)
        #expect(env.browser.archived.isEmpty)
        #expect(env.ui.deckProgress == 1)
    }

    @Test func aLinkToAnAttachmentKeepsThePage() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<a id=l href=\"/a.zip\">a</a>" }
        server.routes["/a.zip"] = attachment("a.zip")
        let page = server.url("/page")
        env.open(page)
        let controller = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled }

        _ = try await controller.webView.evaluateJavaScript("document.getElementById('l').click(); 1")
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        #expect(controller.webView.url == page)
        #expect(env.browser.tabs.count == 1)
    }

    @Test func aDownloadAttributeLinkDownloads() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<a id=l href=\"/plain.txt\" download=\"notes.txt\">a</a>" }
        server.routes["/plain.txt"] = { _ in LocalPageServer.Reply(headers: ["Content-Type": "text/plain"], body: Data("hi".utf8)) }
        env.open(server.url("/page"))
        let controller = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled }

        _ = try await controller.webView.evaluateJavaScript("document.getElementById('l').click(); 1")
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        let record = try #require(env.downloads.records.first)
        #expect(record.filename == "notes.txt")
        #expect(FileManager.default.contents(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)) == Data("hi".utf8))
    }

    @Test func aSecondDownloadOfTheSameNameIsNumbered() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")

        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) {
            env.downloads.records.count == 2 && env.downloads.records.allSatisfy { $0.state == .finished }
        }

        #expect(env.downloads.records.map(\.filename) == ["a 2.zip", "a.zip"])
        let second = env.downloads.folder.appending(path: "a 2.zip")
        #expect(FileManager.default.contents(atPath: second.path(percentEncoded: false)) == Self.zip)
    }

    @Test func aPDFWithoutAttachmentOpensInThePage() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/doc.pdf"] = { _ in LocalPageServer.Reply(headers: ["Content-Type": "application/pdf"], body: Self.pdf()) }
        let url = server.url("/doc.pdf")
        env.open(url)
        let controller = try #require(env.activeController)
        let finished = FinishedURLs()
        let onFinish = controller.onFinish
        controller.onFinish = { url, title in
            finished.urls.append(url)
            onFinish?(url, title)
        }

        try await waitUntil(timeout: .seconds(10)) { finished.urls == [url] }
        #expect(env.downloads.records.isEmpty)
        #expect(controller.webView.url == url)
    }

    // Cancelling keeps what WebKit hands back, and Retry finishes the same record from it.
    @Test func aCancelledDownloadRetriesToTheSameFile() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        let half = Self.zip.count / 2
        server.routes["/b.zip"] = LocalPageServer.resumable(Self.zip, named: "b.zip", stallingAfter: half)

        env.open(server.url("/b.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.bytes == Int64(half) }
        let id = try #require(env.downloads.records.first?.id)
        env.downloads.cancel(id)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .failed && env.downloads.canRetry(id) }

        env.downloads.retry(id)
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }

        #expect(env.downloads.records.map(\.id) == [id])
        #expect(!env.downloads.canRetry(id))
        let file = env.downloads.folder.appending(path: "b.zip")
        #expect(FileManager.default.contents(atPath: file.path(percentEncoded: false)) == Self.zip)
    }

    @Test func deleteRemovesTheFileAndTheRecord() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        let record = try #require(env.downloads.records.first)

        env.downloads.delete(record.id)

        #expect(env.downloads.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)))
    }

    // Detached before its cancel, a running download never reaches the deleted row, even as its connection closes.
    @Test func deletingARunningDownloadLeavesNothing() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/c.zip"] = { _ in
            LocalPageServer.Reply(
                headers: [
                    "Content-Type": "application/zip", "Content-Disposition": "attachment; filename=c.zip",
                    "Content-Length": String(Self.zip.count),
                ],
                body: Self.zip[..<(Self.zip.count / 2)], holdsOpen: true)
        }
        env.open(server.url("/c.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.bytes ?? 0 > 0 }
        let record = try #require(env.downloads.records.first)

        env.downloads.delete(record.id)
        server.closeHeld()
        try await Task.sleep(for: .milliseconds(500))

        #expect(env.downloads.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)))
    }

    @Test func clearingBrowsingDataKeepsDownloads() async throws {
        let env = makeEnvironment()
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        server.routes["/a.zip"] = attachment("a.zip")
        env.open(server.url("/a.zip"))
        try await waitUntil(timeout: .seconds(10)) { env.downloads.records.first?.state == .finished }
        let record = try #require(env.downloads.records.first)

        await env.clearBrowsingData()

        #expect(env.downloads.records == [record])
        #expect(FileManager.default.fileExists(atPath: env.downloads.fileURL(of: record).path(percentEncoded: false)))
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

    private static func pdf() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        return renderer.pdfData { context in
            context.beginPage()
            "pdf".draw(at: CGPoint(x: 20, y: 20))
        }
    }
}
