import CoreGraphics

// A swipe right from the left half of a page with nothing to go back to archives its tab and shows the tab shown
// before it, as Arc Search does; this is the pure half: which tabs take it, the touch's start and lock, the magnet that
// holds the page (EdgeMagnet) and the release rule.
nonisolated enum EdgeArchive {
    enum Outcome: Equatable, Sendable {
        // The tab goes to the Archive, where it can be restored.
        case archive
        // A private tab is never archived: it closes.
        case close
    }

    // What the swipe does to a tab on its first page. Nil archives nothing: a page with back history goes back through
    // it instead (backMove), and a pinned tab is never archived by a gesture, as the timed sweep never archives it.
    static func outcome(isPinned: Bool, isPrivate: Bool, canGoBack: Bool) -> Outcome? {
        guard !canGoBack, !isPinned else { return nil }
        return isPrivate ? .close : .archive
    }

    // What a swipe does. Right from the left half: back through the page's history, or, on its first page, the tab to
    // the Archive (outcome). Left from the right half: forward through the history, or, with none, the tab the back
    // swipe archived from here comes back.
    enum Move: Equatable, Sendable {
        case historyBack, archive(Outcome), historyForward, restore
    }

    static func backMove(canGoBack: Bool, isPinned: Bool, isPrivate: Bool) -> Move? {
        if canGoBack { return .historyBack }
        return outcome(isPinned: isPinned, isPrivate: isPrivate, canGoBack: false).map(Move.archive)
    }

    static func forwardMove(canGoForward: Bool, hasArchivedTab: Bool) -> Move? {
        if canGoForward { return .historyForward }
        return hasArchivedTab ? .restore : nil
    }

    // A touch starting anywhere in the left part of the page is watched, so the swipe needs no aim at the edge.
    static func startsInZone(x: CGFloat, width: CGFloat) -> Bool {
        x >= 0 && x <= width * Theme.Gesture.edgeArchiveZoneFraction
    }

    // A page zoomed in and scrolled sideways scrolls back to its left edge first; only one at its left edge swipes.
    static func pageAtLeftEdge(offsetX: CGFloat, leftInset: CGFloat) -> Bool {
        offsetX <= -leftInset + 0.5
    }

    // The forward swipe's touch starts anywhere in the right part of the page, the back swipe's zone mirrored.
    static func startsInForwardZone(x: CGFloat, width: CGFloat) -> Bool {
        x <= width && x >= width * (1 - Theme.Gesture.edgeArchiveZoneFraction)
    }

    // A page scrolled sideways short of its right edge scrolls there first; only one at its right edge swipes forward.
    static func pageAtRightEdge(offsetX: CGFloat, contentWidth: CGFloat, width: CGFloat, rightInset: CGFloat) -> Bool {
        offsetX >= contentWidth - width + rightInset - 0.5
    }

    // The forward pan begins once it has moved left within the lock angle, the back swipe's begin mirrored.
    static func beginsForward(translation: CGSize) -> Bool {
        begins(translation: CGSize(width: -translation.width, height: translation.height))
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

    // Only a page pulled free of the magnet goes: one still held springs back, however it was let go, and a free one
    // flicked back cancels.
    static func completes(isFree: Bool, velocity: CGFloat) -> Bool {
        isFree && velocity > -Theme.Gesture.edgeArchiveFlickVelocity
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

// The magnet that holds a swiped page. Held, the page gives a rubber band's way under the finger; past the unstick line
// it comes free and closes on the finger on a critically damped spring, then follows it; back under the line, less the
// detent's hysteresis, it closes on the held place again. Each change of side reports an event for its haptic.
nonisolated struct EdgeMagnet: Equatable, Sendable {
    enum Event: Equatable, Sendable { case freed, stuck }

    let width: CGFloat
    private var detent: Detent
    private(set) var translation: CGFloat = 0
    // How free the page is: 0 held, 1 on the finger. It was `from` at `since` and closes on the detent's side.
    private var from: CGFloat = 0
    private var since: ContinuousClock.Instant?
    private var sample: Sample?

    private struct Sample: Equatable, Sendable {
        let translation: CGFloat
        let at: ContinuousClock.Instant
    }

    init(width: CGFloat) {
        self.width = width
        detent = Detent(line: width * Theme.Gesture.edgeArchiveUnstickFraction)
    }

    var isFree: Bool {
        detent.isArmed
    }

    // The pull toward the line, 0 to 1, for the texture's sharpness.
    var tension: CGFloat {
        min(1, max(0, translation / detent.line))
    }

    mutating func update(translation: CGFloat, at now: ContinuousClock.Instant) -> Event? {
        let freedom = freedom(at: now)
        self.translation = translation
        guard let change = detent.update(translation) else { return nil }
        from = freedom
        since = now
        return change == .disarmed ? .stuck : .freed
    }

    // Where the page is drawn: between its held place and the finger by how free it is.
    func offset(at now: ContinuousClock.Instant) -> CGFloat {
        let free = EdgeArchive.offset(translation: translation, width: width)
        let held = min(free, Magnet.rubberBand(max(0, translation), stretch: width * Theme.Gesture.edgeArchiveHoldFraction))
        return held + (free - held) * freedom(at: now)
    }

    // The texture's level for a frame while the page is held: the finger's speed since the last frame as a share of
    // Haptic.edgeTextureSpeed (nothing on the first frame, which has no speed yet, or while the finger rests), with
    // the tension as sharpness. A free page is silent.
    mutating func level(at now: ContinuousClock.Instant) -> HapticTexture.Level {
        defer { sample = Sample(translation: translation, at: now) }
        guard !isFree, let sample, now > sample.at else { return HapticTexture.Level(intensity: 0, sharpness: 0) }
        let speed = abs(translation - sample.translation) / CGFloat((now - sample.at) / .seconds(1))
        return HapticTexture.Level(
            intensity: Float(min(1, speed / Theme.Haptic.edgeTextureSpeed)), sharpness: Float(tension))
    }

    // At rest on its side of the line, so a clock driving the page can stop until the finger moves.
    func isSettled(at now: ContinuousClock.Instant) -> Bool {
        abs(freedom(at: now) - (isFree ? 1 : 0)) < 0.001
    }

    private func freedom(at now: ContinuousClock.Instant) -> CGFloat {
        let target: CGFloat = isFree ? 1 : 0
        guard let since else { return target }
        let omega = 2 * .pi / Theme.Gesture.edgeArchiveSnapResponse
        let t = max(0, (now - since) / .seconds(1))
        return target + (from - target) * CGFloat((1 + omega * t) * exp(-omega * t))
    }
}

// The tabs the back swipe archived, newest last, for the forward swipe to bring back: each with the tab the swipe
// landed on. Only the newest one is offered, and only while its landing tab is the one shown, so a tab shown any other
// way drops the lot, as a browser's forward history goes when it goes somewhere new. A tab restored or deleted from the
// Archive in the meantime is skipped.
nonisolated struct EdgeForwardHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        // The archived tab, whose Archive entry keeps its id.
        let archived: Tab.ID
        let landing: Tab.ID
    }

    private(set) var entries: [Entry] = []

    mutating func archived(_ id: Tab.ID, landing: Tab.ID) {
        entries.append(Entry(archived: id, landing: landing))
    }

    // The entry the forward swipe offers on the shown tab, dropping what no longer applies.
    mutating func next(shown: Tab.ID?, inArchive: (Tab.ID) -> Bool) -> Entry? {
        entries.removeAll { !inArchive($0.archived) }
        guard let last = entries.last, last.landing == shown else {
            entries = []
            return nil
        }
        return last
    }

    // The newest entry came back as a new tab: the entry before it, which landed on the tab that was archived, now
    // lands on the new one.
    mutating func restored(_ entry: Entry, as id: Tab.ID) {
        entries.removeAll { $0 == entry }
        for i in entries.indices where entries[i].landing == entry.archived {
            entries[i] = Entry(archived: entries[i].archived, landing: id)
        }
    }
}
