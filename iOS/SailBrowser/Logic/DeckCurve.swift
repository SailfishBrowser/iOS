import CoreGraphics
import Foundation
import SwiftUI

extension DeckSnap {
    func retargeted(to target: CGFloat, at time: ContinuousClock.Instant, spring: Spring) -> DeckSnap {
        let presented = position(at: time)
        let speed = isSettled(at: time) ? 0 : velocity(at: time)
        let distance = target - presented
        return DeckSnap(
            from: presented, to: target, velocity: distance == 0 ? 0 : Double(speed / distance), start: time,
            spring: spring, points: points)
    }
}

// Coasts from a release at the platform's normal deceleration, so it starts at the finger's speed and only slows,
// and stops on `to`, which its start speed must be enough to pass.
nonisolated struct DeckCoast: Equatable, Sendable {
    // Per second, so that the coast's whole distance is Magnet.project's for the same velocity.
    static let rate = 1000 * (1 - Theme.Gesture.decelerationNormal) / Theme.Gesture.decelerationNormal

    let from: CGFloat
    let to: CGFloat
    let velocity: CGFloat
    let start: ContinuousClock.Instant

    var duration: TimeInterval {
        Double(-log(1 - Self.rate * (to - from) / velocity) / Self.rate)
    }

    func isSettled(at time: ContinuousClock.Instant) -> Bool {
        (time - start) / .seconds(1) >= duration
    }

    func value(at time: ContinuousClock.Instant) -> CGFloat {
        let elapsed = (time - start) / .seconds(1)
        guard elapsed < duration else { return to }
        return from + velocity / Self.rate * (1 - exp(-Self.rate * CGFloat(elapsed)))
    }
}

nonisolated enum DeckCurve: Equatable, Sendable {
    case snap(DeckSnap)
    case coast(DeckCoast)

    func isSettled(at time: ContinuousClock.Instant) -> Bool {
        switch self {
        case .snap(let snap): snap.isSettled(at: time)
        case .coast(let coast): coast.isSettled(at: time)
        }
    }

    func value(at time: ContinuousClock.Instant) -> CGFloat {
        switch self {
        case .snap(let snap): snap.position(at: time)
        case .coast(let coast): coast.value(at: time)
        }
    }
}
