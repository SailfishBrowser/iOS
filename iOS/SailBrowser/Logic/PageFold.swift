import QuartzCore

// A pinch in on a page folds it once about its centre line like a sheet closing, toward the fingers, over the glow its
// summary comes in on; this is the pure half: the pinch's mapping onto the fold's progress, the release rule and each
// half's place.
nonisolated enum PageFold {
    // A pinch in on the page, from scale 1 to the closed scale, folds it from 0 to 1.
    static func progress(closingScale scale: CGFloat) -> CGFloat {
        clamped((1 - scale) / (1 - Theme.Fold.closedScale))
    }

    // A pinch out on the card, from scale 1 to the open scale, unfolds it from 1 to 0.
    static func progress(openingScale scale: CGFloat) -> CGFloat {
        clamped(1 - (scale - 1) / (Theme.Fold.openScale - 1))
    }

    // The recognizer's velocity is scale per second; the release rule and the spring take progress per second.
    static func progressVelocity(scaleVelocity: CGFloat, closing: Bool) -> CGFloat {
        scaleVelocity / (closing ? Theme.Fold.closedScale - 1 : -(Theme.Fold.openScale - 1))
    }

    // One rule both ways: the fold ends closed when its progress, projected at its speed, is past half.
    static func completes(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress + velocity * Theme.Fold.projection > 0.5
    }

    // Each half turns about its own centre line by progress × 90°, the top half's lower edge and the bottom half's upper
    // edge away from the eye, and sinks as it turns so its outer edge stays in the screen's plane: the crease recedes
    // and the outer edges swing toward each other. Each half's centre moves toward the anchor as the halves shorten,
    // so the inner edges meet at the crease whatever the anchor.
    static func halves(progress: CGFloat, height: CGFloat, anchor: CGFloat) -> (top: CATransform3D, bottom: CATransform3D) {
        let angle = progress * .pi / 2
        let half = height / 2
        let sink = -sin(angle) * half / 2
        func place(center: CGFloat, turn: CGFloat) -> CATransform3D {
            let shift = (1 - cos(angle)) * (anchor - center)
            return CATransform3DRotate(CATransform3DMakeTranslation(0, shift, sink), turn, 1, 0, 0)
        }
        return (place(center: half / 2, turn: -angle), place(center: half * 1.5, turn: angle))
    }

    // The folded halves fade out over the last tenth.
    static func opacity(progress: CGFloat) -> CGFloat {
        min(1, (1 - progress) / (1 - Theme.Fold.fadeStart))
    }

    // The crease darkens as the halves turn from flat.
    static func shade(progress: CGFloat) -> CGFloat {
        1 - cos(progress * .pi / 2)
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
