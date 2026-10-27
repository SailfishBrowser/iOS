import CoreGraphics

nonisolated struct BarVisibility: Equatable, Sendable {
    private(set) var isHidden = false
    private var lastOffsetY: CGFloat?
    private var travel: CGFloat = 0

    mutating func update(offsetY: CGFloat, maxOffsetY: CGFloat, isUserScrolling: Bool) {
        let delta = lastOffsetY.map { offsetY - $0 }
        lastOffsetY = offsetY
        if offsetY <= 0 || offsetY >= maxOffsetY {
            isHidden = false
            travel = 0
            return
        }
        guard isUserScrolling, let delta, delta != 0 else { return }
        travel = (travel < 0) == (delta < 0) ? travel + delta : delta
        if travel >= Theme.Gesture.barHideDistance {
            isHidden = true
        } else if travel <= -Theme.Gesture.barShowDistance {
            isHidden = false
        }
    }
}
