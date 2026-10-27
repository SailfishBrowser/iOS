import CoreGraphics

nonisolated enum Magnet {
    // UIScrollView's band, (1 - 1 / (x * c / d + 1)) * d: slope c at the edge, saturating at d.
    static func rubberBand(_ overshoot: CGFloat, stretch: CGFloat) -> CGFloat {
        let magnitude = (1 - 1 / (abs(overshoot) * Theme.Gesture.rubberBandCoefficient / stretch + 1)) * stretch
        return overshoot < 0 ? -magnitude : magnitude
    }

    // The overshoot that rubberBand maps to this value, which must be under the stretch.
    static func rubberBandInverse(_ value: CGFloat, stretch: CGFloat) -> CGFloat {
        let magnitude = (1 / (1 - abs(value) / stretch) - 1) * stretch / Theme.Gesture.rubberBandCoefficient
        return value < 0 ? -magnitude : magnitude
    }

    // The distance a release at this velocity (pt/s) coasts at the given deceleration rate (WWDC18).
    static func project(velocity: CGFloat, rate: CGFloat) -> CGFloat {
        velocity / 1000 * rate / (1 - rate)
    }
}

nonisolated struct Detent: Equatable, Sendable {
    // Only a drag's first arm is .armed, so a wobble round the line cannot play its haptic again.
    enum Event: Sendable { case armed, rearmed, disarmed }

    let line: CGFloat
    private(set) var isArmed = false
    private(set) var hasArmed = false

    init(line: CGFloat) {
        self.line = line
    }

    mutating func update(_ value: CGFloat) -> Event? {
        if !isArmed, value >= line {
            isArmed = true
            defer { hasArmed = true }
            return hasArmed ? .rearmed : .armed
        }
        if isArmed, value < line - Theme.Gesture.detentHysteresis {
            isArmed = false
            return .disarmed
        }
        return nil
    }
}

nonisolated enum SheetDrag {
    static func offset(translation: CGFloat) -> CGFloat {
        translation >= 0 ? translation : -Magnet.rubberBand(-translation, stretch: Theme.Gesture.sheetStretch)
    }

    static func closes(armed: Bool, translation: CGFloat, velocity: CGFloat) -> Bool {
        armed
            || translation + Magnet.project(velocity: velocity, rate: Theme.Gesture.decelerationNormal)
                > Theme.Gesture.sheetDragPredictedClose
    }

    static func releaseVelocity(_ velocity: CGFloat, toward travel: CGFloat) -> CGFloat {
        travel == 0 ? 0 : velocity / travel
    }
}
