import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// SwiftUI has a Tab of its own.
private typealias Tab = SailBrowser.Tab

struct MemoryPressureTests {
    // Eight tabs over a pool of six, visited in the order given, every tab with a decoded picture; a private tab's is
    // held in memory.
    private func eightTabs(visiting: [Int], privateTab: Int? = nil) -> (env: AppEnvironment, ids: [Tab.ID]) {
        let env = makeEnvironment()
        for index in 0..<8 {
            env.open(page("\(index)"), isPrivate: index == privateTab)
        }
        let ids = env.browser.tabs.map(\.id)
        for index in visiting {
            env.showTab(ids[index], via: .deckCardTap)
        }
        for (index, id) in ids.enumerated() {
            if index == privateTab {
                env.snapshots.hold(solidImage(.red, side: 4), for: id)
            } else {
                env.snapshots.store(solidImage(.red, side: 4), for: id)
            }
        }
        return (env, ids)
    }

    // The switcher open on the fifth of eight tabs has built the cards around the deck's position (CardLayout.span):
    // a warning keeps every built card's picture and the previous tab's, and drops the rest. Mutant: trimming to the
    // active tab and its neighbours blanks the two older built cards until a deck move rebuilds them.
    @Test func aWarningKeepsTheDecksBuiltCardsAndThePreviousTab() {
        let (env, ids) = eightTabs(visiting: [4])
        env.ui.setDeck(1, animated: false)
        env.ui.deck.jump(to: 4, shift: [:])
        let span = env.ui.deck.span.clamped(to: 0...7)
        #expect(span.lowerBound < 3 && span.contains(4))
        #expect(env.browser.previousTabID == ids[7])
        #expect(env.snapshots.decodedCount == 8)

        env.memoryWarning()

        let kept = Set(span.map { ids[$0] }).union([ids[3], ids[5], ids[7]])
        for (index, id) in ids.enumerated() {
            #expect((env.snapshots.thumbnail(for: id).image != nil) == kept.contains(id), "tab \(index)")
        }
        #expect(env.snapshots.decodedCount == kept.count)
    }

    // With the switcher closed the deck rests on the active tab, whose built cards add nothing beyond its neighbours:
    // the active tab, both neighbours and the previous tab keep their pictures, a private neighbour's goes (it lives
    // in memory only), and the rest drop to their small pictures. Mutant: the previous tab's picture goes too.
    @Test func aWarningWithTheSwitcherClosedKeepsTheNeighbourhoodAndThePreviousTab() async throws {
        let (env, ids) = eightTabs(visiting: [5, 1], privateTab: 2)
        env.ui.deck.jump(to: 1, shift: [:])
        #expect(env.browser.previousTabID == ids[5])
        let stored = ids.enumerated().filter { $0.offset != 2 }.map(\.element)
        try await waitUntil { stored.allSatisfy { env.snapshots.thumbnail(for: $0).small != nil } }
        #expect(env.snapshots.decodedCount == 8)

        env.memoryWarning()

        let kept: Set = [ids[0], ids[1], ids[5]]
        for (index, id) in ids.enumerated() {
            #expect((env.snapshots.thumbnail(for: id).image != nil) == kept.contains(id), "tab \(index)")
        }
        for id in stored {
            #expect(env.snapshots.thumbnail(for: id).small != nil)
        }
        #expect(env.snapshots.decodedCount == kept.count)
    }

    // A card whose full picture is gone draws its small one until the full one is decoded again. Mutant: the old body
    // draws the tint (blue here) whenever the full picture is nil.
    @Test func aCardWithoutItsFullPictureDrawsItsSmallOne() throws {
        let thumbnail = Thumbnail()
        thumbnail.small = solidImage(.red, side: 4)
        let tab = Tab(
            id: UUID(), url: page("a"), title: "a", isPinned: false, prefersDesktop: false, createdAt: .now,
            lastActiveAt: .now, tint: CodableColor(red: 0, green: 0, blue: 1))
        let card = CardSnapshot(thumbnail: thumbnail, tab: tab, layout: CardLayout(screen: CGSize(width: 440, height: 956)))
            .frame(width: 8, height: 8)
            .environment(makeEnvironment())
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        #expect(pixel(image, at: CGPoint(x: 0.5, y: 0.5)) == [255, 0, 0])
    }

    // A capture in flight when the warning lands stores its picture afterwards, inside the budget: no more decoded
    // pictures than the retained set (the active tab, its neighbours and the previous tab) plus the spare.
    @Test func aCaptureInFlightAtTheWarningStoresWithinTheBudget() async throws {
        let (env, ids) = eightTabs(visiting: [4])
        let controller = try #require(env.activeController)
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        controller.webView.frame = window.bounds
        window.addSubview(controller.webView)
        window.isHidden = false
        await loadAndFinish(controller, html: "<body style='background:#2e86de'>a</body>", base: "https://example.test/a")
        let before = env.snapshots.thumbnail(for: ids[4]).image

        env.captureSnapshot(of: ids[4])
        env.memoryWarning()

        try await waitUntil { env.snapshots.thumbnail(for: ids[4]).image !== before }
        #expect(env.snapshots.thumbnail(for: ids[4]).image != nil)
        let retained: Set = [ids[3], ids[4], ids[5], ids[7]]
        #expect(env.snapshots.decodedCount <= retained.count + Theme.Snapshot.spareDecoded)
    }

    // Three finishes inside the settle delay (a redirect chain, a reload storm) leave one pending capture, which
    // captures once. Mutant: a Task per finish captures three times.
    @Test func finishesInsideTheSettleDelayCaptureOnce() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        let controller = try #require(env.activeController)
        let id = controller.tabID
        try await waitUntil { controller.hasSettled }
        var captures: [Tab.ID] = []
        env.onCaptureRequested = { captures.append($0) }

        for _ in 0..<3 {
            controller.onFinish!(page("a"), "a")
        }

        #expect(env.settledSnapshotTasks.count == 1)
        _ = await env.settledSnapshotTasks[id]!.result
        #expect(captures == [id])
        #expect(env.settledSnapshotTasks.isEmpty)
    }

    // A tab removed inside the delay captures nothing: its pending capture goes with it. Mutant: the Task fires and
    // asks for a capture of a tab that is gone.
    @Test func aTabRemovedInsideTheSettleDelayCapturesNothing() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        env.open(page("b"))
        let controller = try #require(env.activeController)
        let id = controller.tabID
        try await waitUntil { controller.hasSettled }
        var captures: [Tab.ID] = []
        env.onCaptureRequested = { captures.append($0) }
        controller.onFinish!(page("b"), "b")
        let pending = try #require(env.settledSnapshotTasks[id])

        env.archive(id)

        #expect(pending.isCancelled)
        #expect(env.settledSnapshotTasks[id] == nil)
        _ = await pending.result
        #expect(!captures.contains(id))
    }

    // A page loading again when the delay ends is not settled, so the pending capture takes nothing. Mutant: a capture
    // at the delay's end whatever the page is doing.
    @Test func anUnsettledPageAtTheDelaysEndCapturesNothing() async throws {
        let html = Data(String(repeating: "<p>held</p>", count: 200).utf8)
        let server = try await LocalPageServer { _ in "" }
        defer { withExtendedLifetime(server) {} }
        server.routes["/held"] = { _ in
            LocalPageServer.Reply(
                headers: ["Content-Type": "text/html", "Content-Length": String(html.count)],
                body: html[..<(html.count / 2)], holdsOpen: true)
        }
        let env = makeEnvironment()
        env.open(page("a"))
        let controller = try #require(env.activeController)
        let id = controller.tabID
        try await waitUntil { controller.hasSettled }
        controller.load(server.url("/held"))
        try await waitUntil { !controller.hasSettled }
        var captures: [Tab.ID] = []
        env.onCaptureRequested = { captures.append($0) }

        controller.onFinish!(page("a"), "a")
        let pending = try #require(env.settledSnapshotTasks[id])
        _ = await pending.result

        #expect(!captures.contains(id))
        #expect(env.settledSnapshotTasks.isEmpty)
    }

    // The spare web view returns only once both gates open: pressure ending under reduced energy builds none, energy
    // returning under pressure builds none, and the second gate opening builds one.
    @Test func theSpareReturnsOnlyWhenPressureAndReducedEnergyBothEnd() async throws {
        let stub = EnergyStub()
        let center = NotificationCenter()
        let recorder = RecordingPressure()
        let env = makeEnvironment(energy: EnergyPolicy(readings: stub.readings, center: center), pressure: recorder.relief)
        env.pool.prewarm()
        #expect(env.pool.prewarmed != nil)
        env.memoryWarning()
        #expect(env.pool.prewarmed == nil)
        stub.lowPower.withLock { $0 = true }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { env.energy.isReduced }

        recorder.relieved!()
        #expect(!env.pool.isUnderPressure)
        #expect(env.pool.prewarmed == nil)

        env.memoryWarning()
        stub.lowPower.withLock { $0 = false }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { !env.energy.isReduced }
        #expect(env.pool.isUnderPressure)
        #expect(env.pool.prewarmed == nil)

        recorder.relieved!()
        #expect(env.pool.prewarmed != nil)
    }
}
