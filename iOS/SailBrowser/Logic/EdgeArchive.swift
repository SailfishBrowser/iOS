import CoreGraphics

// A swipe in from the left edge of a page with nothing to go back to archives its tab and shows the tab shown before
// it, as Arc Search does; this is the pure half: which tabs take it, the touch's start and lock, the slide under the
// finger and the release rule.
nonisolated enum EdgeArchive {
    enum Outcome: Equatable, Sendable {
        // The tab goes to the Archive, where it can be restored.
        case archive
        // A private tab is never archived: it closes.
        case close
    }

    // Nil leaves the edge alone: a page with back history keeps WebKit's own back swipe, and a pinned tab is never
    // archived by a gesture, as the timed sweep never archives it.
    static func outcome(isPinned: Bool, isPrivate: Bool, canGoBack: Bool) -> Outcome? {
        guard !canGoBack, !isPinned else { return nil }
        return isPrivate ? .close : .archive
    }

    // Only a touch that starts this close to the page's left edge is watched, so a horizontal scroll inside the page
    // keeps its touches.
    static func startsAtEdge(x: CGFloat) -> Bool {
        x >= 0 && x <= Theme.Gesture.edgeArchiveZone
    }

    // The pan begins once it has moved right within the bar swipe's lock angle of horizontal; a vertical start is
    // the page's scroll.
    static func begins(translation: CGSize) -> Bool {
        translation.width > 0
            && abs(translation.height) <= translation.width * tan(Theme.Gesture.axisLockAngle * .pi / 180)
    }

    // The page follows the finger to the right and stops at its rest on the left.
    static func offset(translation: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, translation), width)
    }

    static func progress(offset: CGFloat, width: CGFloat) -> CGFloat {
        width > 0 ? min(1, max(0, offset / width)) : 0
    }

    // A flick completes or cancels in its direction wherever the page is; a slower release completes past the commit
    // fraction of the width.
    static func completes(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        if velocity >= Theme.Gesture.edgeArchiveFlickVelocity { return true }
        if velocity <= -Theme.Gesture.edgeArchiveFlickVelocity { return false }
        return progress(offset: offset, width: width) >= Theme.Gesture.edgeArchiveCommitFraction
    }

    // The release's spring carries the finger's speed relative to the distance left, or none when it points away.
    static func releaseVelocity(offset: CGFloat, velocity: CGFloat, completes: Bool, width: CGFloat) -> CGFloat {
        let remaining = (completes ? width : 0) - offset
        let relative = SheetDrag.releaseVelocity(velocity, toward: remaining)
        return max(0, relative)
    }

    // The tab underneath starts a parallax share of the width to the left and slides in to rest with the page, as
    // UIKit's back swipe reveals the screen under it.
    static func underlayOffset(progress: CGFloat, width: CGFloat) -> CGFloat {
        -(1 - progress) * width * Theme.Gesture.edgeArchiveParallax
    }

    // The tab underneath is dimmed until the page has gone.
    static func underlayDim(progress: CGFloat) -> CGFloat {
        (1 - progress) * Theme.Opacity.edgeArchiveDim
    }
}
