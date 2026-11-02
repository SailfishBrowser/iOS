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

// A horizontal release in the deck, as a scroll view without paging decelerates: it coasts at the platform's fast
// deceleration, so it follows the finger and stops soon after the lift, and rests where it slows under the landed
// speed. A coast that reaches an end of the deck carries its speed there into a spring about that end, drawn through
// the end's stretch, and comes back to rest on it.
nonisolated struct DeckGlide: Equatable, Sendable {
    static let rate = 1000 * (1 - Theme.Gesture.decelerationFast) / Theme.Gesture.decelerationFast

    let from: CGFloat
    // Positions per second.
    let velocity: CGFloat
    let start: ContinuousClock.Instant
    // Drawn points per position.
    let stride: CGFloat
    let last: CGFloat

    private var restSpeed: CGFloat {
        Theme.Gesture.landedSpeed / stride
    }

    private var rest: CGFloat {
        abs(velocity) <= restSpeed ? from : from + (velocity - copysign(restSpeed, velocity)) / Self.rate
    }

    var edge: CGFloat? {
        rest < 0 ? 0 : rest > last ? last : nil
    }

    var end: CGFloat {
        edge ?? rest
    }

    // The coast loses speed in proportion to the distance it covers.
    private var edgeSpeed: CGFloat {
        velocity - Self.rate * (end - from)
    }

    private var coastDuration: TimeInterval {
        guard abs(velocity) > restSpeed else { return 0 }
        return Double(log(velocity / (edge == nil ? copysign(restSpeed, velocity) : edgeSpeed)) / Self.rate)
    }

    func isSettled(at time: ContinuousClock.Instant) -> Bool {
        let elapsed = (time - start) / .seconds(1)
        guard elapsed >= coastDuration else { return false }
        guard edge != nil else { return true }
        let bounce = elapsed - coastDuration
        return bounce >= DeckSnap.snap.settlingDuration
            || abs(raw(at: elapsed) - end) * stride <= Theme.Gesture.landedPoints
                && abs(velocity(at: time)) * stride <= Theme.Gesture.landedSpeed
    }

    func velocity(at time: ContinuousClock.Instant) -> CGFloat {
        let elapsed = (time - start) / .seconds(1)
        guard elapsed >= coastDuration else { return velocity * exp(-Self.rate * CGFloat(elapsed)) }
        guard edge != nil else { return 0 }
        return DeckSnap.snap.velocity(target: 0, initialVelocity: edgeSpeed, time: elapsed - coastDuration)
    }

    func position(at time: ContinuousClock.Instant) -> CGFloat {
        isSettled(at: time) ? end : CardLayout.stretched(raw(at: (time - start) / .seconds(1)), last: last)
    }

    private func raw(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed >= coastDuration else {
            return from + velocity / Self.rate * (1 - exp(-Self.rate * CGFloat(elapsed)))
        }
        guard edge != nil else { return rest }
        return end + DeckSnap.snap.value(target: 0, initialVelocity: edgeSpeed, time: elapsed - coastDuration)
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
