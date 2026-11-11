import CoreGraphics
import Foundation
import Testing
@testable import SailBrowser

// The edge swipe's pure half: which tabs take it, where a touch may start and lock, the magnet that holds the page and
// the release rule. The slide itself and its haptics are checked in the running app.
struct EdgeArchiveTests {
    private let width: CGFloat = 400

    @Test func aTabWithNoBackHistoryArchivesAndAPrivateOneCloses() {
        #expect(EdgeArchive.outcome(isPinned: false, isPrivate: false, canGoBack: false) == .archive)
        #expect(EdgeArchive.outcome(isPinned: false, isPrivate: true, canGoBack: false) == .close)
    }

    @Test func backHistoryKeepsWebKitsSwipeAndAPinnedTabTakesNone() {
        #expect(EdgeArchive.outcome(isPinned: false, isPrivate: false, canGoBack: true) == nil)
        #expect(EdgeArchive.outcome(isPinned: false, isPrivate: true, canGoBack: true) == nil)
        #expect(EdgeArchive.outcome(isPinned: true, isPrivate: false, canGoBack: false) == nil)
        #expect(EdgeArchive.outcome(isPinned: true, isPrivate: false, canGoBack: true) == nil)
    }

    @Test func aTouchAnywhereInTheLeftHalfIsWatched() {
        let zone = width * Theme.Gesture.edgeArchiveZoneFraction
        #expect(EdgeArchive.startsInZone(x: 0, width: width))
        #expect(EdgeArchive.startsInZone(x: zone, width: width))
        #expect(!EdgeArchive.startsInZone(x: zone + 1, width: width))
        #expect(!EdgeArchive.startsInZone(x: -1, width: width))
    }

    @Test func aPageScrolledSidewaysScrollsBackFirst() {
        #expect(EdgeArchive.pageAtLeftEdge(offsetX: 0, leftInset: 0))
        #expect(EdgeArchive.pageAtLeftEdge(offsetX: -8, leftInset: 8))
        #expect(!EdgeArchive.pageAtLeftEdge(offsetX: 40, leftInset: 0))
    }

    @Test func itBeginsOnlyMovingRightNearHorizontal() {
        #expect(EdgeArchive.begins(translation: CGSize(width: 12, height: 0)))
        #expect(EdgeArchive.begins(translation: CGSize(width: 12, height: -6)))
        #expect(!EdgeArchive.begins(translation: CGSize(width: -12, height: 0)))
        #expect(!EdgeArchive.begins(translation: CGSize(width: 4, height: 12)))
        #expect(!EdgeArchive.begins(translation: .zero))
    }

    @Test func thePageFollowsTheFingerBetweenRestAndTheRightEdge() {
        #expect(EdgeArchive.offset(translation: 120, width: width) == 120)
        #expect(EdgeArchive.offset(translation: -30, width: width) == 0)
        #expect(EdgeArchive.offset(translation: 520, width: width) == width)
        #expect(EdgeArchive.progress(offset: 100, width: width) == 0.25)
        #expect(EdgeArchive.progress(offset: 100, width: 0) == 0)
    }

    @Test func onlyAFreePageGoesAndAFlickBackCancelsIt() {
        let flick = Theme.Gesture.edgeArchiveFlickVelocity
        #expect(EdgeArchive.completes(isFree: true, velocity: 0))
        #expect(EdgeArchive.completes(isFree: true, velocity: flick))
        #expect(!EdgeArchive.completes(isFree: true, velocity: -flick))
        #expect(!EdgeArchive.completes(isFree: false, velocity: 0))
        #expect(!EdgeArchive.completes(isFree: false, velocity: flick * 4))
    }

    // Held, the page gives less than the finger travels and never more than the hold; past the line it comes free and
    // closes on the finger; back under the line, less the hysteresis, it sticks again.
    @Test func theMagnetHoldsThePageUntilItComesFree() {
        let start = ContinuousClock.now
        var magnet = EdgeMagnet(width: width)
        let line = width * Theme.Gesture.edgeArchiveUnstickFraction
        #expect(magnet.update(translation: line - 1, at: start) == nil)
        #expect(!magnet.isFree)
        let held = magnet.offset(at: start)
        #expect(held > 0 && held < line / 2)
        #expect(held < width * Theme.Gesture.edgeArchiveHoldFraction)

        #expect(magnet.update(translation: line + 10, at: start) == .freed)
        #expect(magnet.isFree)
        #expect(magnet.offset(at: start) < line)
        let later = start + .seconds(1)
        #expect(abs(magnet.offset(at: later) - (line + 10)) < 0.1)
        #expect(magnet.isSettled(at: later))
        #expect(!magnet.isSettled(at: start + .milliseconds(20)))

        #expect(magnet.update(translation: line - 2, at: later) == nil)
        #expect(magnet.update(translation: line - Theme.Gesture.detentHysteresis - 1, at: later) == .stuck)
        #expect(!magnet.isFree)
        #expect(magnet.offset(at: later + .seconds(1)) < line / 2)
    }

    // The texture follows the finger's speed while the page is held, sharpening with the tension, and is silent once
    // the page is free or the finger rests.
    @Test func theTextureRunsOnlyWhileThePageIsHeldAndMoving() {
        let start = ContinuousClock.now
        var magnet = EdgeMagnet(width: width)
        _ = magnet.update(translation: 20, at: start)
        #expect(magnet.level(at: start).intensity == 0)
        _ = magnet.update(translation: 40, at: start + .milliseconds(20))
        let moving = magnet.level(at: start + .milliseconds(20))
        #expect(moving.intensity > 0)
        #expect(moving.sharpness == Float(40 / (width * Theme.Gesture.edgeArchiveUnstickFraction)))
        #expect(magnet.level(at: start + .milliseconds(40)).intensity == 0)
        _ = magnet.update(translation: width * 0.5, at: start + .milliseconds(60))
        #expect(magnet.level(at: start + .milliseconds(80)).intensity == 0)
    }

    @Test func theReleaseCarriesTheFingerTowardItsTargetOnly() {
        // 300 pt/s with 300 pt left to go off the screen is one distance per second.
        #expect(EdgeArchive.releaseVelocity(offset: 100, velocity: 300, completes: true, width: width) == 1)
        // A cancel toward rest carries a leftward finger, and never a rightward one.
        #expect(EdgeArchive.releaseVelocity(offset: 100, velocity: -200, completes: false, width: width) == 2)
        #expect(EdgeArchive.releaseVelocity(offset: 100, velocity: 200, completes: false, width: width) == 0)
        #expect(EdgeArchive.releaseVelocity(offset: width, velocity: 300, completes: true, width: width) == 0)
    }

    @Test func theTabUnderneathSlidesInAndBrightensWithThePage() {
        #expect(EdgeArchive.underlayOffset(progress: 0, width: width) == -width * Theme.Gesture.edgeArchiveParallax)
        #expect(EdgeArchive.underlayOffset(progress: 1, width: width) == 0)
        #expect(EdgeArchive.underlayDim(progress: 0) == Theme.Opacity.edgeArchiveDim)
        #expect(EdgeArchive.underlayDim(progress: 1) == 0)
    }

    @Test func theForwardSwipeIsTheBackSwipeMirrored() {
        let zone = width * (1 - Theme.Gesture.edgeArchiveZoneFraction)
        #expect(EdgeArchive.startsInForwardZone(x: width, width: width))
        #expect(EdgeArchive.startsInForwardZone(x: zone, width: width))
        #expect(!EdgeArchive.startsInForwardZone(x: zone - 1, width: width))
        #expect(EdgeArchive.beginsForward(translation: CGSize(width: -12, height: 6)))
        #expect(!EdgeArchive.beginsForward(translation: CGSize(width: 12, height: 0)))
        #expect(!EdgeArchive.beginsForward(translation: CGSize(width: -4, height: 12)))
        #expect(EdgeArchive.pageAtRightEdge(offsetX: 0, contentWidth: width, width: width, rightInset: 0))
        #expect(EdgeArchive.pageAtRightEdge(offsetX: 200, contentWidth: 600, width: width, rightInset: 0))
        #expect(!EdgeArchive.pageAtRightEdge(offsetX: 100, contentWidth: 600, width: width, rightInset: 0))
    }

    // Forward brings back the last tab archived from the tab shown, newest first, and only while that tab is shown.
    @Test func forwardOffersTheLastTabArchivedFromTheShownTab() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var history = EdgeForwardHistory()
        history.archived(a, landing: b)
        history.archived(b, landing: c)
        let inArchive: (Tab.ID) -> Bool = { _ in true }
        #expect(history.next(shown: c, inArchive: inArchive) == .init(archived: b, landing: c))

        // b comes back as a new tab; the entry that landed on b now lands on it.
        let b2 = UUID()
        history.restored(.init(archived: b, landing: c), as: b2)
        #expect(history.next(shown: b2, inArchive: inArchive) == .init(archived: a, landing: b2))
    }

    @Test func showingAnotherTabDropsTheForwardHistory() {
        let (a, b, other) = (UUID(), UUID(), UUID())
        var history = EdgeForwardHistory()
        history.archived(a, landing: b)
        #expect(history.next(shown: other, inArchive: { _ in true }) == nil)
        #expect(history.entries.isEmpty)
        #expect(history.next(shown: b, inArchive: { _ in true }) == nil)
    }

    @Test func aTabGoneFromTheArchiveIsSkipped() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var history = EdgeForwardHistory()
        history.archived(a, landing: c)
        history.archived(b, landing: c)
        // b was restored or deleted from the Archive: a, archived from the same tab, is offered.
        #expect(history.next(shown: c, inArchive: { $0 != b }) == .init(archived: a, landing: c))
    }
}
