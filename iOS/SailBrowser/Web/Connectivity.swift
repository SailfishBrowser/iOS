import Network
import Observation

// One path monitor for the app. The observed value is the count of returns to online, so a flap that Observation
// coalesces into one emission still counts as a transition.
@Observable
final class Connectivity {
    static let shared = Connectivity(monitor: NWPathMonitor())

    private(set) var isOnline = true
    private(set) var isConstrained = false
    private(set) var isExpensive = false
    private(set) var reconnects = 0
    private let monitor: NWPathMonitor?

    // Nil: fed only through apply, for tests.
    init(monitor: NWPathMonitor?) {
        self.monitor = monitor
        monitor?.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.apply(online: path.status == .satisfied, constrained: path.isConstrained, expensive: path.isExpensive)
            }
        }
        monitor?.start(queue: .main)
    }

    deinit {
        monitor?.cancel()
    }

    // Writes only what changed, so an equal path wakes no observer.
    func apply(online: Bool, constrained: Bool, expensive: Bool) {
        if online != isOnline {
            if online {
                reconnects += 1
            }
            isOnline = online
        }
        if constrained != isConstrained {
            isConstrained = constrained
        }
        if expensive != isExpensive {
            isExpensive = expensive
        }
    }
}
