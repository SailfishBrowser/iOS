import CoreGraphics
import Testing
@testable import SailBrowser

struct PullToRefreshTests {
    @Test func armsOnlyWhenTheRingCloses() {
        var pull = PullToRefresh()
        #expect(pull.update(overscroll: 75) == .ticked(6))
        #expect(pull.progress == 0.5)
        #expect(pull.update(overscroll: 149) == .ticked(13))
        #expect(pull.update(overscroll: 150) == .armed)
        #expect(pull.progress == 1)
    }

    // One tick per step, out and back, naming the boundary just crossed; nothing once the pull has armed.
    @Test func everyStepTicksOutAndBackUntilTheArm() {
        var pull = PullToRefresh()
        let events = [9, 10, 19, 20, 15, 9, 10, 150, 100, 130].map { pull.update(overscroll: CGFloat($0)) }
        #expect(
            events == [nil, .ticked(0), nil, .ticked(1), .ticked(1), .ticked(0), .ticked(0), .armed, .disarmed, nil])
    }

    @Test func aFrameThatCrossesSeveralStepsTicksTheFurthest() {
        var pull = PullToRefresh()
        #expect(pull.update(overscroll: 45) == .ticked(3))
        #expect(pull.update(overscroll: 5) == .ticked(0))
    }

    @Test func aFrameThatCrossesAStepAndTheLineOnlyArms() {
        var pull = PullToRefresh()
        #expect(pull.update(overscroll: 100) == .ticked(9))
        #expect(pull.update(overscroll: 200) == .armed)
    }

    // The arm line is the step after the last tick, so the thock takes the last step's place.
    @Test func theArmIsTheStepAfterTheLastTick() {
        let r = Theme.Refresh.self
        #expect(r.armDistance == r.tickStep * CGFloat(Theme.Haptic.refreshTicks.count + 1))
        var pull = PullToRefresh()
        #expect(pull.update(overscroll: r.armDistance - r.tickStep) == .ticked(Theme.Haptic.refreshTicks.count - 1))
        #expect(pull.update(overscroll: r.armDistance) == .armed)
    }

    // The level is the page's speed over the frame as a share of the texture's full speed, with the pull's progress as
    // sharpness: the first frame has no speed, a frame at rest none, one at full speed one, and faster still one.
    @Test func theLevelFollowsTheFramesMovementAndThePullsProgress() {
        var pull = PullToRefresh()
        let start = ContinuousClock.now
        let frame = Theme.Latency.frame
        let full = Theme.Haptic.pullTextureSpeed * CGFloat(frame / .seconds(1))
        _ = pull.update(overscroll: 0)
        #expect(!pull.isPulling)
        _ = pull.update(overscroll: 15)
        #expect(pull.isPulling)
        let first = pull.level(at: start)
        #expect(first == HapticTexture.Level(intensity: 0, sharpness: 0.1))
        _ = pull.update(overscroll: 15 + full / 2)
        let half = pull.level(at: start + frame)
        #expect(abs(half.intensity - 0.5) < 1e-5)
        #expect(half.sharpness == Float(pull.progress))
        let still = pull.level(at: start + frame * 2)
        #expect(still == HapticTexture.Level(intensity: 0, sharpness: half.sharpness))
        _ = pull.update(overscroll: 15 + full / 2 + 2 * full)
        let fast = pull.level(at: start + frame * 3)
        #expect(fast.intensity == 1)
        _ = pull.update(overscroll: 150)
        let armed = pull.level(at: start + frame * 4)
        #expect(armed.sharpness == 1)
        let refreshed = pull.release()
        #expect(refreshed)
        #expect(!pull.isPulling)
    }

    @Test func chatterDoesNotRearm() {
        var pull = PullToRefresh()
        let events = [150, 148, 151, 145, 152].map { pull.update(overscroll: CGFloat($0)) }
        #expect(events == [.armed, nil, nil, nil, nil])
        #expect(pull.update(overscroll: 141) == .disarmed)
        #expect(pull.update(overscroll: 150) == .rearmed)
    }

    @Test func releaseRefreshesWhileArmedThroughHysteresis() {
        var pull = PullToRefresh()
        _ = pull.update(overscroll: 150)
        _ = pull.update(overscroll: 144)
        let refreshed = pull.release()
        #expect(refreshed)
        #expect(pull == PullToRefresh())

        _ = pull.update(overscroll: 149)
        let refreshedBelow = pull.release()
        #expect(!refreshedBelow)
    }
}
