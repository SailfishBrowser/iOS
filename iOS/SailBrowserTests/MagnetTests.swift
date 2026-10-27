import CoreGraphics
import Testing
@testable import SailBrowser

struct MagnetTests {
    @Test func rubberBandIsContinuousAndBounded() {
        #expect(Magnet.rubberBand(0, stretch: 60) == 0)
        let step: CGFloat = 1e-4
        #expect(abs(Magnet.rubberBand(step, stretch: 60) / step - 0.55) < 0.001)
        #expect(Magnet.rubberBand(10_000, stretch: 60) < 60)
        for x: CGFloat in [0.5, 7, 40, 300] {
            #expect(Magnet.rubberBand(-x, stretch: 20) == -Magnet.rubberBand(x, stretch: 20))
        }
    }

    @Test func projectionUsesTheGivenRate() {
        #expect(abs(Magnet.project(velocity: 1000, rate: 0.998) - 499) < 1e-6)
        #expect(abs(Magnet.project(velocity: 1000, rate: 0.99) - 99) < 1e-6)
        #expect(abs(Magnet.project(velocity: -500, rate: 0.998) + 249.5) < 1e-6)
    }

    @Test func detentArmsOnceAndRearmsBelowHysteresis() {
        var detent = Detent(line: 80)
        let events = [79, 80, 76, 71, 80].map { detent.update($0) }
        #expect(events == [nil, .armed, nil, .disarmed, .rearmed])
        #expect(detent.isArmed)
        #expect(detent.hasArmed)
    }

    @Test func sheetClosesWhileArmedEvenBelowTheLine() {
        #expect(SheetDrag.closes(armed: true, translation: 76, velocity: 0))
        #expect(!SheetDrag.closes(armed: false, translation: 79, velocity: 0))
    }
}
