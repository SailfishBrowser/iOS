import CoreGraphics

nonisolated struct DeckGesture: Equatable, Sendable {
    enum Axis: Sendable { case horizontal, vertical }

    let start: CGFloat
    let cardIndex: Int?
    private(set) var axis: Axis?
    private var lockHeight: CGFloat = 0
    private var leadLeft: CGFloat = 1
    var archive: Detent

    init(start: CGFloat, cardIndex: Int?, cardHeight: CGFloat) {
        self.start = start
        self.cardIndex = cardIndex
        archive = Detent(line: Theme.Gesture.archiveCommitFraction * cardHeight)
    }

    mutating func lock(_ translation: CGSize) -> Axis? {
        guard axis == nil, hypot(translation.width, translation.height) >= Theme.Gesture.deckAxisLock else {
            return nil
        }
        axis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
        lockHeight = translation.height
        return axis
    }

    mutating func lifted(_ translation: CGFloat) -> CGFloat {
        let lock = Theme.Gesture.deckAxisLock
        let lead = min(max(lockHeight, -lock), lock)
        let since = abs(translation - lockHeight)
        leadLeft = min(leadLeft, max(0, 1 - since / (abs(lead) * Theme.Gesture.tabStackFlickCatchUp)))
        return translation - lead * leadLeft
    }
}
