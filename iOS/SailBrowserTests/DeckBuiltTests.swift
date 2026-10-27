import Foundation
import Testing
@testable import SailBrowser

// The deck builds the cards in its span, the active card, and the cards a swipe or a flick pins, from inputs that
// change once per gesture.
struct DeckBuiltTests {
    @Test func theBuiltCardsAreTheSpanTheActiveAndThePinned() {
        let ids = (0..<8).map { _ in UUID() }
        let plain = DeckView.built(ids: ids, activeIndex: 6, span: 1...3, pinned: [])
        #expect(plain == [1, 2, 3, 6])
        let pinned = DeckView.built(ids: ids, activeIndex: 2, span: 1...3, pinned: [ids[7], ids[0]])
        #expect(pinned == [0, 1, 2, 3, 7])
        #expect(DeckView.built(ids: ids, activeIndex: 2, span: 1...3, pinned: [ids[7], ids[0]]) == pinned)
        #expect(DeckView.built(ids: ids, activeIndex: 0, span: -4...1, pinned: [UUID()]) == [0, 1])
    }
}
