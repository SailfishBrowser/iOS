import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct IntegrationTests {
    @Test func adBlockingToggleReachesBlockerAndReloads() async throws {
        let env = makeEnvironment()
        let handler = FailingSchemeHandler()
        env.pool.configuration.setURLSchemeHandler(handler, forURLScheme: "fail")
        let url = URL(string: "fail://page/a")!
        env.open(url)
        let controller = try #require(env.activeController)
        try await waitUntil { controller.hasSettled }
        #expect(handler.startedURLs == [url])

        env.browser.settings.blocksAds = false
        try await waitUntil { env.blocker.categories == [.trackers, .cookieBanners] && handler.startedURLs.count == 2 }
        try await waitUntil { controller.hasSettled }

        // The observation tracks blockedCategories only, so an unrelated write fires nothing. The marker task runs
        // after any hop the write could have enqueued, and reload() would have set isLoading synchronously.
        env.browser.settings.zoomByHost["example.test"] = 1.5
        await Task { @MainActor in }.value
        #expect(!controller.webView.isLoading)

        env.browser.settings.blocksAds = true
        try await waitUntil { env.blocker.categories == Set(BlockingCategory.allCases) && handler.startedURLs.count == 3 }
        try await waitUntil { controller.hasSettled }
        #expect(handler.startedURLs == [url, url, url])
    }

    // The suites run hosted in the app, so Bundle.main carries its rule lists and manifest.
    @Test func theTestHostIsTheApp() {
        #expect(Bundle.main.bundleURL.lastPathComponent == "SailBrowser.app")
    }

    @Test func blocklistVersionComesFromBundledManifest() {
        #expect(makeEnvironment().blocklistVersion == BlocklistManifest.bundled(in: .main).version)
    }
}
