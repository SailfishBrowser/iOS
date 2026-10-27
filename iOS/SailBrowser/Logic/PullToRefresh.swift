import CoreGraphics

nonisolated struct PullToRefresh: Equatable, Sendable {
    enum Event: Equatable, Sendable { case ticked(Int), armed, rearmed, disarmed }

    private struct Sample: Equatable, Sendable {
        let overscroll: CGFloat
        let at: ContinuousClock.Instant
    }

    private var detent = Detent(line: Theme.Refresh.armDistance)
    private var step = 0
    private var overscroll: CGFloat = 0
    private var sample: Sample?
    private(set) var progress: CGFloat = 0
    // True from the first frame past the top until the release: the texture under the finger runs while it is.
    private(set) var isPulling = false

    // One tick each time the pull crosses a multiple of Refresh.tickStep, out or back, naming the boundary just
    // crossed, until the pull's first arm. A frame that crosses several steps reports the furthest; one that crosses a
    // step and the line only arms.
    mutating func update(overscroll: CGFloat) -> Event? {
        self.overscroll = overscroll
        isPulling = isPulling || overscroll > 0
        progress = min(1, overscroll / Theme.Refresh.armDistance)
        switch detent.update(overscroll) {
        case .armed: return .armed
        case .rearmed: return .rearmed
        case .disarmed: return .disarmed
        case nil: break
        }
        let reached = Int(overscroll / Theme.Refresh.tickStep)
        guard !detent.hasArmed, reached != step else { return nil }
        defer { step = reached }
        return .ticked(reached > step ? reached - 1 : reached)
    }

    // The texture's level for a frame: the page's speed since the last frame as a share of Haptic.pullTextureSpeed,
    // nothing while it rests (and on the first frame, which has no speed yet), and the pull's progress as sharpness.
    mutating func level(at now: ContinuousClock.Instant) -> HapticTexture.Level {
        defer { sample = Sample(overscroll: overscroll, at: now) }
        let speed = sample.map { abs(overscroll - $0.overscroll) / CGFloat((now - $0.at) / .seconds(1)) } ?? 0
        return HapticTexture.Level(
            intensity: Float(min(1, speed / Theme.Haptic.pullTextureSpeed)), sharpness: Float(progress))
    }

    mutating func release() -> Bool {
        defer { self = PullToRefresh() }
        return detent.isArmed
    }
}
