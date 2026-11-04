import CoreGraphics

nonisolated struct DeckGesture: Equatable, Sendable {
    enum Axis: Sendable { case horizontal, vertical }

    let start: CGFloat
    let cardIndex: Int?
    private(set) var axis: Axis?
    private var lockTranslation = CGSize.zero
    private var leadLeft: CGFloat = 1
    var archive: Detent

    init(start: CGFloat, cardIndex: Int?, cardHeight: CGFloat) {
        self.start = start
        self.cardIndex = cardIndex
        archive = Detent(line: Theme.Gesture.archiveCommitFraction * cardHeight)
    }

    // Records the translation at the lock once, so the drag moves 1:1 from that frame.
    mutating func lock(_ translation: CGSize) -> Axis? {
        guard axis == nil, hypot(translation.width, translation.height) >= Theme.Gesture.deckAxisLock else {
            return nil
        }
        axis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
        lockTranslation = translation
        return axis
    }

    func effective(_ translation: CGSize) -> CGSize {
        CGSize(width: translation.width - lockTranslation.width, height: translation.height - lockTranslation.height)
    }

    mutating func lifted(_ translation: CGFloat) -> CGFloat {
        let lock = Theme.Gesture.deckAxisLock
        let lead = min(max(lockTranslation.height, -lock), lock)
        let since = abs(translation - lockTranslation.height)
        leadLeft = min(leadLeft, max(0, 1 - since / (abs(lead) * Theme.Gesture.tabStackFlickCatchUp)))
        return translation - lead * leadLeft
    }
}
