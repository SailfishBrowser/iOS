import Foundation
import Observation

// Whether discretionary work should stop: Low Power Mode is on, or the phone is hot. Read at init, then kept current
// by the system's two notifications; nothing is latched, so the gates open again on the next change. The frame-rate
// range is left to the system, which caps it in Low Power Mode itself.
@Observable final class EnergyPolicy {
    nonisolated struct Readings: Sendable {
        var lowPower: @Sendable () -> Bool
        var thermal: @Sendable () -> ProcessInfo.ThermalState

        static let live = Readings(
            lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            thermal: { ProcessInfo.processInfo.thermalState })
    }

    private(set) var isReduced: Bool
    @ObservationIgnored private let readings: Readings
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    // The thermal state is read before the observers register: the system delivers its change notification only to
    // a process that has read it.
    init(readings: Readings = .live, center: NotificationCenter = .default) {
        self.readings = readings
        self.center = center
        isReduced = Self.reduced(readings)
        let names = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reread() }
            }
        }
    }

    isolated deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func reread() {
        let reduced = Self.reduced(readings)
        if reduced != isReduced {
            isReduced = reduced
        }
    }

    // Both readings every time: the thermal read happens even when Low Power Mode already decides.
    private static func reduced(_ readings: Readings) -> Bool {
        let lowPower = readings.lowPower()
        let thermal = readings.thermal()
        return lowPower || thermal.rawValue >= Theme.Energy.reducedThermalState.rawValue
    }
}
