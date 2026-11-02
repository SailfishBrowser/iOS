import CoreGraphics

nonisolated struct PullToRefresh: Equatable, Sendable {
    enum Event: Equatable, Sendable { case armed, rearmed, disarmed }

    private var detent = Detent(line: Theme.Refresh.armDistance)
    private(set) var progress: CGFloat = 0
    // True from the first frame past the top until the release: the pulse under the finger runs while it is.
    private(set) var isPulling = false

    mutating func update(overscroll: CGFloat) -> Event? {
        isPulling = isPulling || overscroll > 0
        progress = min(1, overscroll / Theme.Refresh.armDistance)
        switch detent.update(overscroll) {
        case .armed: return .armed
        case .rearmed: return .rearmed
        case .disarmed: return .disarmed
        case nil: return nil
        }
    }

    mutating func release() -> Bool {
        defer { self = PullToRefresh() }
        return detent.isArmed
    }
}
