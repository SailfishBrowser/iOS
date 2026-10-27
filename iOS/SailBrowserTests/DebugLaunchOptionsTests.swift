import Testing
import UIKit
@testable import SailBrowser

#if DEBUG
// The store screenshot script reaches these states through launch arguments alone.
// Each test runs the options as finishLaunch runs them, over an environment hosted as the app hosts it, so the seed's
// snapshot waits and the bar's surfaces are real.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DebugLaunchOptionsTests {
    private static let french = Locale.Language(identifier: "fr")
    private static let frenchPage = URL(
        string: "data:text/html;base64,"
            + Data("<html lang=\"fr\"><body><p>Le chat dort sur le canapé.</p></body></html>".utf8).base64EncodedString())!

    private struct Hosted {
        let env: AppEnvironment
        let window: UIWindow
    }

    private func hosted() -> Hosted {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        window.rootViewController = BehindController(env: env)
        window.makeKeyAndVisible()
        return Hosted(env: env, window: window)
    }

    private func options(
        seed: [URL], screen: String, isPrivate: Bool = false, forceTranslation: Bool = false
    ) -> DebugLaunchOptions {
        DebugLaunchOptions(
            resetState: false, seedURLs: seed, activeIndex: nil, screen: screen, demo: nil, submitURL: nil, scroll: nil,
            isPrivate: isPrivate, forceTranslation: forceTranslation)
    }

    // -SailScreen reader: the seeded article is open in the reader with the search sheet closed, as the menu's Reader
    // Mode row leaves it.
    @Test func theReaderScreenOpensTheReaderOnTheActiveTab() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        let article = try ReaderFixtures.dataURL("readability-001")
        await options(seed: [article], screen: "reader").run(in: hosted.env)
        #expect(hosted.env.activeController?.readerArticle != nil)
        #expect(hosted.env.ui.overlay == .none)
    }

    // -SailPrivate 1: every seeded tab is private, so the page shows its band and the bar its private look.
    @Test func thePrivateFlagSeedsPrivateTabs() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        await options(seed: [page("a"), page("b")], screen: "browse", isPrivate: true).run(in: hosted.env)
        let tabs = hosted.env.browser.tabs
        #expect(tabs.count == 2)
        #expect(tabs.allSatisfy { $0.isPrivate })
        #expect(hosted.env.pool.isPrivate(hosted.env.activeController!.tabID))
    }

    // -SailForceTranslation 1: a French page offers its translation in the simulator, where LanguageAvailability reports
    // every pair unsupported. The offer is the button alone; nothing is translated.
    @Test func theForcedTranslationShowsTheButtonForAFrenchPage() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        await options(seed: [Self.frenchPage], screen: "browse", forceTranslation: true).run(in: hosted.env)
        let controller = hosted.env.activeController!
        try await waitUntil { controller.translator.source == Self.french }
        try await waitUntil { hosted.env.debugSurfaces[.translate] != nil }
        #expect(controller.translator.state == .idle)
    }
}
#endif
