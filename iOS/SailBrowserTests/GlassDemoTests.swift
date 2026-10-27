import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

#if DEBUG
@Observable private final class Mount {
    var isOn = true
}

private struct Mounting: View {
    let mount: Mount
    let controller: WebTabController

    var body: some View {
        if mount.isOn {
            BarSlide(controller: controller)
        }
    }
}

@MainActor @Suite(.serialized)
struct GlassDemoTests {
    @Test func theDemoPlaysTheSevenMotionsInOrder() {
        #expect(GlassDemo.motions.map(\.name) == ["barSlide", "barSwipe", "flick", "zoomOut", "zoomIn", "menu", "search"])
        #expect(GlassDemo.motions.allSatisfy { $0.window > .zero })
    }

    // Two pages, one bright and one dark, each its own theme colour, with rows for the frame counter.
    @Test func thePagesCarryTwoBackgroundsAndRows() {
        #expect(GlassDemo.backgrounds.count == 2 && Set(GlassDemo.backgrounds).count == 2)
        for background in GlassDemo.backgrounds {
            let html = GlassDemo.page(background)
            #expect(html.contains("background:#\(background)"))
            #expect(html.contains("<meta name='theme-color' content='#\(background)'>"))
            #expect(html.components(separatedBy: "<p>").count > 1)
        }
    }

    @Test func theBarPublishesItsSurfaceWhileMountedAndWithdrawsItOnDismantle() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let env = makeEnvironment()
        env.open(page("a"))
        let mount = Mount()
        let host = UIHostingController(rootView: Mounting(mount: mount, controller: env.activeController!).environment(env))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await waitUntil { env.debugSurfaces[.bar] != nil }
        mount.isOn = false
        try await waitUntil { env.debugSurfaces[.bar] == nil }
    }

    // The driver's swipe right from the middle tab, through the bar's surface, lands on the previous tab.
    @Test(.timeLimit(.minutes(1))) func theBarSwipeDriverPagesToThePreviousTab() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let env = makeEnvironment()
        for index in 0..<3 {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        let controller = BehindController(env: env)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil { env.pager != nil && env.debugSurfaces[.bar] != nil }
        env.showTab(tabs[1], via: .deckCardTap)
        try await waitUntil {
            env.activeController?.tabID == tabs[1] && env.pager?.driver.position == 1 && env.pager?.driver.isAnimating == false
        }
        await BarDrivers.table[.barSwipe]!(env)
        try await waitUntil { env.pager?.driver.isPaging == false && env.pager?.driver.isAnimating == false }
        #expect(env.browser.activeTabID == tabs[0])
        #expect(env.pager?.driver.position == 0)
    }
}
#endif
