import Foundation
import Testing
@testable import SailBrowser

struct SnapshotBudgetTests {
    // The deck's rest span must fit in the spare, so a capture landing while the switcher rests never blanks a built
    // card. If this fails, Theme.Snapshot.spareDecoded goes up.
    @Test func theRestSpanFitsTheSpare() {
        for p in 0..<20 {
            #expect(CardLayout.span(from: CGFloat(p), to: CGFloat(p)).count <= Theme.Snapshot.spareDecoded)
        }
    }
}
