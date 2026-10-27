import CoreGraphics
import Testing
@testable import SailBrowser

struct RowSwipeTests {
    private let lead = Theme.Gesture.deckAxisLock

    // A swipe to the left removes a recent; a swipe right refuses, leaving the touch alone.
    @Test func aSwipeStartsOnlyOnceTheLeftwardTravelLeadsTheVerticalByTheSlop() {
        #expect(RowSwipe.starts(CGSize(width: -lead - 2, height: 2)) == true)
        #expect(RowSwipe.starts(CGSize(width: -lead, height: lead / 2)) == nil)
        #expect(RowSwipe.starts(CGSize(width: -4, height: 4 + lead)) == false)
        #expect(RowSwipe.starts(CGSize(width: -2, height: -lead - 4)) == false)
        #expect(RowSwipe.starts(CGSize(width: lead, height: 0)) == false)
    }

    // The pull is leftward travel; the row rides it 1:1, never past rest to the right, and arms once at
    // the fraction of its width.
    @Test func theRowFollowsLeftAndArmsOnceAtItsFraction() {
        var swipe = RowSwipe(width: 400, from: 0)
        let line = Theme.Gesture.recentRemoveFraction * 400
        #expect(swipe.follow(-30) == nil)
        #expect(swipe.offset == 0)
        #expect(swipe.follow(100) == nil)
        #expect(swipe.offset == 100)
        #expect(swipe.follow(line - 1) == nil)
        #expect(!swipe.removes)
        #expect(swipe.follow(line) == .armed)
        #expect(swipe.removes)
        #expect(swipe.follow(line - lead * 2) == .disarmed)
        #expect(swipe.follow(line + 20) == .rearmed)
    }

    @Test func aSwipeTakenMidReturnFollowsFromWhereTheRowWasHeld() {
        var swipe = RowSwipe(width: 400, from: 50)
        #expect(swipe.offset == 50)
        #expect(swipe.follow(20) == nil)
        #expect(swipe.offset == 70)
        #expect(swipe.follow(-80) == nil)
        #expect(swipe.offset == 0)
        #expect(swipe.follow(Theme.Gesture.recentRemoveFraction * 400 - 50) == .armed)
    }

    // The "Remove" capsule: 12 x 6, 48 x 28, then 112 x 48, its right edge 11 pt from
    // the screen's.
    @Test func theCapsuleGrowsFromADotToFullHeight() {
        let inset = Theme.Metrics.recentRemoveInset
        #expect(RemoveCapsule.size(travel: inset) == .zero)
        for (width, height) in [(12.0, 6.0), (48, 28), (112, 48)] {
            let size = RemoveCapsule.size(travel: inset + width)
            #expect(abs(size.width - width) < 1e-9)
            #expect(abs(size.height - height) <= 1.5, "\(width)")
        }
        #expect(RemoveCapsule.size(travel: inset + 300).height == Theme.Metrics.recentRemoveHeight)
    }

    // The release carries the finger's speed from its last two moves, and none if it rested before lifting.
    @Test func aFlickReleasesAtItsLastSpeedAndARestedFingerAtNone() {
        var flick = FlickVelocity()
        flick.add(0, at: 1)
        flick.add(10, at: 1.01)
        flick.add(16, at: 1.02)
        #expect(abs(flick.release(at: 1.021) - 600) < 1e-6)
        #expect(flick.release(at: 1.02 + Theme.Gesture.flickStill) == 0)
    }
}
