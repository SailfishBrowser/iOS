import Foundation
import Testing
import WebKit
@testable import SailBrowser

// What a real web view writes to history: every committed main-frame page once, under its final URL, with the title it
// ends up with.
@MainActor @Suite(.serialized)
struct HistoryRecordingTests {
    private let history = HistoryStore(directories: AppDirectories.temporary())

    private func tracked() -> WebTabController {
        let controller = WebTabController(tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics())
        history.track(controller)
        return controller
    }

    @Test func aCommittedPageGetsTheTitleItSetsLate() async throws {
        let server = try await LocalPageServer { _ in
            "<title>First</title><script>setTimeout(() => document.title = 'Late', 300)</script>"
        }
        let controller = tracked()
        let page = server.url("/page-a")
        controller.load(page)

        try await waitUntil(timeout: .seconds(10)) { history.entries.first?.title == "Late" }
        #expect(history.entries.map(\.url) == [page])
        #expect(history.entries[0].visitCount == 1)
    }

    @Test func aRedirectRecordsTheFinalURLOnly() async throws {
        let server = try await LocalPageServer { _ in "<title>Final</title>" }
        let controller = tracked()
        controller.load(server.url("/redirect-b"))

        try await waitUntil(timeout: .seconds(10)) { history.entries.first?.title == "Final" }
        #expect(history.entries.map(\.url) == [server.url("/page-b")])
    }

    // Pages often rewrite their URL on load (utm stripping, router normalising) before titling themselves from script.
    @Test func aTitleSetAfterAReplaceStateStillLands() async throws {
        let server = try await LocalPageServer { _ in
            "<script>history.replaceState({}, '', '/page-d?x=1'); setTimeout(() => document.title = 'Late', 300)</script>"
        }
        let controller = tracked()
        let page = server.url("/page-d")
        controller.load(page)

        try await waitUntil(timeout: .seconds(10)) { history.entries.first?.title == "Late" }
        #expect(history.entries.map(\.url) == [page])
    }

    @Test func aSameDocumentNavigationAddsNoRow() async throws {
        let server = try await LocalPageServer { _ in "<title>Shown</title>" }
        let controller = tracked()
        let page = server.url("/page-c")
        controller.load(page)
        try await waitUntil(timeout: .seconds(10)) { history.entries.first?.title == "Shown" && !controller.isLoading }

        _ = try await controller.webView.evaluateJavaScript(
            "history.pushState({}, '', '/page-c2'); document.title = 'Pushed'; 1")
        try await waitUntil { controller.title == "Pushed" }

        #expect(history.entries.map(\.url) == [page])
        #expect(history.entries.map(\.title) == ["Shown"])
    }
}
