import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

extension CAAnimation {
    var asksForFullRate: Bool {
        let (range, full) = (preferredFrameRateRange, Theme.Latency.frameRateRange)
        return range.minimum == full.minimum && range.maximum == full.maximum && range.preferred == full.preferred
    }
}

@MainActor
struct LayerAnimationRateTests {
    @Test func everyLayerAnimationAsksForTheDecksRate() {
        for token in [Theme.Motion.submitFadeOut, Theme.Motion.searchSubmitRise, Theme.Motion.searchBehindClose, .keyboard] {
            #expect(token.layerAnimation(keyPath: "opacity", from: 0).asksForFullRate)
        }
    }

    @Test func theKeyboardTokenRunsOnItsOwnSpringWithTheGivenVelocity() {
        let animation = MotionToken.keyboard.layerAnimation(keyPath: "opacity", from: 0, initialVelocity: 1.5)
        let spring = MotionToken.keyboard.spring
        let rise = animation as? CASpringAnimation
        #expect(rise.map { abs($0.stiffness - spring.stiffness) < 1e-6 } == true)
        #expect(rise.map { abs($0.damping - spring.damping) < 1e-6 } == true)
        #expect(rise?.initialVelocity == 1.5)
    }
}

@MainActor
@Suite(.serialized)
struct FrameRateVoteTests {
    @Test func aTokenSettlesOverItsSpringOrItsCurve() {
        #expect(Theme.Motion.bar.settlingDuration == Theme.Motion.bar.spring.settlingDuration)
        #expect(MotionToken.keyboard.settlingDuration == MotionToken.keyboard.spring.settlingDuration)
        #expect(Theme.Motion.fieldGrow.settlingDuration == 0.15)
    }

    // The vote is held through the longest transition asking for it and released after it settles.
    @Test(.timingSensitive) func theVoteHoldsUntilTheLatestTransitionSettles() async throws {
        FrameRateVote.hold(for: 0.05)
        FrameRateVote.hold(for: 0.2)
        FrameRateVote.hold(for: 0.05)
        #expect(FrameRateVote.isHolding)
        #expect(FrameRateVote.heldUntil >= CACurrentMediaTime() + 0.15)
        try await Task.sleep(for: .milliseconds(120))
        #expect(FrameRateVote.isHolding)
        try await waitUntil { !FrameRateVote.isHolding }
    }
}
