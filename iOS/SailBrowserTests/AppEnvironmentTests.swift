import Foundation
import Synchronization
import Testing
import UIKit
import WebKit
@testable import SailBrowser

func makeEnvironment(
    _ directories: AppDirectories = .temporary(), hapticSink: any HapticSink = RecordingHapticSink(start: .now),
    energy: EnergyPolicy = EnergyPolicy(
        readings: .init(lowPower: { false }, thermal: { .nominal }), center: NotificationCenter()),
    pressure: MemoryPressureRelief = RecordingPressure().relief,
    assertion: BackgroundAssertion = BackgroundAssertion(begin: { _, _ in {} })
) -> AppEnvironment {
    AppEnvironment(
        directories: directories, ruleStore: WKContentRuleListStore(url: directories.caches.appending(path: "rules")),
        hapticSink: hapticSink, energy: energy, pressure: pressure, assertion: assertion)
}

// Keeps the relief closure an environment registers, so a test can report pressure back to normal, and counts the
// stops.
@MainActor final class RecordingPressure {
    private(set) var relieved: (@MainActor @Sendable () -> Void)?
    private(set) var stops = 0

    var relief: MemoryPressureRelief {
        MemoryPressureRelief(watch: { [self] relieved in
            self.relieved = relieved
            return { self.stops += 1 }
        })
    }
}

func recordingHaptics() -> HapticsEngine {
    HapticsEngine(sink: RecordingHapticSink(start: .now))
}

extension RecordingHapticSink {
    // Each play's generator was prepared since that generator last played.
    var playsArePrepared: Bool {
        var warm: Set<HapticFeedback.Generator> = []
        for call in calls {
            switch call {
            case .prepare(let feedback):
                warm.insert(feedback.generator)
            case .play(let feedback):
                if warm.remove(feedback.generator) == nil {
                    return false
                }
            case .drive, .stop:
                break
            }
        }
        return true
    }
}

// Runs a check at the moment a haptic plays, to see what work came before it.
@MainActor final class ProbeHapticSink: HapticSink {
    let now = ContinuousClock.now
    var onPlay: () -> Void = {}

    func prepare(_ feedback: HapticFeedback) {}

    func play(_ feedback: HapticFeedback) {
        onPlay()
    }

    func drive(_ texture: HapticTexture, _ level: HapticTexture.Level) {}

    func stop(_ texture: HapticTexture) {}
}

func page(_ name: String) -> URL {
    URL(string: "data:text/html,<p>\(name)</p>")!
}

struct AppEnvironmentTests {
    // A tab can outlive its environment; its history hooks and app-link check then leave the freed stores alone.
    @Test func aTabThatOutlivesItsEnvironmentStillNavigatesAndKeepsItsLinks() async throws {
        weak var freed: AppEnvironment?
        let controller: WebTabController
        do {
            let env = makeEnvironment()
            freed = env
            env.open(page("a"))
            controller = env.activeController!
            try await waitUntil { controller.hasSettled }
        }
        try await waitUntil { freed == nil }
        await loadAndFinish(controller, html: "<title>B</title><p>b</p>", base: "https://example.test/b")
        #expect(controller.url == URL(string: "https://example.test/b"))
        let link = LinkRequest(url: URL(string: "https://other.test/a")!, isMainFrame: true, type: .linkActivated)
        #expect(await !controller.leavesForApp(link))
    }

    // The deck's debug hooks live on the environment and close over the deck, so they go with the deck: a hosted
    // environment with no page is freed once its window lets it go.
    @Test(.timeLimit(.minutes(1)))
    func aHostedEnvironmentWithNoPageIsFreedWithItsWindow() async throws {
        weak var freed: AppEnvironment?
        do {
            let env = makeEnvironment()
            freed = env
            let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
            let window = UIWindow(windowScene: scene)
            window.rootViewController = BehindController(env: env)
            window.makeKeyAndVisible()
            try await waitUntil { env.debugDeckDrawn != nil }
            window.rootViewController = nil
            window.isHidden = true
        }
        try await waitUntil { freed == nil }
    }

    // WebKit's tile views keep the trait collection they last had, which carries SwiftUI's environment, for as long as
    // their web view lives, so the pages go first. The first page shown in a hosted window also leaves a process-wide
    // UIKit view holding that window's traits, so a first environment takes that hold before the one under test.
    @Test(.timeLimit(.minutes(1)), .timingSensitive)
    func aHostedEnvironmentIsFreedWithItsWindowOnceItsPagesAreGone() async throws {
        _ = try await showAPageThenLetGo()
        let freed = try await showAPageThenLetGo()
        try await waitUntil { freed() == nil }
    }

    // Hosts an environment with a page, then lets the window and every page go.
    private func showAPageThenLetGo() async throws -> () -> AppEnvironment? {
        weak var freed: AppEnvironment?
        weak var webView: WKWebView?
        do {
            let env = makeEnvironment()
            freed = env
            env.open(page("a"))
            let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
            let window = UIWindow(windowScene: scene)
            window.rootViewController = BehindController(env: env)
            window.makeKeyAndVisible()
            try await waitUntil { env.activeController?.webView.window != nil && env.activeController!.hasSettled }
            webView = env.activeController!.webView
            window.rootViewController = nil
            window.isHidden = true
            for tab in env.browser.tabs {
                env.archive(tab.id)
            }
        }
        try await waitUntil { webView == nil }
        return { freed }
    }

    // A deck leaving takes back only the hooks it set: a newer deck on the same environment keeps its own.
    @Test(.timeLimit(.minutes(1)))
    func aDeckLeavingKeepsANewerDecksHooks() async throws {
        let env = makeEnvironment()
        weak var olderHost: BehindController?
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let older = UIWindow(windowScene: scene)
        do {
            let host = BehindController(env: env)
            olderHost = host
            older.rootViewController = host
        }
        older.makeKeyAndVisible()
        try await waitUntil { env.debugDeckOwner != nil }
        let olderOwner = env.debugDeckOwner
        let newer = UIWindow(windowScene: scene)
        newer.rootViewController = BehindController(env: env)
        newer.makeKeyAndVisible()
        try await waitUntil { env.debugDeckOwner != olderOwner }
        older.rootViewController = nil
        older.isHidden = true
        try await waitUntil { olderHost == nil }
        #expect(env.debugDeckOwner != nil)
        #expect(env.debugDeckDrawn != nil)
        newer.isHidden = true
    }

    @Test func cardTapDuringZoomOutRetargets() {
        let env = makeEnvironment()
        env.open(page("a"))
        let other = env.browser.activeTabID!
        env.open(page("b"))

        env.showSwitcher(via: .tabStackTap)
        #expect(env.ui.deckProgress == 1)
        env.showTab(other, via: .deckCardTap)

        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.activeTabID == other)
        #expect(env.activeController?.tabID == other)
    }

    @Test func showTabWhileOverlayUpChangesNothing() {
        let env = makeEnvironment()
        env.open(page("a"))
        let other = env.browser.activeTabID!
        env.open(page("b"))
        let active = env.browser.activeTabID
        #expect(env.ui.open(.menu))

        env.showTab(other, via: .deckCardTap)

        #expect(env.browser.activeTabID == active)
        #expect(env.activeController?.tabID == active)
        #expect(env.ui.deckProgress == 0)
        #expect(env.ui.overlay == .menu)
    }

    @Test func showSwitcherWhileOverlayUpChangesNothing() {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.search))

        env.showSwitcher(via: .tabStackTap)

        #expect(env.ui.deckProgress == 0)
    }

    @Test func previousTabTogglesBack() {
        let env = makeEnvironment()
        env.open(page("a"))
        let a = env.browser.activeTabID!
        env.open(page("b"))
        let b = env.browser.activeTabID!

        env.activatePreviousTab()
        #expect(env.browser.activeTabID == a)
        #expect(env.activeController?.tabID == a)

        env.activatePreviousTab()
        #expect(env.browser.activeTabID == b)
        #expect(env.activeController?.tabID == b)
    }

    @Test func archivingActiveAttachesNextActiveController() {
        let env = makeEnvironment()
        env.open(page("a"))
        let a = env.browser.activeTabID!
        env.open(page("b"))
        let b = env.browser.activeTabID!

        env.archive(b)
        #expect(env.activeController?.tabID == a)
        #expect(env.pool.liveController(for: b) == nil)

        env.archive(a)
        #expect(env.activeController == nil)
    }

    @Test func restoreClosesSheetAndZoomsIntoRestoredTab() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.archive(env.browser.activeTabID!)
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.archive))

        env.restore(env.browser.archived[0].id)

        #expect(env.ui.overlay == .none)
        #expect(env.ui.deckProgress == 0)
        #expect(env.browser.archived.isEmpty)
        #expect(env.activeController?.tabID == env.browser.activeTabID)
    }

    @Test func zoomAndDesktopAreStoredAndApplied() {
        let env = makeEnvironment()
        env.open(URL(string: "https://example.test/a")!)
        let controller = env.activeController!
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/a")!), responseHTML: "<p>a</p>")

        env.setZoom(1.25, forHost: "example.test")
        #expect(env.zoom(forHost: "example.test") == 1.25)
        #expect(env.zoom(forHost: "other.test") == 1)

        env.setDesktopMode(true, for: controller.tabID)
        #expect(env.browser.activeTab?.prefersDesktop == true)
        #expect(controller.prefersDesktop)
    }

    @Test func backgroundingSavesEveryLiveTabsSession() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        let first = try #require(env.activeController)
        env.open(URL(string: "about:blank")!)
        let second = try #require(env.activeController)
        try await waitUntil { first.hasSettled && second.hasSettled }

        env.sceneDidEnterBackground()

        #expect(env.sessions.load(first.tabID) != nil)
        #expect(env.sessions.load(second.tabID) != nil)
    }

    @Test func clearingBrowsingDataDropsCachedFavicons() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        let folder = directories.caches.appending(path: "favicons")
        try await JSONFile.write(Data(), to: folder.appending(path: "cached.test.png"))
        let box = env.favicons.favicon(for: "cached.test")

        await env.clearBrowsingData()

        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(env.favicons.favicon(for: "cached.test") !== box)
    }

    // Low Power Mode ending builds the spare web view at once, through the energy observer.
    @Test func energyReturningPrewarms() async throws {
        let stub = EnergyStub()
        stub.lowPower.withLock { $0 = true }
        let center = NotificationCenter()
        let env = makeEnvironment(energy: EnergyPolicy(readings: stub.readings, center: center))
        env.pool.prewarm()
        #expect(env.pool.prewarmed == nil)
        stub.lowPower.withLock { $0 = false }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { env.pool.prewarmed != nil }
    }

    @Test func aMemoryWarningReleasesTheFaviconCache() {
        let env = makeEnvironment()
        _ = env.favicons.favicon(for: "a.test")
        #expect(env.favicons.cachedCount == 1)
        env.memoryWarning()
        #expect(env.favicons.cachedCount == 0)
    }

    @Test func foregroundEndsPressure() {
        let env = makeEnvironment()
        env.pool.prewarm()
        #expect(env.pool.prewarmed != nil)
        env.memoryWarning()
        #expect(env.pool.prewarmed == nil)
        #expect(env.pool.isUnderPressure)
        env.sceneWillEnterForeground()
        #expect(env.pool.prewarmed != nil)
        #expect(!env.pool.isUnderPressure)
    }

    // The system reporting pressure back to normal ends it; the watch stops with the environment.
    @Test func pressureReturningToNormalPrewarms() async throws {
        let recorder = RecordingPressure()
        weak var freed: AppEnvironment?
        do {
            let env = makeEnvironment(pressure: recorder.relief)
            freed = env
            env.pool.prewarm()
            env.memoryWarning()
            #expect(env.pool.prewarmed == nil)
            #expect(env.pool.isUnderPressure)
            recorder.relieved!()
            #expect(env.pool.prewarmed != nil)
            #expect(!env.pool.isUnderPressure)
            #expect(recorder.stops == 0)
        }
        try await waitUntil { freed == nil }
        #expect(recorder.stops == 1)
    }
}

struct EnvironmentFixTests {
    @Test func newPageOnZoomedHostRendersAtSavedZoom() async throws {
        let env = makeEnvironment()
        env.setZoom(1.5, forHost: "example.test")
        env.open(URL(string: "about:blank")!)
        let controller = env.activeController!
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/a")!), responseHTML: "<p>a</p>")

        try await waitUntil { controller.webView.pageZoom == 1.5 }
    }

    @Test func shortcutsFireTheirInteractionAfterTheirGuard() async {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        env.activatePreviousTab()
        env.open(page("a"))
        let first = env.browser.activeTabID!
        env.open(page("b"))
        #expect(env.haptics.records.isEmpty)

        env.showSwitcher(via: .tabStackTap)
        sink.advance(by: Theme.Latency.frame)
        env.showTab(first, via: .deckBackgroundTap)
        sink.advance(by: Theme.Latency.frame)
        env.activatePreviousTab()
        await env.clearBrowsingData()

        #expect(
            env.haptics.records.map(\.interaction) == [.tabStackTap, .deckBackgroundTap, .tabStackFlick, .clearData])
        #expect(env.haptics.records.map(\.played) == [true, false, true, true])
    }

    #if DEBUG
    // The load hook runs once the tab's web view is made, so a suggestion's tap playing first shows it waits on none
    // of that work.
    @Test func aSuggestionPlaysBeforeTheTabAndItsWebViewAreMade() {
        let sink = ProbeHapticSink()
        let env = makeEnvironment(hapticSink: sink)
        var steps: [String] = []
        sink.onPlay = { steps.append("play") }
        env.debugLoadStarted = { _ in steps.append("load") }
        #expect(env.ui.open(.search, animated: false))
        env.submit(page("a"), via: .suggestionTap)
        #expect(steps == ["play", "load"])
    }

    // Enter opens a page without a tap.
    @Test func aSubmitRecordsNoHapticEvent() {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        #expect(env.ui.open(.search, animated: false))
        env.submit(page("a"), via: .searchSubmit)
        let submit = env.haptics.records.filter { $0.interaction == .searchSubmit }
        #expect(submit.count == 1)
        #expect(submit.compactMap(\.event).isEmpty)
        #expect(sink.played.isEmpty)
    }
    #endif

    @Test func clearingDataPreparesItsHapticBeforeTheRemoval() async {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        await env.clearBrowsingData()
        #expect(sink.calls == [.prepare(Theme.Haptic.success), .play(Theme.Haptic.success)])
    }

    // A snapshot that comes back while the deck moves is stored once it rests, on the turn after the rest report, so
    // its thumbnail and tint writes stay out of the motion's frames and off the frame that lands a switch.
    @Test func snapshotWorkWaitsForTheDeckToRest() async throws {
        let env = makeEnvironment()
        var ran = 0
        env.whenDeckRests { ran += 1 }
        #expect(ran == 1)
        env.deckMotionChanged(moving: true)
        env.whenDeckRests { ran += 1 }
        env.whenDeckRests { ran += 1 }
        #expect(ran == 1)
        env.deckMotionChanged(moving: false)
        #expect(ran == 1)
        try await waitUntil { ran == 3 }
    }

    // The at-rest work runs on the turn after the switch's, never inside it, and a motion before that turn keeps it
    // waiting.
    @Test func restWorkRunsOnTheTurnAfterTheSwitch() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.open(page("b"))
        let a = env.browser.tabs[0].id
        var seenActive: [Tab.ID?] = []
        env.deckMotionChanged(moving: true)
        env.whenDeckRests { seenActive.append(env.browser.activeTabID) }
        env.flickedTo(a)
        env.deckMotionChanged(moving: false)
        #expect(seenActive.isEmpty)
        env.deckMotionChanged(moving: true)
        await Task { }.value
        #expect(seenActive.isEmpty)
        env.deckMotionChanged(moving: false)
        try await waitUntil { seenActive == [a] }
    }

    // A rest in the browser arms the neighbours' warm-up, a motion or a touch's first move cancels it, and a rest
    // re-arms it once.
    @Test func aRestArmsTheWarmUpAndAMotionCancelsIt() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.deckMotionChanged(moving: false)
        try await waitUntil { env.isWarmArmed }
        env.deckMotionChanged(moving: true)
        #expect(!env.isWarmArmed)
        env.deckMotionChanged(moving: false)
        try await waitUntil { env.isWarmArmed }
        env.cancelWarmUp()
        #expect(!env.isWarmArmed)
        env.ui.setDeck(1, animated: false)
        env.deckMotionChanged(moving: false)
        await Task { }.value
        #expect(!env.isWarmArmed)
    }

    // A warm-up armed by a landing fires 0.5 s later; a '+' or chevron tap inside that window moves nothing, so the
    // fire re-checks the browsing gate and builds nothing under the sheet's rise. Mutant: a fire that only checks the
    // gate at arm time builds the cold neighbour with the sheet up.
    @Test func aWarmUpArmedBeforeASheetOpensBuildsNothing() async throws {
        let env = makeEnvironment()
        for index in 0..<8 {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        env.showTab(tabs[2], via: .deckCardTap)
        env.deckMotionChanged(moving: false)
        try await waitUntil { env.isWarmArmed }
        env.ui.open(.search, animated: false)
        env.fireWarmUp()
        #expect(!env.isWarmArmed)
        #expect(env.pool.liveController(for: tabs[1]) == nil)
        env.ui.close(animated: false)
        env.deckMotionChanged(moving: false)
        try await waitUntil { env.isWarmArmed }
        env.fireWarmUp()
        #expect(env.pool.liveController(for: tabs[1]) != nil)
    }

    // Rest, motion, rest inside one turn queue two rest turns with no cancel between them; the second re-arms the
    // warm-up and cancels the Task the first armed, so no orphan fires mid-gesture. The probe runs on the main actor
    // between the two rest turns and reads the first Task. Mutant: arming over the first Task leaves it alive.
    @Test func aSecondRestCancelsTheFirstWarmUp() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.deckMotionChanged(moving: false)
        env.deckMotionChanged(moving: true)
        let probe = Task { env.warmUp }
        env.deckMotionChanged(moving: false)
        let first = try #require(await probe.value)
        await Task { }.value
        #expect(first.isCancelled)
        #expect(env.isWarmArmed && env.warmUp?.isCancelled == false)
    }

    // Eight tabs over a pool of six: the active tab's cold deck neighbour is made live by the warm-up, its live one
    // kept, and a tab two away stays cold. Mutant: no preparation leaves the neighbour nil.
    @Test func warmingNeighboursMakesThemLive() {
        let env = makeEnvironment()
        for index in 0..<8 {
            env.open(page("\(index)"))
        }
        let tabs = env.browser.tabs.map(\.id)
        env.showTab(tabs[2], via: .deckCardTap)
        #expect(env.pool.liveController(for: tabs[0]) == nil && env.pool.liveController(for: tabs[1]) == nil)
        let kept = env.pool.liveController(for: tabs[3])
        #expect(kept != nil)
        env.prepareDeckNeighbours()
        #expect(env.pool.liveController(for: tabs[1]) != nil)
        #expect(env.pool.liveController(for: tabs[3]) === kept)
        #expect(env.pool.liveController(for: tabs[0]) == nil)
    }

    // The zoom-out keeps the live page in its card, so the tap's snapshot waits for the deck to rest instead of
    // sharing the tap's first frame.
    @Test func theTabStackTapRequestsItsSnapshotOnceTheZoomOutRests() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        let active = env.browser.activeTabID!
        var captures: [Tab.ID] = []
        env.onCaptureRequested = { captures.append($0) }
        env.showSwitcher(via: .tabStackTap)
        #expect(env.ui.deckProgress == 1)
        #expect(captures.isEmpty)
        env.deckMotionChanged(moving: true)
        #expect(captures.isEmpty)
        env.deckMotionChanged(moving: false)
        #expect(captures.isEmpty)
        try await waitUntil { captures == [active] }
    }

    @Test func restorePlaysOneHapticAndCapturesOnce() {
        let env = makeEnvironment()
        env.open(page("a"))
        env.archive(env.browser.activeTabID!)
        env.open(page("b"))
        let outgoing = env.browser.activeTabID!
        env.ui.setDeck(1, animated: false)
        #expect(env.ui.open(.archive))
        var captures: [Tab.ID] = []
        env.onCaptureRequested = { captures.append($0) }

        env.restore(env.browser.archived[0].id)

        #expect(env.haptics.records.map(\.interaction) == [.archiveRestore])
        #expect(captures == [outgoing])
        #expect(env.ui.deckProgress == 0)
    }
}

@Suite(.serialized)
struct OutgoingSnapshotTests {
    @Test func switchingTabsSnapshotsOutgoingTab() async throws {
        let env = makeEnvironment()
        env.open(page("b"))
        env.open(URL(string: "about:blank")!)
        let a = env.browser.activeTabID!
        let controller = env.activeController!

        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.isHidden = false
        await loadAndFinish(controller, html: "<body style='background:#2e86de'>a</body>", base: "https://example.test/a")
        #expect(env.snapshots.thumbnail(for: a).image == nil)

        env.activatePreviousTab()

        let deadline = ContinuousClock.now + .seconds(2)
        while env.snapshots.thumbnail(for: a).image == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(env.snapshots.thumbnail(for: a).image != nil)
    }

    // Every activation retains the active tab, its deck neighbours and the previous tab, and preloads the neighbours,
    // so a swipe onto one finds its cover decoded whatever the budget evicted.
    @Test func activatingATabRetainsAndPreloadsItsNeighbours() async throws {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        env.open(page("a"))
        env.open(page("b"))
        env.open(page("c"))
        let ids = env.browser.tabs.map(\.id)
        for id in ids {
            env.snapshots.store(picture(), for: id)
        }
        await env.snapshots.flush()
        env.snapshots.trim(keeping: [])
        #expect(env.snapshots.decodedCount == 0)
        env.pageTo(ids[1])
        try await waitUntil { ids.allSatisfy { env.snapshots.thumbnail(for: $0).image != nil } }
        for _ in 0...Theme.Snapshot.spareDecoded {
            env.snapshots.store(picture(), for: UUID())
        }
        for id in ids {
            #expect(env.snapshots.thumbnail(for: id).image != nil)
        }
        #expect(env.snapshots.thumbnail(for: env.browser.previousTabID!).image != nil)
    }

    // A submit activates through adoptSubmitted, never attachActiveController: it still retains the new tab's
    // neighbour and the previous tab.
    @Test func aSubmitRetainsThePreviousTabsPicture() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.open(page("b"))
        env.open(page("c"))
        let (a, b, c) = (env.browser.tabs[0].id, env.browser.tabs[1].id, env.browser.tabs[2].id)
        env.pageTo(b)
        env.pageTo(a)
        env.snapshots.store(picture(), for: c)
        env.snapshots.store(picture(), for: a)
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://submit.test/page")!, via: .searchSubmit)
        env.ui.submitHidden()
        #expect(env.browser.previousTabID == a)
        for _ in 0...Theme.Snapshot.spareDecoded {
            env.snapshots.store(picture(), for: UUID())
        }
        #expect(env.snapshots.thumbnail(for: a).image != nil)
        #expect(env.snapshots.thumbnail(for: c).image != nil)
    }

    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    }

    @Test func storedSnapshotRecordsCurrentTint() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "about:blank")!)
        let id = env.browser.activeTabID!
        let controller = env.activeController!

        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.isHidden = false
        await loadAndFinish(
            controller, html: "<meta name='theme-color' content='#27ae60'><body>g</body>", base: "https://example.test/g")
        try await waitUntil { controller.webView.themeColor != nil }
        #expect(env.browser.tabs[0].tint == nil)

        env.captureSnapshot(of: id)
        try await waitUntil { env.snapshots.thumbnail(for: id).image != nil }

        let tint = try #require(env.browser.tabs[0].tint)
        #expect(abs(tint.red - 0x27 / 255) < 0.01)
        #expect(abs(tint.green - 0xAE / 255) < 0.01)
        #expect(abs(tint.blue - 0x60 / 255) < 0.01)
    }
}

struct SubmitTests {
    private static let target = URL(string: "https://submit.test/page")!
    private static let landed = URL(string: "https://submit.test/landed")!

    private func submitted() -> (env: AppEnvironment, outgoing: Tab.ID) {
        let env = makeEnvironment()
        env.open(page("a"))
        let outgoing = env.browser.activeTabID!
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.target, via: .searchSubmit)
        return (env, outgoing)
    }

    private func fired(_ env: AppEnvironment) -> [Interaction] {
        env.haptics.records.map(\.interaction)
    }

    private func controller(onHost host: String, in env: AppEnvironment) throws -> WebTabController {
        try #require(env.pool.controllers(onHost: host).first)
    }

    private func finish(_ controller: WebTabController, at url: URL, html: String) async throws {
        controller.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        try await waitUntil { controller.hasSettled && controller.webView.url == url }
    }

    @Test func submitStartsTheLoadAtOnceAndSwitchesOnlyAtTheHiddenStep() throws {
        let (env, outgoing) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        #expect(controller.isLoading)
        #expect(env.browser.activeTabID == outgoing)
        #expect(env.activeController?.tabID == outgoing)
        #expect(!env.browser.tabs.contains { $0.id == controller.tabID })
        #expect(fired(env) == [.searchSubmit])

        env.ui.submitHidden()

        #expect(env.browser.activeTabID == controller.tabID)
        #expect(env.activeController === controller)
        #expect(env.browser.tabs.last?.id == controller.tabID)
        #expect(fired(env) == [.searchSubmit])
    }

    @Test func theSubmittedControllerIsHandedOverAtGo() throws {
        let env = makeEnvironment()
        env.open(page("a"))
        var handed: [WebTabController] = []
        env.onSubmitted = { handed.append($0) }
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.target, via: .searchSubmit)
        let controller = try controller(onHost: "submit.test", in: env)
        #expect(handed.count == 1)
        #expect(handed.first === controller)
        #expect(controller.isLoading)
    }

    @Test func onlyTheTabASubmitActivatesCutsInAndOnlyOnce() throws {
        let (env, outgoing) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        #expect(!env.takeCutIn(controller))
        env.ui.submitHidden()
        let previous = try #require(env.pool.liveController(for: outgoing))
        #expect(!env.takeCutIn(previous))
        #expect(env.takeCutIn(controller))
        #expect(!env.takeCutIn(controller))
    }

    @Test func aCancelledSubmitNeverCutsIn() throws {
        let (env, _) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        #expect(env.ui.open(.search))
        #expect(!env.takeCutIn(controller))
    }

    @Test func cancellingLeavesTheNewTabLoadingBehindTheOldOne() throws {
        let (env, outgoing) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)

        #expect(env.ui.open(.search))
        env.ui.submitHidden()

        #expect(env.browser.activeTabID == outgoing)
        #expect(env.activeController?.tabID == outgoing)
        #expect(env.browser.tabs.map(\.id).contains(controller.tabID))
        #expect(env.pool.liveController(for: controller.tabID) === controller)
        #expect(controller.isLoading)
        #expect(fired(env) == [.searchSubmit])
    }

    @Test func aPageFinishedBeforeTheHiddenStepIsRecordedWhenItsTabAppears() async throws {
        let (env, _) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        try await finish(controller, at: Self.landed, html: "<p>e</p>")
        #expect(env.history.entries.first?.url == Self.landed)
        #expect(!env.browser.tabs.contains { $0.id == controller.tabID })

        env.ui.submitHidden()

        let tab = try #require(env.browser.activeTab)
        #expect(tab.id == controller.tabID)
        #expect(tab.url == Self.landed)
    }

    @Test func aTitleSetAfterAnEarlyFinishIsTheOneRecordedAtTheHiddenStep() async throws {
        let (env, _) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        try await finish(
            controller, at: Self.landed,
            html: "<script>addEventListener('load', () => setTimeout(() => { document.title = 'Late' }, 50))</script>")
        try await waitUntil { controller.title == "Late" }

        env.ui.submitHidden()

        #expect(env.browser.activeTab?.title == "Late")
    }

    @Test func aPageFinishedBeforeACancelRecordsUrlTitleAndTintInTheBackground() async throws {
        let (env, outgoing) = submitted()
        let controller = try controller(onHost: "submit.test", in: env)
        try await finish(
            controller, at: Self.landed,
            html: "<meta name='theme-color' content='#27ae60'><title>Background</title><p>b</p>")
        try await waitUntil { controller.title == "Background" && controller.webView.themeColor != nil }

        #expect(env.ui.open(.search))

        #expect(env.browser.activeTabID == outgoing)
        let tab = try #require(env.browser.tabs.first { $0.id == controller.tabID })
        #expect(tab.url == Self.landed)
        #expect(tab.title == "Background")
        let tint = try #require(tab.tint)
        #expect(abs(tint.red - 0x27 / 255.0) < 0.02)
        #expect(abs(tint.green - 0xAE / 255.0) < 0.02)
        #expect(abs(tint.blue - 0x60 / 255.0) < 0.02)
    }

    @Test func anOutgoingTabStillLoadingKeepsUpdatingItselfDuringASubmit() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "https://outgoing.test/start")!)
        let outgoing = try #require(env.activeController)
        #expect(outgoing.isLoading)
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.target, via: .searchSubmit)
        // Found by host while its load is in flight: a .test host fails to resolve, which clears its URL.
        let submitted = try controller(onHost: "submit.test", in: env)

        let outgoingLanded = URL(string: "https://outgoing.test/landed")!
        try await finish(outgoing, at: outgoingLanded, html: "<p>o</p>")

        #expect(env.browser.tabs.first { $0.id == outgoing.tabID }?.url == outgoingLanded)
        #expect(!env.browser.tabs.contains { $0.id == submitted.tabID })
        env.ui.submitHidden()
        #expect(env.browser.activeTab?.url == Self.target)
    }

    @Test func aCancelledSubmitFinishingDuringTheNextSubmitUpdatesItsBackgroundTab() async throws {
        let (env, outgoing) = submitted()
        let first = try controller(onHost: "submit.test", in: env)
        #expect(env.ui.open(.search))
        env.submit(URL(string: "https://second.test/page")!, via: .searchSubmit)
        let second = try controller(onHost: "second.test", in: env)

        #expect(env.pool.liveController(for: first.tabID) === first)
        #expect(env.browser.tabs.contains { $0.id == first.tabID })
        #expect(!env.browser.tabs.contains { $0.id == second.tabID })
        #expect(env.browser.activeTabID == outgoing)

        try await finish(first, at: Self.landed, html: "<p>f</p>")

        #expect(env.browser.tabs.first { $0.id == first.tabID }?.url == Self.landed)
        #expect(!env.browser.tabs.contains { $0.id == second.tabID })
    }

    @Test func aCancelledSubmitIntoAnEmptyStoreBecomesTheActiveTab() throws {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        env.submit(Self.target, via: .searchSubmit)
        let controller = try controller(onHost: "submit.test", in: env)

        #expect(env.ui.open(.search))

        #expect(env.browser.activeTabID == controller.tabID)
        #expect(env.activeController === controller)
        #expect(!env.takeCutIn(controller))
    }

    @Test func aSubmittedTabReplacedBeforeItPaintsDeallocatesWhenArchived() async throws {
        let env = makeEnvironment()
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://first.test/page")!, via: .searchSubmit)
        env.ui.submitHidden()
        weak let first = env.activeController
        let firstID = try #require(first?.tabID)
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://second.test/page")!, via: .searchSubmit)
        env.ui.submitHidden()
        #expect(env.activeController?.tabID != firstID)

        env.archive(firstID)

        try await waitUntil { first == nil }
    }
}

@Suite(.serialized)
struct SubmitBarIntroTests {
    // The bar keeps to Go: it arrives 50 frames after Go even over a page that is still blank. So the timer starts
    // at the swap, painted or not.
    @Test func theBarIntroStartsAtTheSwapWhetherOrNotThePageHasPainted() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://submit.test/page")!, via: .searchSubmit)
        let controller = try #require(env.pool.controllers(onHost: "submit.test").first)
        #expect(env.ui.barIntroTask == nil)

        env.ui.submitHidden()

        #expect(!controller.isRevealable)
        #expect(env.ui.isBarIntroPending)
        let task = try #require(env.ui.barIntroTask)
        await task.value
        #expect(!env.ui.isBarIntroPending)
    }

    @Test func theNextSubmitCancelsAnEarlierSubmitsBarIntro() throws {
        let env = makeEnvironment()
        env.open(page("a"))
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://first.test/page")!, via: .searchSubmit)
        env.ui.submitHidden()
        let first = try #require(env.ui.barIntroTask)
        env.ui.close(animated: false)
        #expect(env.ui.open(.search, animated: false))
        env.submit(URL(string: "https://second.test/page")!, via: .searchSubmit)

        #expect(first.isCancelled)
        #expect(env.ui.isBarIntroPending)
    }
}

@Suite(.serialized)
struct SearchSheetSubmitTests {
    private func submitTyped(_ text: String, engine: SearchEngine) throws -> (env: AppEnvironment, outgoing: Tab.ID) {
        StubSuggestProtocol.answer(text, with: "[\"\(text)\",[],[]]")
        let env = makeEnvironment()
        env.open(page("a"))
        let outgoing = env.browser.activeTabID!
        env.browser.settings.searchEngine = engine
        #expect(env.ui.open(.search, animated: false))
        let model = SearchModel(history: env.history, service: stubService(), engine: { env.browser.settings.searchEngine })
        let sheet = SearchSheetController(model: model, env: env)
        sheet.loadViewIfNeeded()
        let field = try #require(sheet.view.firstSearchField())
        field.text = text
        field.sendActions(for: .editingChanged)
        #expect(!sheet.textFieldShouldReturn(field))
        return (env, outgoing)
    }

    @Test func aTypedQuerySubmitsTheSearchUrlAndKeepsTheOldTabActive() throws {
        let (env, outgoing) = try submitTyped("swift testing", engine: .google)
        let pending = try #require(env.pool.controllers(onHost: "www.google.com").first)
        #expect(pending.url == SearchEngine.google.resultsURL(for: "swift testing"))
        #expect(env.browser.activeTabID == outgoing)
        #expect(env.ui.isSubmitting)
    }

    // The choice takes effect on the next submit; the open tab keeps the page it had.
    @Test func aTypedQuerySubmitsTheChosenEnginesUrlAndLeavesTheOpenTabAlone() throws {
        let (env, outgoing) = try submitTyped("swift testing", engine: .duckDuckGo)
        let pending = try #require(env.pool.controllers(onHost: "duckduckgo.com").first)
        #expect(pending.url == URL(string: "https://duckduckgo.com/?q=swift%20testing"))
        #expect(env.pool.controllers(onHost: "www.google.com").isEmpty)
        #expect(env.pool.liveController(for: outgoing)?.url == page("a"))
    }

    @Test func aTypedUrlSubmitsThatUrlAndKeepsTheOldTabActive() throws {
        let (env, outgoing) = try submitTyped("example.test/typed", engine: .google)
        let pending = try #require(env.pool.controllers(onHost: "example.test").first)
        #expect(pending.url == URL(string: "https://example.test/typed"))
        #expect(env.browser.activeTabID == outgoing)
        #expect(env.ui.isSubmitting)
    }
}

extension UIView {
    func firstSearchField() -> SearchField? {
        for subview in subviews {
            if let field = subview as? SearchField ?? subview.firstSearchField() {
                return field
            }
        }
        return nil
    }
}

@Suite(.serialized)
struct SiteSettingsTests {
    private func openSimulated(_ env: AppEnvironment, _ url: String) async throws -> WebTabController {
        env.open(URL(string: url)!)
        let controller = try #require(env.activeController)
        controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: url)!), responseHTML: "<p>page</p>")
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled && controller.url == URL(string: url) }
        return controller
    }

    @Test func changingASitesTrackerSettingSwitchesOnlyThatSitesTabs() async throws {
        let env = makeEnvironment()
        await env.blocker.prepare()
        let first = try await openSimulated(env, "https://first.test/")
        let second = try await openSimulated(env, "https://second.test/")
        let firstLists = first.webView.configuration.userContentController
        let secondLists = second.webView.configuration.userContentController
        #expect(env.blocker.isBlocking(firstLists) && env.blocker.isBlocking(secondLists))

        env.setSiteSettings(SiteSettings(blocksTrackers: false), forHost: "first.test")
        try await waitUntil(timeout: .seconds(10)) { !env.blocker.isBlocking(firstLists) }
        #expect(env.blocker.isBlocking(secondLists))
        #expect(env.siteSettings(forHost: "first.test") == SiteSettings(blocksTrackers: false))
        #expect(env.siteSettings(forHost: "second.test") == SiteSettings())
    }

    @Test func siteSettingsSurviveARelaunch() async {
        let directories = AppDirectories.temporary()
        let env = makeEnvironment(directories)
        env.setSiteSettings(SiteSettings(allowsJavaScript: false), forHost: "kept.test")
        await env.sites.flush()

        #expect(makeEnvironment(directories).siteSettings(forHost: "kept.test") == SiteSettings(allowsJavaScript: false))
    }

    @Test func restoringAPageAllowsTrackersOnItsSiteAndClosesTheMenu() {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        env.setSiteSettings(SiteSettings(allowsJavaScript: false), forHost: "restored.test")
        #expect(env.ui.open(.menu))

        env.setTrackerBlocking(false, forHost: "restored.test")
        #expect(env.siteSettings(forHost: "restored.test") == SiteSettings(blocksTrackers: false, allowsJavaScript: false))
        #expect(env.ui.overlay == .none)
        #expect(sink.calls == [.play(Theme.Haptic.medium)])

        #expect(env.ui.open(.menu))
        env.setTrackerBlocking(true, forHost: "restored.test")
        #expect(env.siteSettings(forHost: "restored.test") == SiteSettings(allowsJavaScript: false))
        #expect(env.ui.overlay == .none)

        env.setSiteSettings(SiteSettings(), forHost: "restored.test")
        #expect(env.sites.byHost["restored.test"] == nil)
    }

    @Test func clearingASitesDataKeepsOtherSitesData() async throws {
        let sink = RecordingHapticSink(start: .now)
        let env = makeEnvironment(hapticSink: sink)
        let cookies = env.pool.configuration.websiteDataStore.httpCookieStore
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let cleared = "cleared-\(suffix).test", kept = "kept-\(suffix).test"
        for domain in [cleared, kept] {
            await cookies.setCookie(
                HTTPCookie(properties: [.domain: domain, .path: "/", .name: "id", .value: domain, .expires: Date.distantFuture])!)
        }

        // Site Settings opens over the active tab.
        env.open(URL(string: "about:blank")!)
        await env.clearSiteData(forHost: "www.\(cleared)")

        let domains = Set(await cookies.allCookies().map(\.domain))
        #expect(!domains.contains(cleared))
        #expect(domains.contains(kept))
        #expect(sink.calls == [.prepare(Theme.Haptic.success), .play(Theme.Haptic.success)])
    }
}
