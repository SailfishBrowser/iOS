import CoreGraphics
import Foundation
import SwiftUI

nonisolated struct CardTransform: Equatable, Sendable {
    var offset: CGSize
    var scale: CGFloat
    var clipHeight: CGFloat
    var rotation: Angle
    var corner: CGFloat
    var opacity: CGFloat
    var headerOpacity: CGFloat
    var titleOpacity: CGFloat
    var dim: CGFloat
    var zIndex: Double
    // Cut from the card's top, as clipHeight cuts from its bottom; both in drawn points from the card's top.
    var clipTop: CGFloat = 0
}

nonisolated struct CardLayout: Sendable {
    private static let zoomingZIndex = Double(Int32.max)

    let screen: CGSize
    let cardSize: CGSize
    let stride: CGFloat
    // One armed card and the gap after it, for a swipe on the bar; the finger moves the pair one to one.
    let pageStride: CGFloat
    let slotCenter: CGPoint
    let tabStackButtonFrame: CGRect
    let barTop: CGFloat
    private let focusedLeft: CGFloat
    private let leftFirstStep: CGFloat
    private let leftStep: CGFloat
    private let depthScales: [CGFloat]
    private let displayCorner: CGFloat
    private let cardCorner: CGFloat
    private let buttonCorner: CGFloat
    private let thumbnailWidth: CGFloat
    private let thumbnailHeight: CGFloat
    private let buttonTilt: Double
    // The tab stack's front card, which leaves the stack as a card and which a card dropped into the stack becomes.
    let frontSlot: CGPoint
    private let pairScale: CGFloat
    private let pairTopInset: CGFloat
    private let pairCorner: CGFloat
    private let flickArmScale: CGFloat
    private let flickPeekScale: CGFloat
    private let flickInset: CGFloat
    private let flickBottomInset: CGFloat
    private let flickUprightScale: CGFloat
    private let flickShapeFast: CGFloat
    private let flickShapeSlow: CGFloat
    private let flickShapeFastShare: CGFloat

    @MainActor init(screen: CGSize, barHeight: CGFloat = Theme.Metrics.barTotalHeight) {
        self.screen = screen
        barTop = screen.height - barHeight
        let width = Theme.Metrics.cardWidthFraction * screen.width
        cardSize = CGSize(width: width, height: Theme.Metrics.cardHeightFraction * screen.height)
        stride = Theme.Metrics.rightStepFraction * width
        pageStride = Theme.Metrics.barSwipeCardScale * screen.width + Theme.Metrics.barSwipeGap
        focusedLeft = Theme.Metrics.focusedLeftFraction * screen.width
        leftFirstStep = Theme.Metrics.leftFirstStepFraction * width
        leftStep = Theme.Metrics.leftStepFraction * width
        depthScales = Theme.Metrics.olderDepthScales
        slotCenter = CGPoint(
            x: focusedLeft + width / 2, y: Theme.Metrics.cardTopFraction * screen.height + cardSize.height / 2)
        let button = Theme.Metrics.tabStackButtonSize
        tabStackButtonFrame = CGRect(
            x: Theme.Metrics.tabStackButtonCenterX - button.width / 2,
            y: screen.height - Theme.Metrics.barControlCenterFromBottom - button.height / 2,
            width: button.width, height: button.height)
        displayCorner = Theme.Metrics.displayCorner
        cardCorner = Theme.Metrics.cardCorner
        buttonCorner = Theme.Metrics.tabStackThumbnailCorner
        thumbnailWidth = Theme.Metrics.tabStackThumbnailSize.width
        thumbnailHeight = Theme.Metrics.tabStackThumbnailSize.height
        buttonTilt = Theme.Metrics.tabStackTilt
        let front = Theme.Metrics.tabStackThumbnailOffsets[0]
        frontSlot = CGPoint(x: tabStackButtonFrame.midX + front.width, y: tabStackButtonFrame.midY + front.height)
        pairScale = Theme.Metrics.barSwipeCardScale
        pairTopInset = Theme.Metrics.barSwipeCardTopInset
        pairCorner = Theme.Metrics.barSwipeCardCorner
        flickArmScale = Theme.Metrics.tabStackFlickArmScale
        flickPeekScale = Theme.Metrics.tabStackFlickPeekScale
        flickInset = Theme.Metrics.tabStackFlickInset
        flickBottomInset = Theme.Metrics.tabStackFlickBottomInset
        flickUprightScale = Theme.Metrics.tabStackFlickUprightScale
        flickShapeFast = Theme.Metrics.tabStackFlickShapeFast
        flickShapeSlow = Theme.Metrics.tabStackFlickShapeSlow
        flickShapeFastShare = Theme.Metrics.tabStackFlickShapeFastShare
    }

    var restScale: CGFloat { cardSize.width / screen.width }

    // Where a card's drawn bottom edge is on the screen.
    func bottom(of t: CardTransform) -> CGFloat {
        screen.height / 2 + t.offset.height - screen.height * t.scale / 2 + t.clipHeight
    }

    // The flick to the previous tab: the live page never lifts. As the pull
    // locks it shrinks toward the bottom-left corner, its bottom-left pinned above the bar, to the armed scale, and
    // stays that size while the card is dragged. On a landing it drops into the tab stack button.
    func flickLive(arm: CGFloat, drop: CGFloat) -> CardTransform {
        let scale = lerp(1, flickArmScale, arm)
        let left = lerp(0, flickInset, arm)
        let bottom = lerp(screen.height, screen.height - flickBottomInset, arm)
        let t = CardTransform(
            offset: CGSize(
                width: left + screen.width * scale / 2 - screen.width / 2, height: bottom - screen.height * scale / 2
                    - screen.height / 2),
            scale: scale, clipHeight: screen.height * scale, rotation: .zero,
            corner: lerp(displayCorner, cardCorner, arm), opacity: 1, headerOpacity: 0, titleOpacity: 0, dim: 0,
            zIndex: 0)
        return towardStack(t, drop)
    }

    // Where the finger took the flick's card: the point on the stack's front card nearest the touch, on the
    // screen, and its place on the card as a fraction of the card's size from its centre, in the card's own tilted
    // axes. That point of the card stays under the finger however the card grows and turns.
    struct FlickGrab: Equatable {
        let point: CGPoint
        let unit: CGPoint
    }

    func flickGrab(at finger: CGPoint) -> FlickGrab {
        let (c, s) = (cos(Angle.degrees(buttonTilt).radians), sin(Angle.degrees(buttonTilt).radians))
        let (dx, dy) = (finger.x - frontSlot.x, finger.y - frontSlot.y)
        let x = min(max(dx * c + dy * s, -thumbnailWidth / 2), thumbnailWidth / 2)
        let y = min(max(-dx * s + dy * c, -thumbnailHeight / 2), thumbnailHeight / 2)
        return FlickGrab(
            point: CGPoint(x: frontSlot.x + x * c - y * s, y: frontSlot.y + x * s + y * c),
            unit: CGPoint(x: x / thumbnailWidth, y: y / thumbnailHeight))
    }

    // How far the grabbed point rises from the front card to the peek height, where
    // the card is the peek's scale with its top at the safe-area line.
    func flickRiseHeight(grab: FlickGrab, safeTop: CGFloat) -> CGFloat {
        let height = screen.height * flickPeekScale
        return grab.point.y - (safeTop + height / 2 + grab.unit.y * height)
    }

    // How grown the flick's card is at this offset from where it left the stack, 0 the thumbnail and 1 the peek's
    // size: its rise toward the peek's height, as the card grows with its height (43 pt wide at
    // 40 pt of travel), the peek's size exactly as its top meets the safe
    // line. Grown over a fixed travel it was the peek's size in three frames of a flick, hanging below the finger off
    // the screen. The flick never lets it shrink under the
    // finger, and a sideways drag at one height keeps one size.
    func flickGrow(rise: CGFloat, grab: FlickGrab, safeTop: CGFloat) -> CGFloat {
        min(max(rise / flickRiseHeight(grab: grab, safeTop: safeTop), 0), 1)
    }

    // How much of the thumbnail's shape the rising card has left at this grow, 1 at 0 and 0 at 1: a two time
    // constant decay in units of the width growth, pinned so both ends are
    // exact.
    private func flickShapeLeft(_ grow: CGFloat) -> CGFloat {
        func decay(_ p: CGFloat) -> CGFloat {
            flickShapeFastShare * exp(-p / flickShapeFast) + (1 - flickShapeFastShare) * exp(-p / flickShapeSlow)
        }
        return (decay(grow) - decay(1)) / (1 - decay(1))
    }

    // The previous tab's card rises out of the tab stack button over the live page, under the finger exactly:
    // the point the finger took stays at the grabbed point plus the finger's offset. Its width follows its grow,
    // from the front card's to the peek's, one size wherever it is dragged after that; its shape runs ahead
    // of its width, from the thumbnail's to the page's: the page at one uniform
    // scale, clipped from its top, the corner easing with the shape. It is upright by the upright scale. A landing
    // zooms it to the screen from where it is drawn.
    func flickIncoming(offset: CGSize, grab: FlickGrab, grow: CGFloat, land: CGFloat, safeTop: CGFloat)
        -> CardTransform
    {
        let thumbnailScale = thumbnailWidth / screen.width
        let scale = thumbnailScale * (1 - grow) + flickPeekScale * grow
        let left = flickShapeLeft(grow)
        let aspect = lerp(screen.width / screen.height, thumbnailWidth / thumbnailHeight, left)
        let tilt = 1 - min(max((scale - thumbnailScale) / (flickUprightScale - thumbnailScale), 0), 1)
        var rising = CardTransform(
            offset: .zero, scale: scale, clipHeight: screen.width * scale / aspect,
            rotation: .degrees(buttonTilt * Double(tilt)), corner: lerp(buttonCorner, cardCorner, 1 - left),
            opacity: 1, headerOpacity: 0, titleOpacity: 0, dim: 0, zIndex: 1)
        // The card turns about its drawn centre, so the centre is the finger less the grabbed point turned with it.
        let (w, h) = (screen.width * scale * grab.unit.x, rising.clipHeight * grab.unit.y)
        let (c, s) = (cos(rising.rotation.radians), sin(rising.rotation.radians))
        let centre = CGPoint(
            x: grab.point.x + offset.width - (w * c - h * s), y: grab.point.y + offset.height - (w * s + h * c))
        rising.offset = self.offset(visibleCenter: centre, scale: scale, clipHeight: rising.clipHeight)
        guard land > 0 else { return rising }
        let screenCard = CardTransform(
            offset: .zero, scale: 1, clipHeight: screen.height, rotation: .zero, corner: displayCorner, opacity: 1,
            headerOpacity: 0, titleOpacity: 0, dim: 0, zIndex: 1)
        return CardTransform(
            offset: CGSize(
                width: lerp(rising.offset.width, 0, land), height: lerp(rising.offset.height, 0, land)),
            scale: lerp(rising.scale, 1, land), clipHeight: lerp(rising.clipHeight, screenCard.clipHeight, land),
            rotation: .degrees(rising.rotation.degrees * Double(1 - land)), corner: lerp(rising.corner, displayCorner, land),
            opacity: lerp(rising.opacity, 1, land), headerOpacity: 0, titleOpacity: 0, dim: 0, zIndex: 1)
    }

    // Moves a card toward the tab stack's front card: at 1 it is that
    // card exactly, the thumbnail's size, tilt, corner and top-aligned crop at the front slot. It stays opaque; where it
    // passes under the bar, the stack draws its own copy over the bar.
    private func towardStack(_ t: CardTransform, _ f: CGFloat) -> CardTransform {
        guard f > 0 else { return t }
        let top = screen.height / 2 + t.offset.height - screen.height * t.scale / 2
        let from = CGPoint(x: screen.width / 2 + t.offset.width, y: top + (t.clipTop + t.clipHeight) / 2)
        let shrink = lerp(1, thumbnailWidth / (screen.width * t.scale), f)
        let centre = CGPoint(x: lerp(from.x, frontSlot.x, f), y: lerp(from.y, frontSlot.y, f))
        var r = t
        r.scale = t.scale * shrink
        r.clipTop = lerp(t.clipTop * shrink, 0, f)
        r.clipHeight = lerp(t.clipHeight * shrink, thumbnailHeight, f)
        r.offset = CGSize(
            width: centre.x - screen.width / 2,
            height: centre.y - (r.clipTop + r.clipHeight) / 2 - screen.height / 2 + screen.height * r.scale / 2)
        r.rotation = .degrees(buttonTilt * Double(f))
        r.corner = lerp(t.corner, buttonCorner, f)
        return r
    }

    func openPosition(activeIndex: Int) -> CGFloat {
        CGFloat(max(activeIndex - 1, 0))
    }

    func transform(slot: CGFloat, isActive: Bool, activeIndex: Int, position: CGFloat, progress: CGFloat)
        -> CardTransform
    {
        transform(
            slot: slot, isActive: isActive, activeIndex: activeIndex, position: position, progress: progress,
            olderProgress: progress)
    }

    func transform(
        slot: CGFloat, isActive: Bool, activeIndex: Int, position: CGFloat, progress: CGFloat, olderProgress: CGFloat
    ) -> CardTransform {
        let t = !isActive && slot < CGFloat(activeIndex) ? olderProgress : progress
        let p = slot - position
        let rest = rest(p)
        var transform = CardTransform(
            offset: rest.offset, scale: rest.scale, clipHeight: rest.clipHeight, rotation: .zero,
            corner: t == 0 ? 0 : lerp(displayCorner, cardCorner, t), opacity: 1, headerOpacity: t,
            titleOpacity: max(0, 1 - abs(p)), dim: rest.dim * t,
            zIndex: isActive && t < 1 ? Self.zoomingZIndex : Double(slot))
        if isActive {
            transform.scale = lerp(1, rest.scale, t)
            transform.clipHeight = lerp(screen.height, rest.clipHeight, t)
            transform.offset = CGSize(width: rest.offset.width * t, height: rest.offset.height * t)
        } else if slot < CGFloat(activeIndex) {
            let button = tabStackButtonFrame
            let widthScale = lerp(thumbnailWidth / cardSize.width, rest.depth, t)
            let center = CGPoint(x: lerp(button.midX, rest.center.x, t), y: lerp(button.midY, rest.center.y, t))
            let tilt = Int(slot.rounded()) == activeIndex - 1 ? -buttonTilt : buttonTilt
            transform.scale = restScale * widthScale
            transform.clipHeight = cardSize.height * widthScale
            transform.offset = offset(visibleCenter: center, scale: transform.scale, clipHeight: transform.clipHeight)
            transform.rotation = .degrees(tilt * Double(1 - t))
            transform.corner = lerp(buttonCorner, cardCorner, t)
            transform.opacity = min(1, t / Theme.Metrics.deckOlderFadeIn)
        } else {
            let active = self.rest(CGFloat(activeIndex) - position)
            let zoom = lerp(1 / active.scale, 1, t)
            transform.offset = CGSize(
                width: active.offset.width * t + zoom * (rest.offset.width - active.offset.width),
                height: active.offset.height * t + zoom * (rest.offset.height - active.offset.height))
            transform.scale = zoom * rest.scale
            transform.clipHeight = zoom * rest.clipHeight
            transform.opacity = t == 0 ? 0 : 1
        }
        return transform
    }

    // The bar swipe: the page slides at full size until the drag arms; armed, the pages are
    // equal cards at the card scale between the status bar and the bar, their status band cut, side by side a gap
    // apart, with no dim or shadow. `offset` is the card's place in strides from the position; the card nearest the
    // position draws on top, as the cards overlap until the pair arms. A card on its way to or from the tab stack
    // button (`fromStack` 1 at the button) takes the deck zoom's older-card path there: the thumbnail's width and
    // tilt, fading out as it arrives.
    func pairTransform(offset p: CGFloat, fromStack f: CGFloat, arm: CGFloat, safeTop: CGFloat) -> CardTransform {
        let scale = lerp(1, pairScale, arm)
        let clipTop = safeTop * arm * scale
        let top = arm * (safeTop - pairTopInset - safeTop * pairScale)
        let t = CardTransform(
            offset: CGSize(width: p * pageStride, height: top - screen.height / 2 + screen.height * scale / 2),
            scale: scale, clipHeight: screen.height * scale, rotation: .zero, corner: lerp(displayCorner, pairCorner, arm),
            opacity: 1, headerOpacity: 0, titleOpacity: 0, dim: 0, zIndex: -abs(p), clipTop: clipTop)
        guard f > 0 else { return t }
        var r = towardStack(t, f)
        r.zIndex = 1
        return r
    }

    static func span(from start: CGFloat, to end: CGFloat) -> ClosedRange<Int> {
        let lower = Int((min(start, end) - Theme.Gesture.deckBuiltBehind).rounded(.down)) + 1
        let upper = Int((max(start, end) + Theme.Gesture.deckBuiltAhead).rounded(.up)) - 1
        return lower...upper
    }

    func visibleRange(from start: CGFloat, to end: CGFloat, count: Int) -> ClosedRange<Int> {
        let span = Self.span(from: start, to: end)
        return max(0, span.lowerBound)...min(count - 1, span.upperBound)
    }

    func stretched(_ position: CGFloat, count: Int) -> CGFloat {
        let last = CGFloat(count - 1)
        if position < 0 {
            return Magnet.rubberBand(position, stretch: Theme.Gesture.deckStretch)
        }
        if position > last {
            return last + Magnet.rubberBand(position - last, stretch: Theme.Gesture.deckStretch)
        }
        return position
    }

    // The topmost card drawn under the point at this zoom, so a tap mid-zoom takes the card the finger is on.
    func card(
        at point: CGPoint, activeIndex: Int, position: CGFloat, progress: CGFloat, olderProgress: CGFloat,
        in range: ClosedRange<Int>, slot: (Int) -> CGFloat
    ) -> Int? {
        let hits = range.compactMap { index -> (index: Int, zIndex: Double)? in
            let transform = transform(
                slot: slot(index), isActive: index == activeIndex, activeIndex: activeIndex, position: position,
                progress: progress, olderProgress: olderProgress)
            let top = screen.height / 2 + transform.offset.height - screen.height * transform.scale / 2
            let inside = abs(point.x - screen.width / 2 - transform.offset.width) <= screen.width * transform.scale / 2
                && point.y >= top && point.y <= top + transform.clipHeight
            return inside ? (index, transform.zIndex) : nil
        }
        return hits.max { $0.zIndex < $1.zIndex }?.index
    }

    // The slot nearest the projected aim, at most deckMaxFlickCards from the start, and the finger's velocity
    // relative to the distance left, or 0 when it points away or almost nothing is left.
    func snapTarget(start: CGFloat, translation: CGFloat, velocity: CGFloat, slots: [CGFloat]) -> (
        index: Int, velocity: Double
    ) {
        let reach = CGFloat(Theme.Gesture.deckMaxFlickCards)
        let projected = translation + Magnet.project(velocity: velocity, rate: Theme.Gesture.decelerationNormal)
        let aim = min(max(start - projected / stride, start - reach), start + reach)
        var index = 0
        for (candidate, slot) in slots.enumerated() where abs(slot - aim) <= abs(slots[index] - aim) {
            index = candidate
        }
        let remaining = CGFloat(index) - stretched(start - translation / stride, count: slots.count)
        let relative = Double(SheetDrag.releaseVelocity(-velocity / stride, toward: remaining))
        return (index, abs(remaining) < Theme.Gesture.deckSettledDistance || relative < 0 ? 0 : relative)
    }

    // The finger's travel added to the lift the card showed at the lock, so a re-grab of a springing card picks it
    // up where it is. The downward band applies to the sum.
    func lift(for dy: CGFloat, from base: CGFloat = 0) -> CGFloat {
        let travel = (base < 0 ? base : Magnet.rubberBandInverse(base, stretch: Theme.Gesture.liftStretch)) + dy
        return travel < 0 ? travel : Magnet.rubberBand(travel, stretch: Theme.Gesture.liftStretch)
    }

    func commitsArchive(armed: Bool, lift: CGFloat, velocity: CGFloat) -> Bool {
        armed
            || (velocity <= -Theme.Gesture.archiveFlickVelocity
                && lift + Magnet.project(velocity: velocity, rate: Theme.Gesture.decelerationNormal)
                    < -Theme.Gesture.archivePredictedCommitFraction * cardSize.height)
    }

    func liftReturn(from lift: CGFloat, velocity: CGFloat, start: ContinuousClock.Instant) -> DeckSnap {
        let relative = Double(SheetDrag.releaseVelocity(velocity, toward: -lift))
        return DeckSnap(from: lift, to: 0, velocity: relative, start: start, spring: DeckSnap.release(relative))
    }

    // Straight off the top from the release, at the finger's upward speed or the slowest that coasts
    // archiveFlyOffMinimumCoast times the trip, whichever is faster.
    func flyOff(from lift: CGFloat, velocity: CGFloat, start: ContinuousClock.Instant) -> DeckCoast {
        let floor = -Theme.Motion.archiveFlyOffMinimumCoast * DeckCoast.rate * (lift + screen.height)
        return DeckCoast(from: lift, to: -screen.height, velocity: min(velocity, floor), start: start)
    }

    func archivePlan(
        removing index: Int, ids: [UUID], shift: [UUID: CGFloat], position: CGFloat, start: ContinuousClock.Instant
    ) -> DeckArchivePlan {
        var closing: [UUID: CGFloat] = [:]
        var remaining: [CGFloat] = []
        var excess: [UUID: CGFloat] = [:]
        for (oldIndex, id) in ids.enumerated() where oldIndex != index {
            let amount = shift[id, default: 0] + (oldIndex > index ? 1 : 0)
            if oldIndex > index {
                closing[id] = -1
            }
            if amount != 0 {
                excess[id] = amount
            }
            remaining.append(CGFloat(remaining.count) + amount)
        }
        let target = remaining.isEmpty
            ? 0 : CGFloat(snapTarget(start: position, translation: 0, velocity: 0, slots: remaining).index)
        return DeckArchivePlan(
            shift: closing,
            motion: DeckMotion(
                from: position, to: target, shift: excess, velocity: 0, start: start, spring: DeckSnap.gapClose))
    }

    static func frozenOrder(_ frozen: [UUID], current: [UUID]) -> [UUID] {
        let present = Set(current)
        let kept = frozen.filter(present.contains)
        let known = Set(kept)
        return kept + current.filter { !known.contains($0) }
    }

    private func rest(_ p: CGFloat) -> (
        center: CGPoint, depth: CGFloat, offset: CGSize, scale: CGFloat, clipHeight: CGFloat, dim: CGFloat
    ) {
        let left =
            p >= 0
            ? focusedLeft + p * stride
            : focusedLeft + max(p, -1) * leftFirstStep + min(p + 1, 0) * leftStep
        let depth =
            p >= 0
            ? 1
            : p >= -1
                ? 1 + (1 - depthScales[0]) * p
                : max(depthScales[1], depthScales[0] + (depthScales[0] - depthScales[1]) * (p + 1))
        let center = CGPoint(x: left + cardSize.width / 2, y: slotCenter.y)
        let scale = restScale * depth
        let clipHeight = cardSize.height * depth
        return (
            center, depth, offset(visibleCenter: center, scale: scale, clipHeight: clipHeight), scale, clipHeight,
            min(Theme.Metrics.deckLeftMaxDim, max(0, -Theme.Metrics.deckLeftDimStep * p))
        )
    }

    private func offset(visibleCenter center: CGPoint, scale: CGFloat, clipHeight: CGFloat) -> CGSize {
        CGSize(
            width: center.x - screen.width / 2,
            height: center.y - clipHeight / 2 + screen.height * scale / 2 - screen.height / 2)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    // The most one unit of each channel moves a drawn point, for the rest rule (landedPoints): the pair's arm and the
    // flick's arm, grow and land are the screen's height times their scale change (height, the larger drawn axis),
    // a card between the stack and the screen the whole height, a flick's offset a point per point.
    var pairArmPoints: CGFloat { screen.height * (1 - pairScale) }
    var screenPoints: CGFloat { screen.height }
    // The flick's clip is steepest at grow 0, 739 pt per unit of grow on 402 x 874 and 771 on 440 x 956 against the
    // 551 and 602 here, so the return's last rest step moves the clip at most 0.67 pt, under the point's feel
    // tolerance.
    var flickGrowPoints: CGFloat { screen.height * flickPeekScale }
    var flickArmPoints: CGFloat { screen.height * (1 - flickArmScale) }
    var flickLandPoints: CGFloat { screen.height * (1 - flickPeekScale) }

    // The active card's largest corner displacement between the screen and its deck slot: the zoom's progress moves
    // its corners linearly, so one unit of progress moves a point this far at most.
    var zoomPoints: CGFloat {
        let slot = rest(0)
        let width = screen.width * slot.scale
        let left = screen.width / 2 + slot.offset.width - width / 2
        let top = screen.height / 2 + slot.offset.height - screen.height * slot.scale / 2
        let corners = [
            (left, top), (left + width, top), (left, top + slot.clipHeight), (left + width, top + slot.clipHeight),
        ]
        let full = [(0, 0), (screen.width, 0), (0, screen.height), (screen.width, screen.height)]
        return zip(corners, full).map { hypot($0.0 - $1.0, $0.1 - $1.1) }.max()!
    }
}

nonisolated struct DeckSnap: Equatable, Sendable {
    static let snap = Theme.Motion.deckSnap.spring
    static let gapClose = Theme.Motion.archiveGapClose.spring
    static let zoom = Theme.Motion.deckZoom.spring
    static let olderZoom = Theme.Motion.deckOlderZoom.spring
    static let barSwipe = Theme.Motion.barSwipeSettle.spring
    static let barFade = Theme.Motion.zoom.spring
    static let flick = Theme.Motion.tabStackFlickSettle.spring
    static let flickDrop = Theme.Motion.tabStackFlickDrop.spring
    static let arm = Theme.Motion.barSwipeArm.spring
    static let drop = Theme.Motion.barSwipeDrop.spring

    // The snap spring for a release at this velocity relative to the distance left. Past the snap's natural
    // frequency it stiffens at the same damping ratio, so the card keeps the finger's speed and the overshoot stays
    // within the bound the old cap at that frequency set: a small fixed fraction of the distance, however hard the
    // release.
    static func release(_ velocity: Double) -> Spring {
        stiffened(snap, for: velocity)
    }

    // The bar swipe's release, stiffened the same way so a hard flick never shows a strip past the last page.
    static func barSwipeRelease(_ velocity: Double) -> Spring {
        stiffened(barSwipe, for: velocity)
    }

    static func stiffened(_ spring: Spring, for velocity: Double) -> Spring {
        let scale = max(abs(velocity) / (spring.stiffness / spring.mass).squareRoot(), 1)
        return Spring(mass: spring.mass, stiffness: spring.stiffness * scale * scale, damping: spring.damping * scale)
    }

    let from: CGFloat
    let to: CGFloat
    let velocity: Double
    let start: ContinuousClock.Instant
    var spring = DeckSnap.snap
    // Drawn points per unit of the value. With it the curve is at rest once it is within landedPoints of its target
    // and under landedSpeed, so the last drawn step is at most half a point; without it, at the spring's settling time.
    var points: CGFloat? = nil

    func isSettled(at time: ContinuousClock.Instant) -> Bool {
        let elapsed = (time - start) / .seconds(1)
        guard elapsed < spring.settlingDuration else { return true }
        guard let points else { return false }
        return abs(to - raw(at: elapsed)) * points <= Theme.Gesture.landedPoints
            && abs(velocity(at: time)) * points <= Theme.Gesture.landedSpeed
    }

    func velocity(at time: ContinuousClock.Instant) -> CGFloat {
        let distance = to - from
        return spring.velocity(target: distance, initialVelocity: velocity * distance, time: (time - start) / .seconds(1))
    }

    // The spring's own value, before the rest rule snaps it to the target.
    func raw(at elapsed: TimeInterval) -> CGFloat {
        let distance = to - from
        return from + spring.value(target: distance, initialVelocity: velocity * distance, time: elapsed)
    }

    func position(at time: ContinuousClock.Instant) -> CGFloat {
        isSettled(at: time) ? to : raw(at: (time - start) / .seconds(1))
    }
}

nonisolated struct DeckMotion: Equatable, Sendable {
    let curve: DeckSnap
    let from: CGFloat
    let to: CGFloat
    let shift: [UUID: CGFloat]
    // Drawn points per unit of position; the curve runs over the whole trip, so it carries points times the distance.
    let points: CGFloat?

    init(
        from: CGFloat, to: CGFloat, shift: [UUID: CGFloat], velocity: Double, start: ContinuousClock.Instant,
        spring: Spring = DeckSnap.snap, points: CGFloat? = nil
    ) {
        curve = DeckSnap(
            from: 0, to: 1, velocity: velocity, start: start, spring: spring, points: points.map { $0 * abs(to - from) })
        self.from = from
        self.to = to
        self.shift = shift
        self.points = points
    }

    func retargeted(to target: CGFloat, at time: ContinuousClock.Instant, spring: Spring) -> DeckMotion? {
        guard !curve.isSettled(at: time) else { return nil }
        let presented = presented(at: time)
        let distance = target - presented.position
        let speed = (to - from) * curve.velocity(at: time)
        return DeckMotion(
            from: presented.position, to: target, shift: presented.shift,
            velocity: distance == 0 ? 0 : Double(speed / distance), start: time, spring: spring, points: points)
    }

    func presented(at time: ContinuousClock.Instant) -> (position: CGFloat, shift: [UUID: CGFloat]) {
        let progress = curve.position(at: time)
        return (from + (to - from) * progress, shift.mapValues { $0 * (1 - progress) }.filter { $0.value != 0 })
    }
}

nonisolated struct DeckArchivePlan: Equatable, Sendable {
    let shift: [UUID: CGFloat]
    let motion: DeckMotion
}
