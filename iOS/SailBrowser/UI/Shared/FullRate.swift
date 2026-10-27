import QuartzCore
import SwiftUI

// SwiftUI's animation clock and UIKit's view animations run at a rate the system picks, which the phone traced at
// 60 Hz. Every Core Animation animation the app builds asks for Theme.Latency.frameRateRange, every transition holds
// FrameRateVote while it runs, and the deck plays its motion per frame from a FrameClock.
final class FrameClock {
    private var link: CADisplayLink?
    private let onFrame: (CADisplayLink) -> Bool

    convenience init(onFrame: @escaping (ContinuousClock.Instant) -> Bool) {
        self.init(tick: { link in onFrame(.now + .seconds(link.targetTimestamp - CACurrentMediaTime())) })
    }

    // Frames in a layer's own time, where its animations count, so a test holding the window's clock holds them too.
    // In the app it is media time. Each frame also carries the link's own frame duration.
    convenience init(in layer: CALayer, onFrame: @escaping (CFTimeInterval, CFTimeInterval) -> Bool) {
        self.init(tick: { link in
            onFrame(layer.convertTime(link.targetTimestamp, from: nil), link.targetTimestamp - link.timestamp)
        })
    }

    private init(tick onFrame: @escaping (CADisplayLink) -> Bool) {
        self.onFrame = onFrame
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Theme.Latency.frameRateRange
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if !onFrame(link) {
            stop()
        }
    }
}

// Holds one no-op display link at the deck's rate while any transition runs, so the display stays at that rate for the
// app's Core Animation motion and frame clocks; SwiftUI's and UIKit's own clocks still pick theirs, as the header says.
// Each transition holds it for its settling time when it starts; the link's callback does nothing, and the release is a
// main-queue deadline. A surface that is up holds a Presence.
enum FrameRateVote {
    private static var link: CADisplayLink?
    private(set) static var heldUntil: CFTimeInterval = 0

    static var isHolding: Bool {
        link != nil
    }

    static func hold(_ token: MotionToken) {
        hold(for: token.settlingDuration)
    }

    static func hold(for duration: TimeInterval) {
        let end = CACurrentMediaTime() + duration
        guard end > heldUntil else { return }
        heldUntil = end
        if link == nil {
            link = votingLink()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { release() }
    }

    private static func release() {
        guard CACurrentMediaTime() >= heldUntil else { return }
        link?.invalidate()
        link = nil
    }
}

extension FrameRateVote {
    // A surface holds one for as long as it is up, its still moments included, so the keyboard and the typing under it
    // run at the deck's rate too. Dropping it releases its link.
    final class Presence {
        private let link = votingLink()

        isolated deinit {
            link.invalidate()
        }
    }
}

// A running no-op link at the deck's rate: holding one is the vote.
private func votingLink() -> CADisplayLink {
    let link = CADisplayLink(target: FrameRateVoteTarget.shared, selector: #selector(FrameRateVoteTarget.tick))
    link.preferredFrameRateRange = Theme.Latency.frameRateRange
    link.add(to: .main, forMode: .common)
    return link
}

private final class FrameRateVoteTarget: NSObject {
    static let shared = FrameRateVoteTarget()

    @objc func tick(_ link: CADisplayLink) {}
}

// A driver write reached from inside a SwiftUI animation must not pick it up. Wrapped at those entries only
// (DeckDriver.follow, the deck view's appear and cover change): a transaction makes SwiftUI flush the graph at the
// write, so no gesture or frame write sits inside one.
func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}
