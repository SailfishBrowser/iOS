import Testing
@testable import SailBrowser

struct TouchDownLatchTests {
    @Test func firesOncePerTouchAndAgainOnceTheStateResets() {
        var latched = false
        #expect(TouchDownLatch.fires(&latched))
        #expect(latched)
        #expect(!TouchDownLatch.fires(&latched))
        latched = false
        #expect(TouchDownLatch.fires(&latched))
    }
}
