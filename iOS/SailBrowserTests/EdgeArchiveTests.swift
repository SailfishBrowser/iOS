import CoreGraphics
import Foundation
import Testing
@testable import SailBrowser

// The edge swipe's pure half: which tabs take it, where a touch may start and lock, and the release rule. The slide
// itself and its haptic are checked in the running app.
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

    @Test func onlyATouchAtTheLeftEdgeIsWatched() {
        #expect(EdgeArchive.startsAtEdge(x: 0))
        #expect(EdgeArchive.startsAtEdge(x: Theme.Gesture.edgeArchiveZone))
        #expect(!EdgeArchive.startsAtEdge(x: Theme.Gesture.edgeArchiveZone + 1))
        #expect(!EdgeArchive.startsAtEdge(x: -1))
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

    @Test func aSlowReleaseCompletesPastHalfTheWidth() {
        let line = width * Theme.Gesture.edgeArchiveCommitFraction
        #expect(EdgeArchive.completes(offset: line, velocity: 0, width: width))
        #expect(!EdgeArchive.completes(offset: line - 1, velocity: 0, width: width))
        let slow = Theme.Gesture.edgeArchiveFlickVelocity - 1
        #expect(!EdgeArchive.completes(offset: line - 1, velocity: slow, width: width))
    }

    @Test func aFlickCompletesOrCancelsInItsDirectionWhereverThePageIs() {
        let flick = Theme.Gesture.edgeArchiveFlickVelocity
        #expect(EdgeArchive.completes(offset: 20, velocity: flick, width: width))
        #expect(!EdgeArchive.completes(offset: width * 0.9, velocity: -flick, width: width))
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
}
