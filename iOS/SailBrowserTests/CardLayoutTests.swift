import CoreGraphics
import SwiftUI
import Testing
@testable import SailBrowser

struct CardLayoutTests {
    private let proMax = CardLayout(screen: CGSize(width: 440, height: 956))

    private func frame(_ transform: CardTransform, in layout: CardLayout) -> CGRect {
        let screen = layout.screen
        let width = screen.width * transform.scale
        let top = screen.height / 2 + transform.offset.height - screen.height * transform.scale / 2
        return CGRect(
            x: screen.width / 2 + transform.offset.width - width / 2, y: top, width: width,
            height: transform.clipHeight)
    }

    @Test(arguments: [CGSize(width: 440, height: 956), CGSize(width: 402, height: 874), CGSize(width: 393, height: 852)])
    func activeCardIsExactIdentityAtProgressZero(screen: CGSize) {
        let layout = CardLayout(screen: screen)
        for position in [CGFloat(0), 1, 2.4] {
            let transform = layout.transform(slot: 1, isActive: true, activeIndex: 1, position: position, progress: 0)
            #expect(transform.scale == 1)
            #expect(transform.offset == .zero)
            #expect(transform.corner == 0)
            #expect(transform.opacity == 1)
            #expect(transform.clipHeight == screen.height)
            #expect(transform.rotation == .zero)
        }
        let half = layout.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 0.5)
        let base = layout.cardSize.width / screen.width
        let expectedScale: CGFloat = 1 + (base - 1) * 0.5
        let expectedCorner: CGFloat = 55 + (15 - 55) * 0.5
        #expect(half.scale == expectedScale)
        #expect(half.corner == expectedCorner)
    }

    @Test func restGeometryFollowsSpec() {
        let w: CGFloat = 0.70 * 440
        #expect(abs(proMax.cardSize.width - w) < 1e-9)
        #expect(abs(proMax.cardSize.height - 0.65 * 956) < 1e-9)
        #expect(abs(proMax.stride - 0.80 * w) < 1e-9)

        let focused = proMax.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 1)
        let card = frame(focused, in: proMax)
        #expect(abs(card.minX - 0.205 * 440) < 1e-9)
        #expect(abs(card.minY - 0.188 * 956) < 1e-9)
        #expect(abs(card.width - w) < 1e-9)
        #expect(abs(card.maxY - (0.188 + 0.65) * 956) < 1e-9)
        #expect(focused.corner == 15)
        #expect(focused.titleOpacity == 1)
        #expect(abs(proMax.slotCenter.x - card.midX) < 1e-9)
        #expect(abs(proMax.slotCenter.y - card.midY) < 1e-9)

        let second = proMax.transform(slot: 0, isActive: false, activeIndex: 2, position: 2, progress: 1)
        let secondFrame = frame(second, in: proMax)
        let unscaledLeft: CGFloat = 0.205 * 440 - 0.237 * w - 0.039 * w
        #expect(abs(second.scale - 0.70 * 0.93) < 1e-9)
        #expect(abs(secondFrame.midX - (unscaledLeft + w / 2)) < 1e-9)
        #expect(abs(secondFrame.midY - card.midY) < 1e-9)
        #expect(abs(secondFrame.height - 0.93 * proMax.cardSize.height) < 1e-9)
        #expect(second.titleOpacity == 0)

        let between = proMax.transform(slot: 0, isActive: false, activeIndex: 1, position: 1.5, progress: 1)
        #expect(abs(between.scale - 0.70 * 0.955) < 1e-9)
        let halfway = proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: 1.5, progress: 1)
        #expect(abs(halfway.titleOpacity - 0.5) < 1e-9)
    }

    @Test func opensFocusedOnLeftNeighborWithActivePeekingRight() {
        #expect(proMax.openPosition(activeIndex: 2) == 1)
        #expect(proMax.openPosition(activeIndex: 0) == 0)
        let active = proMax.transform(
            slot: 2, isActive: true, activeIndex: 2, position: proMax.openPosition(activeIndex: 2), progress: 1)
        #expect(abs(frame(active, in: proMax).minX - 336) < 1)
        let only = proMax.transform(
            slot: 0, isActive: true, activeIndex: 0, position: proMax.openPosition(activeIndex: 0), progress: 1)
        #expect(abs(frame(only, in: proMax).minX - 90) < 1)
    }

    @Test func newerCardOverlapsFocusedRightEdge() {
        let focused = frame(
            proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: 1, progress: 1), in: proMax)
        let newer = proMax.transform(slot: 2, isActive: true, activeIndex: 2, position: 1, progress: 1)
        let newerFrame = frame(newer, in: proMax)
        #expect(newerFrame.minX < focused.maxX)
        #expect(abs(focused.maxX - newerFrame.minX - 0.20 * proMax.cardSize.width) < 1e-9)
        #expect(newerFrame.minX < 440)
        #expect(
            newer.zIndex > proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: 1, progress: 1).zIndex)
    }

    @Test func olderCardsDepthScaleAndGrowTiltedFromButton() {
        let first = proMax.transform(slot: 1, isActive: false, activeIndex: 3, position: 2, progress: 1)
        let second = proMax.transform(slot: 0, isActive: false, activeIndex: 3, position: 2, progress: 1)
        #expect(abs(first.scale / proMax.restScale - 0.98) < 1e-9)
        #expect(abs(second.scale / proMax.restScale - 0.93) < 1e-9)
        #expect(first.rotation == .zero)

        let button = proMax.tabStackButtonFrame
        #expect(button == CGRect(x: 46 - 22, y: 956 - 45 - 20, width: 44, height: 40))
        let open = proMax.openPosition(activeIndex: 2)
        let neighbor = proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: open, progress: 0.001)
        let neighborFrame = frame(neighbor, in: proMax)
        #expect(hypot(neighborFrame.midX - button.midX, neighborFrame.midY - button.midY) < 2)
        #expect(abs(neighborFrame.width - Theme.Metrics.tabStackThumbnailSize.width) < 1)
        #expect(abs(neighbor.rotation.degrees + 7) < 0.1)
        #expect(neighbor.opacity > 0)
        #expect(neighbor.opacity < 0.01)
        let older = proMax.transform(slot: 0, isActive: false, activeIndex: 2, position: open, progress: 0.001)
        #expect(abs(older.rotation.degrees - 7) < 0.1)
        let visible = proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: open, progress: 0.15)
        #expect(visible.opacity == 1)
        let hidden = proMax.transform(slot: 1, isActive: false, activeIndex: 2, position: open, progress: 0)
        #expect(hidden.opacity == 0)
    }

    @Test func otherCardsHiddenAtProgressZeroButBuilt() {
        let right = proMax.transform(slot: 2, isActive: false, activeIndex: 1, position: 1, progress: 0)
        let active = proMax.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 0)
        #expect(right.opacity == 0)
        #expect(right.zIndex < active.zIndex)
        let moving = proMax.transform(slot: 2, isActive: false, activeIndex: 1, position: 1, progress: 0.3)
        #expect(moving.opacity == 1)
    }

    @Test func newerCardsZoomRigidlyAboutTheActiveCard() {
        for t in [CGFloat(0.2), 0.6] {
            let active = frame(
                proMax.transform(slot: 1, isActive: true, activeIndex: 1, position: 0, progress: t), in: proMax)
            let newer = frame(
                proMax.transform(slot: 2, isActive: false, activeIndex: 1, position: 0, progress: t), in: proMax)
            let restActive = frame(
                proMax.transform(slot: 1, isActive: true, activeIndex: 1, position: 0, progress: 1), in: proMax)
            let restNewer = frame(
                proMax.transform(slot: 2, isActive: false, activeIndex: 1, position: 0, progress: 1), in: proMax)
            let zoom = active.width / restActive.width
            #expect(abs(newer.width / restNewer.width - zoom) < 1e-9)
            #expect(abs((newer.minX - active.minX) - zoom * (restNewer.minX - restActive.minX)) < 1e-9)
            #expect(abs((newer.minY - active.minY) - zoom * (restNewer.minY - restActive.minY)) < 1e-9)
        }
    }

    @Test func zoomingActiveCardRidesAboveNewerCards() {
        let zooming = proMax.transform(slot: 0, isActive: true, activeIndex: 0, position: 2, progress: 0.5)
        let newer = proMax.transform(slot: 2, isActive: false, activeIndex: 0, position: 2, progress: 0.5)
        #expect(zooming.zIndex > newer.zIndex)
        let resting = proMax.transform(slot: 0, isActive: true, activeIndex: 0, position: 2, progress: 1)
        #expect(resting.zIndex == 0)
    }

    // The pair's cards overlap by 12 - 44 * arm pt until the pair arms past 0.273 (equal cards a stride of 428 apart
    // on a 440 pt screen), so the page under the finger draws over its neighbours there: no neighbour's edge over the
    // live page at the start of a swipe, none over the landed card at the end of one. Armed, a gap separates them.
    @Test func thePageUnderTheFingerDrawsOverItsNeighboursWhileThePairOverlaps() {
        let pair = { (p: CGFloat, arm: CGFloat) in proMax.pairTransform(offset: p, fromStack: 0, arm: arm, safeTop: 59) }
        let page = pair(0, 0.1), newer = pair(1, 0.1), older = pair(-1, 0.1)
        #expect(frame(newer, in: proMax).minX < frame(page, in: proMax).maxX)
        #expect(frame(older, in: proMax).maxX > frame(page, in: proMax).minX)
        #expect(newer.zIndex < page.zIndex && older.zIndex < page.zIndex)
        #expect(pair(-0.3, 0.1).zIndex > pair(0.7, 0.1).zIndex)
        #expect(frame(pair(1, 1), in: proMax).minX > frame(pair(0, 1), in: proMax).maxX)
        #expect(proMax.pairTransform(offset: -1, fromStack: 0.5, arm: 1, safeTop: 59).zIndex > page.zIndex)
    }

    // A left card dims 0.15 a slot to 0.3, with the zoom; the focused card and the newer ones have none.
    @Test func leftCardsDimByTheirDistance() {
        let dim = { (slot: CGFloat, progress: CGFloat) in
            proMax.transform(slot: slot, isActive: false, activeIndex: 4, position: 3, progress: progress).dim
        }
        #expect(abs(dim(2, 1) - 0.15) < 1e-9)
        #expect(abs(dim(1, 1) - 0.3) < 1e-9)
        #expect(abs(dim(0, 1) - 0.3) < 1e-9)
        #expect(dim(3, 1) == 0 && dim(4, 1) == 0)
        #expect(abs(dim(2, 0.5) - 0.075) < 1e-9)
    }

    @Test func snapTargetDoesNotDoubleCountDrag() {
        let stride = proMax.stride
        let slots: [CGFloat] = [0, 1, 2, 3, 4]
        #expect(proMax.snapTarget(start: 1, translation: -1.0 * stride, velocity: 0, slots: slots).index == 2)
        #expect(proMax.snapTarget(start: 1, translation: -0.3 * stride, velocity: 0, slots: slots).index == 1)
        #expect(proMax.snapTarget(start: 3, translation: -6 * stride, velocity: 0, slots: slots).index == 4)
        #expect(proMax.snapTarget(start: 1, translation: 4 * stride, velocity: 0, slots: slots).index == 0)
    }

    @Test func stretchedBandsOnlyPastTheEnds() {
        let stretch = Theme.Gesture.deckStretch
        #expect(proMax.stretched(2, count: 5) == 2)
        #expect(proMax.stretched(-1, count: 5) == Magnet.rubberBand(-1, stretch: stretch))
        #expect(proMax.stretched(5, count: 5) == 4 + Magnet.rubberBand(1, stretch: stretch))
        #expect(proMax.stretched(-100, count: 5) > -stretch)
        #expect(proMax.stretched(104, count: 5) < 4 + stretch)
    }

    @Test func visibleRangeCoversBothEndsOfAnimation() {
        #expect(proMax.visibleRange(from: 0, to: 5, count: 8) == 0...6)
        #expect(proMax.visibleRange(from: 3, to: 3, count: 8) == 0...4)
        #expect(proMax.visibleRange(from: 2.5, to: 2.5, count: 3) == 0...2)
    }

    @Test func cardHitTestPrefersTopmostCardInsideTheCrop() {
        let center = proMax.slotCenter
        let slot = { (index: Int) in CGFloat(index) }
        #expect(proMax.card(at: center, activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == 1)
        #expect(proMax.card(at: CGPoint(x: 25, y: center.y), activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == 0)
        #expect(proMax.card(at: CGPoint(x: 350, y: center.y), activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == 2)
        #expect(proMax.card(at: CGPoint(x: 430, y: center.y), activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == 2)
        #expect(proMax.card(at: CGPoint(x: center.x, y: 20), activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == nil)
        #expect(
            proMax.card(at: CGPoint(x: center.x, y: 820), activeIndex: 1, position: 1, progress: 1, olderProgress: 1, in: 0...2, slot: slot) == nil)
    }

    // Mid-zoom the cards are drawn where the zoom has them, the active card above the rest, so a tap takes the card
    // under the finger then, not the one the finished switcher will put there.
    @Test func cardHitTestFollowsTheDrawnZoom() {
        let center = proMax.slotCenter
        let slot = { (index: Int) in CGFloat(index) }
        let hit = { (x: CGFloat, progress: CGFloat) in
            proMax.card(
                at: CGPoint(x: x, y: center.y), activeIndex: 1, position: 1, progress: progress,
                olderProgress: progress, in: 0...2, slot: slot)
        }
        #expect(hit(60, 0.3) == 1)
        #expect(hit(400, 0.3) == 1)
        #expect(hit(60, 1) == 0)
        #expect(hit(400, 1) == 2)
        let zooming = proMax.transform(slot: 1, isActive: true, activeIndex: 1, position: 1, progress: 0.3)
        let drawnBottom = frame(zooming, in: proMax).maxY
        #expect(
            proMax.card(
                at: CGPoint(x: center.x, y: drawnBottom + 1), activeIndex: 1, position: 1, progress: 0.3,
                olderProgress: 0.3, in: 0...2, slot: slot) != 1)
    }

    @Test func frozenOrderKeepsSlotsAndAppendsNewTabs() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        #expect(CardLayout.frozenOrder([a, b, c], current: [c, a, b, d]) == [a, b, c, d])
        #expect(CardLayout.frozenOrder([a, b, c], current: [c, a]) == [a, c])
    }

    private func elapsed(reaching fraction: Double, on spring: Spring) -> TimeInterval {
        var low = 0.0
        var high = spring.settlingDuration
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if spring.value(target: 1.0, time: mid) < fraction { low = mid } else { high = mid }
        }
        return low
    }

    @Test func throwClosesTheGapFromTheCommitInstant() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let commit = ContinuousClock.now
        let plan = proMax.archivePlan(removing: 2, ids: [a, b, c, d], shift: [:], position: 2, start: commit)
        #expect(plan.shift == [d: -1])
        #expect(plan.motion.to == 2)
        #expect(plan.motion.curve.start == commit)
        let atCommit = plan.motion.presented(at: commit)
        #expect(atCommit.position == 2)
        #expect(atCommit.shift == [d: 1])
        let landed = plan.motion.presented(at: commit + .seconds(0.18))
        #expect(landed.shift[d]! < 0.1)

        let left = proMax.archivePlan(removing: 0, ids: [a, b, c], shift: [:], position: 2, start: commit)
        #expect(left.shift == [b: -1, c: -1])
        #expect(left.motion.from == 2)
        #expect(left.motion.to == 1)
    }

    @Test func reopeningMidZoomInRetargetsFromThePresentedPosition() throws {
        let start = ContinuousClock.now
        let zoomIn = DeckMotion(from: 1, to: 2, shift: [:], velocity: 0, start: start, spring: DeckSnap.zoom)
        let reopenTime = start + .seconds(elapsed(reaching: 0.4, on: DeckSnap.zoom))
        let reopen = try #require(zoomIn.retargeted(to: 1, at: reopenTime, spring: DeckSnap.zoom))
        #expect(abs(reopen.from - 1.4) < 1e-6)
        #expect(reopen.to == 1)
        #expect(reopen.curve.start == reopenTime)
        #expect(abs(reopen.presented(at: reopenTime).position - 1.4) < 1e-6)
        let step = reopenTime + .seconds(0.0001)
        let carried = reopen.presented(at: step).position - 1.4
        let inFlight = zoomIn.presented(at: step).position - 1.4
        #expect(inFlight > 0)
        #expect(abs(carried - inFlight) < 1e-5)

        let settled = start + .seconds(DeckSnap.zoom.settlingDuration + 0.01)
        #expect(zoomIn.retargeted(to: 1, at: settled, spring: DeckSnap.zoom) == nil)
    }
}
