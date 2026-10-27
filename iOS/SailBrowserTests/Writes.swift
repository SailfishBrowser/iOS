import Observation

// Counts the writes to whatever `read` reads on an observable, one per assignment: the observation fires once per
// registration, synchronously as the value is about to change, so it re-registers inside its own change.
@MainActor final class Writes {
    private(set) var count = 0
    private let read: () -> Void

    init(_ read: @escaping () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}
