import SwiftUI
import Testing
@testable import SailBrowser

@MainActor
struct MenuSheetTests {
    @Test func theTrackerFooterShowsACountOnlyWhileBlockingAndAtLeastOneWasScrubbed() {
        typealias Content = TrackerFooter.Content
        #expect(Content.of(blocksGlobally: true, blocksSite: true, count: 3) == .scrubbed(3))
        #expect(Content.of(blocksGlobally: true, blocksSite: true, count: 0) == nil)
        #expect(Content.of(blocksGlobally: true, blocksSite: false, count: 0) == .allowed)
        #expect(Content.of(blocksGlobally: false, blocksSite: true, count: 3) == nil)
        #expect(Content.of(blocksGlobally: false, blocksSite: false, count: 3) == nil)
    }

    @Test func closeCarriesFingerVelocity() {
        var closing = MenuDrag()
        _ = closing.changed(90)
        #expect(closing.ended(translation: 90, velocity: 1240, sheetHeight: 400) == .close(velocity: 4))
        let staying = MenuDrag()
        #expect(staying.ended(translation: 120, velocity: -900, sheetHeight: 400) == .stay(velocity: 7.5))
    }

    @Test func armedDetentClosesBelowTheLine() {
        var drag = MenuDrag()
        _ = drag.changed(85)
        #expect(drag.ended(translation: 76, velocity: 0, sheetHeight: 400) == .close(velocity: 0))
    }

    @Test func detentResetsPerDrag() {
        var first = MenuDrag()
        _ = first.changed(120)
        #expect(first.ended(translation: 120, velocity: 0, sheetHeight: 400) == .close(velocity: 0))
        var second = MenuDrag()
        _ = second.changed(79)
        #expect(second.ended(translation: 79, velocity: 0, sheetHeight: 400) == .stay(velocity: 0))
    }

    // A sheet taken mid-motion starts where it is drawn, and only the finger's own travel arms or flicks it closed.
    @Test func aDragFromWhereTheSheetIsDrawnDecidesOnTheFingerAlone() {
        var drag = MenuDrag(from: 170)
        #expect(drag.changed(0) == 170)
        #expect(drag.changed(-30) == 140)
        #expect(drag.ended(translation: -30, velocity: -280, sheetHeight: 400) == .stay(velocity: 2))
        var raised = MenuDrag(from: -20)
        #expect(abs(raised.changed(0) + 20) < 0.001)
    }

    @Test func changedFollowsDownAndStretchesUp() {
        var drag = MenuDrag()
        #expect(drag.changed(50) == 50)
        let up = drag.changed(-300)
        #expect(up < -40)
        #expect(up > -Theme.Gesture.sheetStretch)
    }

    private func hostedMenu() async throws -> (AppEnvironment, UIWindow) {
        let env = makeEnvironment()
        env.open(page("a"))
        let window = host(env)
        try await waitUntil { env.debugActions[.pin] != nil && env.debugSurfaces[.menuSheet] != nil }
        return (env, window)
    }

    @Test func pinPublishesUnderTheNextStateAndTheDimDismissesSilently() async throws {
        let (env, window) = try await hostedMenu()
        #expect(env.debugActions[.unpin] == nil)

        env.debugActions[.pin]!()
        try await waitUntil { env.debugActions[.unpin] != nil }
        #expect(env.browser.activeTab!.isPinned)
        #expect(env.haptics.records.last?.interaction == .pin)
        #expect(env.debugActions[.pin] == nil)

        env.debugActions[.menuDimTap]!()
        #expect(env.ui.overlay == .none)
        let dim = env.haptics.records.last!
        #expect(dim.interaction == .menuDimTap)
        #expect(!dim.played)
        window.isHidden = true
    }

    // The tile reads the store, which flips and reorders in the tap's own call, before any frame is drawn.
    @Test func pinFlipsTheTileStateInTheTapsTurn() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.open(page("b"))
        let window = host(env)
        try await waitUntil { env.debugActions[.pin] != nil }
        let active = try #require(env.browser.activeTabID)
        #expect(env.browser.tabs.last?.id == active)
        #expect(MenuSheet.pinTile(pinned: env.browser.activeTab!.isPinned) == ("Pin", "pin", .pin))

        env.debugActions[.pin]!()
        #expect(MenuSheet.pinTile(pinned: env.browser.activeTab!.isPinned) == ("Unpin", "pin.slash", .unpin))
        #expect(env.browser.activeTabID == active)
        #expect(env.browser.tabs.first?.id == active)
        window.isHidden = true
    }

    @Test(arguments: [(90.0, Interaction.menuDragDismiss, UIState.Overlay.none), (40.0, .menuDragReturn, .menu)])
    func aReleaseRecordsItsSilentInteraction(height: CGFloat, release: Interaction, overlay: UIState.Overlay) async throws {
        let (env, window) = try await hostedMenu()
        let surface = env.debugSurfaces[.menuSheet]!
        let released = sample(height)
        surface(.began, released)
        surface(.changed, released)
        surface(.ended, released)
        #expect(env.ui.overlay == overlay)
        let record = env.haptics.records.last!
        #expect(record.interaction == release)
        #expect(!record.played)
        window.isHidden = true
    }

    @Test func aCancelledDragClearsTheDetent() async throws {
        let (env, window) = try await hostedMenu()
        let surface = env.debugSurfaces[.menuSheet]!
        let armed = sample(90)
        surface(.began, armed)
        surface(.changed, armed)
        let records = env.haptics.records.count
        surface(.cancelled, armed)
        #expect(env.ui.overlay == .menu)
        #expect(env.haptics.records.count == records)

        let held = sample(75)
        surface(.began, held)
        surface(.changed, held)
        surface(.ended, held)
        #expect(env.ui.overlay == .menu)
        #expect(env.haptics.records.last?.interaction == .menuDragReturn)
        window.isHidden = true
    }

    @Test func theReaderRowOpensTheReaderAndThenClosesIt() async throws {
        let env = makeEnvironment()
        env.open(try ReaderFixtures.dataURL("readability-001"))
        let controller = try #require(env.activeController)
        try await waitUntil(timeout: .seconds(15)) { MenuRow.reader(controller, env: env).isEnabled }
        let open = MenuRow.reader(controller, env: env)
        #expect(open.icon == "doc.plaintext")
        #expect(open.title == "Reader Mode")

        env.ui.open(.menu)
        open.action!()
        #expect(env.ui.overlay == .none)
        #expect(env.haptics.records.last?.interaction == .readerOpen)
        try await waitUntil { controller.readerArticle != nil }
        #expect(controller.reader.isOpen)

        let close = MenuRow.reader(controller, env: env)
        #expect(close.title == "Close Reader Mode")
        #expect(close.isEnabled)
        env.ui.open(.menu)
        close.action!()
        #expect(env.ui.overlay == .none)
        #expect(controller.readerArticle == nil)
        #expect(!controller.reader.isOpen)
        #expect(env.haptics.records.last?.interaction == .readerClose)
    }

    @Test func theReaderRowIsDisabledOnAPageWithNoArticle() async throws {
        let env = makeEnvironment()
        env.open(try ReaderFixtures.dataURL("readability-001"))
        let controller = try #require(env.activeController)
        #expect(!MenuRow.reader(controller, env: env).isEnabled)
        try await waitUntil(timeout: .seconds(15)) { MenuRow.reader(controller, env: env).isEnabled }

        controller.load(try ReaderFixtures.dataURL("app-form"))
        try await waitUntil(timeout: .seconds(15)) { !MenuRow.reader(controller, env: env).isEnabled && controller.hasSettled }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!MenuRow.reader(controller, env: env).isEnabled)
    }

    // The menu as RootView mounts it, following the overlay.
    private func host(_ env: AppEnvironment) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MountedMenu().environment(env))
        window.makeKeyAndVisible()
        env.ui.open(.menu)
        return window
    }

    private func sample(_ height: CGFloat) -> DragSample {
        DragSample(
            startLocation: .zero, location: CGPoint(x: 0, y: height), translation: CGSize(width: 0, height: height),
            velocity: .zero, time: .now)
    }

    @Test func driversCoverTheMenuInteractions() {
        #expect(
            Set(MenuDrivers.table.keys) == [
                .menuDragDismiss, .menuDragReturn, .menuGrabDuringOpen, .menuDimTap, .menuNav, .menuCopyLink, .pin,
                .unpin, .zoomStep, .archiveRestore, .sheetDone,
            ])
    }
}

private struct MountedMenu: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        PageMenuHost(isOpen: env.ui.overlay == .menu)
    }
}
