import CoreGraphics

nonisolated struct DeckGesture: Equatable, Sendable {
    enum Axis: Sendable { case horizontal, vertical }

    let start: CGFloat
    let startCard: Int
    let cardIndex: Int?
    private(set) var axis: Axis?
    private var lockTranslation = CGSize.zero
    var archive: Detent

    init(start: CGFloat, startCard: Int, cardIndex: Int?, cardHeight: CGFloat) {
        self.start = start
        self.startCard = startCard
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
}
