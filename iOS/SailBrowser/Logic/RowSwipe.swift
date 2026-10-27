import Foundation

// A recent's swipe to the left: the pull is leftward finger travel. The row rides it 1:1, left only and from
// where it was held, and arms its removal once past a fraction of its width.
nonisolated struct RowSwipe: Equatable, Sendable {
    private let from: CGFloat
    private(set) var offset: CGFloat
    private var remove: Detent

    init(width: CGFloat, from: CGFloat) {
        self.from = from
        offset = from
        remove = Detent(line: Theme.Gesture.recentRemoveFraction * width)
    }

    // Whether a touch's travel starts the swipe: once the leftward travel leads the vertical by the axis-lock slop.
    // A rightward or mostly vertical travel refuses it, leaving the touch to the sheet; until then it is undecided.
    static func starts(_ translation: CGSize) -> Bool? {
        let lead = Theme.Gesture.deckAxisLock
        let left = -translation.width
        if left - abs(translation.height) >= lead {
            return true
        }
        if translation.width >= lead || abs(translation.height) - left >= lead {
            return false
        }
        return nil
    }

    var removes: Bool {
        remove.isArmed
    }

    mutating func follow(_ pull: CGFloat) -> Detent.Event? {
        offset = max(0, from + pull)
        return remove.update(offset)
    }
}

// The "Remove" capsule in the space the row leaves: its right edge pinned at the inset, its width what is left of
// the travel, its height growing with its width up to full.
nonisolated enum RemoveCapsule {
    static func size(travel: CGFloat) -> CGSize {
        let m = Theme.Metrics.self
        let width = max(0, travel - m.recentRemoveInset)
        return CGSize(width: width, height: min(m.recentRemoveHeight, width * m.recentRemoveAspect))
    }
}

// A drag's speed at its release, from its last two moves: none once the finger has rested before lifting.
nonisolated struct FlickVelocity: Sendable {
    private var last: (value: CGFloat, time: TimeInterval)?
    private var speed: CGFloat = 0

    mutating func add(_ value: CGFloat, at time: TimeInterval) {
        if let last, time > last.time {
            speed = (value - last.value) / (time - last.time)
        }
        last = (value, time)
    }

    func release(at time: TimeInterval) -> CGFloat {
        guard let last, time - last.time < Theme.Gesture.flickStill else { return 0 }
        return speed
    }
}
