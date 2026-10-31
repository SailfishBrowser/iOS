import Testing
@testable import SailBrowser

struct ConnectivityTests {
    @Test func aFlapInsideOneTurnCountsOnce() {
        let connectivity = Connectivity(monitor: nil)
        connectivity.apply(online: false, constrained: false, expensive: false)
        connectivity.apply(online: true, constrained: false, expensive: false)
        #expect(connectivity.reconnects == 1)
        connectivity.apply(online: true, constrained: false, expensive: false)
        #expect(connectivity.reconnects == 1)
        connectivity.apply(online: false, constrained: false, expensive: false)
        #expect(connectivity.reconnects == 1)
        connectivity.apply(online: true, constrained: false, expensive: false)
        #expect(connectivity.reconnects == 2)
    }
}
