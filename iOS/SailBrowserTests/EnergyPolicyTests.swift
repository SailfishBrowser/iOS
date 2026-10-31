import Foundation
import Synchronization
import Testing
@testable import SailBrowser

// Readings over two values; every read is counted, so a post that must not reach the policy is proved by the count
// once a later post has.
nonisolated final class EnergyStub: Sendable {
    let lowPower = Mutex(false)
    let thermal = Mutex(ProcessInfo.ThermalState.fair)
    let powerReads = Mutex(0)
    let thermalReads = Mutex(0)

    var readings: EnergyPolicy.Readings {
        EnergyPolicy.Readings(
            lowPower: {
                self.powerReads.withLock { $0 += 1 }
                return self.lowPower.withLock { $0 }
            },
            thermal: {
                self.thermalReads.withLock { $0 += 1 }
                return self.thermal.withLock { $0 }
            })
    }

    var reads: Int {
        powerReads.withLock { $0 }
    }
}

// Records how many thermal reads the stub had seen when the first observer registered.
private nonisolated final class RecordingCenter: NotificationCenter, @unchecked Sendable {
    private let stub: EnergyStub
    let readsAtFirstObserver = Mutex<Int?>(nil)

    init(stub: EnergyStub) {
        self.stub = stub
        super.init()
    }

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let reads = stub.thermalReads.withLock { $0 }
        readsAtFirstObserver.withLock { $0 = $0 ?? reads }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}

@MainActor
struct EnergyPolicyTests {
    @Test func readingsFlipReducedThroughThePrivateCenter() async throws {
        let stub = EnergyStub()
        let center = NotificationCenter()
        let policy = EnergyPolicy(readings: stub.readings, center: center)
        #expect(!policy.isReduced)
        stub.lowPower.withLock { $0 = true }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { policy.isReduced }
        stub.lowPower.withLock { $0 = false }
        stub.thermal.withLock { $0 = .serious }
        var reads = stub.reads
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await waitUntil { stub.reads == reads + 1 }
        #expect(policy.isReduced)
        stub.thermal.withLock { $0 = .fair }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await waitUntil { !policy.isReduced }
        stub.lowPower.withLock { $0 = true }
        reads = stub.reads
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { policy.isReduced }
        #expect(stub.reads == reads + 1)
        let hot = EnergyStub()
        hot.thermal.withLock { $0 = .critical }
        #expect(EnergyPolicy(readings: hot.readings, center: center).isReduced)
    }

    // With Low Power Mode on at launch the thermal state is still read: the system sends its change only to a process
    // that has read it.
    @Test func theThermalReadingPrecedesRegistration() {
        let stub = EnergyStub()
        stub.lowPower.withLock { $0 = true }
        let center = RecordingCenter(stub: stub)
        _ = EnergyPolicy(readings: stub.readings, center: center)
        let reads = center.readsAtFirstObserver.withLock { $0 }
        #expect(reads != nil && reads! >= 1)
    }
}
