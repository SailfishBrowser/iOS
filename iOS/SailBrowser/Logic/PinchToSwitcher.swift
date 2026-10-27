import CoreGraphics

// A two-finger pinch in on a page at its minimum zoom presses the tab stack button; this is the pure half: the gate,
// the threshold and one pinch's state.
nonisolated enum PinchToSwitcher {
    static func isAtMinimumZoom(zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        zoomScale <= minimumZoomScale + Theme.Gesture.pinchZoomSlack
    }

    static func fires(scale: CGFloat) -> Bool {
        scale <= Theme.Gesture.pinchSwitcherScale
    }

    // One pinch: armed by a begin at minimum zoom, fires once at the threshold while still at minimum zoom.
    struct Tracker: Equatable, Sendable {
        private var armed = false
        private var fired = false

        mutating func began(atMinimumZoom: Bool) {
            armed = atMinimumZoom
            fired = false
        }

        // True exactly once per pinch.
        mutating func changed(scale: CGFloat, atMinimumZoom: Bool) -> Bool {
            guard armed, !fired, atMinimumZoom, fires(scale: scale) else { return false }
            fired = true
            return true
        }

        mutating func ended() {
            armed = false
        }
    }
}
