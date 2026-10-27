import CoreGraphics

// A horizontal swipe on the browsing bar pages through the tabs in deck order: a drag to the left toward the next tab,
// to the right toward the previous one. Positions are in tab indices; a stride is one page plus the gap between pages.
nonisolated enum BarSwipe {
    enum Axis: Sendable { case horizontal, vertical }

    // The touch locks after axisLockDistance of radial travel: to the swipe when its path is within axisLockAngle
    // (degrees) of horizontal, else vertical, which leaves the touch to the bar's controls and the tab stack's flick.
    static func lock(_ translation: CGSize) -> Axis? {
        let (dx, dy) = (abs(translation.width), abs(translation.height))
        guard hypot(dx, dy) >= Theme.Gesture.axisLockDistance else { return nil }
        return dy <= dx * tan(Theme.Gesture.axisLockAngle * .pi / 180) ? .horizontal : .vertical
    }

    // The finger's travel added to the travel that draws the start, so a catch inside the band continues from where
    // the cards are drawn. Past either end the sum is banded.
    static func position(start: CGFloat, translation: CGFloat, stride: CGFloat, count: Int) -> CGFloat {
        let last = CGFloat(count - 1)
        let stretch = Theme.Gesture.barSwipeStretch
        let base =
            start < 0
            ? Magnet.rubberBandInverse(start, stretch: stretch)
            : start > last ? last + Magnet.rubberBandInverse(start - last, stretch: stretch) : start
        let travel = base - translation / stride
        if travel < 0 {
            return Magnet.rubberBand(travel, stretch: stretch)
        }
        if travel > last {
            return last + Magnet.rubberBand(travel - last, stretch: stretch)
        }
        return travel
    }

    // The tab a release lands on, and the finger's velocity relative to the distance left, or 0 when it points away.
    // A slow release lands past the commit fraction; a fast one commits in its direction even short of it. Either lands
    // at most barSwipeMaxTabs from the start.
    static func release(position: CGFloat, start: Int, velocity: CGFloat, stride: CGFloat, count: Int) -> (
        index: Int, velocity: Double
    ) {
        let target: Int
        if abs(velocity) >= Theme.Gesture.barSwipeFlickVelocity {
            let aim = Int((position - Magnet.project(velocity: velocity, rate: Theme.Gesture.decelerationNormal) / stride)
                .rounded())
            target =
                velocity < 0
                ? max(Int(position.rounded(.down)) + 1, aim) : min(Int(position.rounded(.up)) - 1, aim)
        } else {
            let offset = position - CGFloat(start)
            let whole = abs(offset).rounded(.down)
            let pages = Int(whole) + (abs(offset) - whole >= Theme.Gesture.barSwipeCommitFraction ? 1 : 0)
            target = start + (offset < 0 ? -pages : pages)
        }
        let reach = Theme.Gesture.barSwipeMaxTabs
        let index = min(max(target, start - reach, 0), start + reach, count - 1)
        let remaining = CGFloat(index) - position
        let relative = Double(SheetDrag.releaseVelocity(-velocity / stride, toward: remaining))
        return (index, relative < 0 ? 0 : relative)
    }
}

// The tab leading under the finger: it changes as the pages pass each midpoint, with a band of the platform's detent
// hysteresis around it so a finger resting on the line cannot chatter. Past either end nothing changes.
nonisolated struct PageDetent: Equatable, Sendable {
    private(set) var leading: Int
    private let last: Int
    private let band: CGFloat

    init(leading: Int, count: Int, stride: CGFloat) {
        self.leading = leading
        last = count - 1
        band = Theme.Gesture.detentHysteresis / 2 / stride
    }

    // How many midpoints the move crossed, one tick each.
    mutating func update(_ position: CGFloat) -> Int {
        let clamped = min(max(position, 0), CGFloat(last))
        let was = leading
        while clamped >= CGFloat(leading) + 0.5 + band {
            leading += 1
        }
        while clamped <= CGFloat(leading) - 0.5 - band {
            leading -= 1
        }
        return abs(leading - was)
    }
}
