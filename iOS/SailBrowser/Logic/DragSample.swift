import SwiftUI

nonisolated struct DragSample: Equatable, Sendable {
    var startLocation: CGPoint
    var location: CGPoint
    var translation: CGSize
    var velocity: CGSize
    var time: Date
}

extension DragSample {
    init(_ value: DragGesture.Value) {
        self.init(
            startLocation: value.startLocation, location: value.location, translation: value.translation,
            velocity: value.velocity, time: value.time)
    }
}

nonisolated enum DragPhase: Sendable {
    case began, changed, ended, cancelled
}
