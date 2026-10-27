import CoreGraphics
import Testing
@testable import SailBrowser

struct BarVisibilityTests {
    private let maxOffsetY: CGFloat = 2000

    private func scrolled(_ offsets: [CGFloat], from start: BarVisibility = BarVisibility(), user: Bool = true) -> BarVisibility {
        var bar = start
        for offset in offsets {
            bar.update(offsetY: offset, maxOffsetY: maxOffsetY, isUserScrolling: user)
        }
        return bar
    }

    @Test func hidesAfter24DownAndShowsAfter12Up() {
        let down = scrolled([100, 110, 123])
        #expect(!down.isHidden)
        let hidden = scrolled([124], from: down)
        #expect(hidden.isHidden)
        #expect(scrolled([113], from: hidden).isHidden)
        #expect(!scrolled([112], from: hidden).isHidden)
    }

    @Test func directionReversalResetsAccumulator() {
        let bar = scrolled([100, 120, 115, 135])
        #expect(!bar.isHidden)
        #expect(scrolled([139], from: bar).isHidden)
    }

    @Test func bounceAtTopNeverHides() {
        let bounce = scrolled([0, -20, -60, -10, 0, -5])
        #expect(!bounce.isHidden)
        let hidden = scrolled([100, 200])
        #expect(hidden.isHidden)
        #expect(!scrolled([-1], from: hidden, user: false).isHidden)
        #expect(!scrolled([0, 20, 23], from: bounce).isHidden)
    }

    @Test func bottomOfPageShowsBar() {
        let hidden = scrolled([1000, 1900])
        #expect(hidden.isHidden)
        #expect(!scrolled([maxOffsetY], from: hidden).isHidden)
        #expect(!scrolled([maxOffsetY + 40], from: hidden).isHidden)
    }

    @Test func programmaticScrollsAreIgnored() {
        let jumped = scrolled([100, 900], user: false)
        #expect(!jumped.isHidden)
        #expect(!scrolled([920], from: jumped).isHidden)
        let hidden = scrolled([100, 200])
        #expect(scrolled([50], from: hidden, user: false).isHidden)
    }
}
