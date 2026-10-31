import QuartzCore

// A pinch in on a page folds it like paper into a bundle between the fingers, over the page's summary card; this is
// the pure half: the pinch's mapping onto the fold's progress, the release rule and each strip's place.
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

    // Each strip turns about its centre line by progress × 90°, alternately like an accordion, and its top edge sits
    // at the sum of the projected heights of the strips above it, so the stack shrinks toward the anchor. Neighbouring
    // edges turn to the same depth, so the creases meet under the perspective too.
    static func transforms(progress: CGFloat, strips: Int, height: CGFloat, anchor: CGFloat) -> [CATransform3D] {
        let angle = progress * .pi / 2
        let squeeze = cos(angle)
        let strip = height / CGFloat(strips)
        return (0..<strips).map { index in
            let center = (CGFloat(index) + 0.5) * strip
            let shift = (1 - squeeze) * (anchor - center)
            return CATransform3DRotate(
                CATransform3DMakeTranslation(0, shift, 0), index.isMultiple(of: 2) ? angle : -angle, 1, 0, 0)
        }
    }

    // The bundle fades out over the last tenth.
    static func opacity(progress: CGFloat) -> CGFloat {
        min(1, (1 - progress) / (1 - Theme.Fold.fadeStart))
    }

    // The creases darken as the strips turn from flat.
    static func shade(progress: CGFloat) -> CGFloat {
        1 - cos(progress * .pi / 2)
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
