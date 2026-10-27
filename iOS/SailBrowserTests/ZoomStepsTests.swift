import Testing
@testable import SailBrowser

struct ZoomStepsTests {
    @Test func zoomStepsSnapOffTableValues() {
        #expect(ZoomSteps.next(after: 1.1) == 1.15)
        #expect(ZoomSteps.previous(before: 1.1) == 1.0)
        #expect(ZoomSteps.next(after: 1.0) == 1.15)
        #expect(ZoomSteps.previous(before: 1.0) == 0.85)
        #expect(ZoomSteps.next(after: 0.1) == 0.5)
        #expect(ZoomSteps.previous(before: 4) == 3.0)
    }

    @Test func zoomStepsStopAtEnds() {
        #expect(ZoomSteps.all == [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
        #expect(ZoomSteps.previous(before: 0.5) == nil)
        #expect(ZoomSteps.next(after: 3.0) == nil)
        #expect(ZoomSteps.next(after: 2.5) == 3.0)
        #expect(ZoomSteps.previous(before: 0.75) == 0.5)
    }
}
