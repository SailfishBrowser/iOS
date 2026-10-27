import Observation
import Testing
@testable import SailBrowser

struct ConnectivityTests {
    private final class Changes { var count = 0 }

    private func observeOnline(_ connectivity: Connectivity, _ changes: Changes) {
        withObservationTracking {
            _ = connectivity.isOnline
        } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
    }

    @Test func equalUpdatesDoNotWakeObservers() {
        let connectivity = Connectivity(monitor: nil)
        let changes = Changes()
        observeOnline(connectivity, changes)
        connectivity.apply(online: true, constrained: false, expensive: false)
        #expect(changes.count == 0)
        connectivity.apply(online: false, constrained: false, expensive: false)
        #expect(changes.count == 1)
        #expect(!connectivity.isOnline)
    }

    // requiresConnection and unsatisfied both read offline; constrained and expensive are carried for the energy policy.
    @Test func thePathFlagsAreCarried() {
        let connectivity = Connectivity(monitor: nil)
        #expect(connectivity.isOnline && !connectivity.isConstrained && !connectivity.isExpensive)
        connectivity.apply(online: false, constrained: true, expensive: true)
        #expect(!connectivity.isOnline && connectivity.isConstrained && connectivity.isExpensive)
        #expect(connectivity.reconnects == 0)
    }

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
