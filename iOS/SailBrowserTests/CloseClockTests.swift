import QuartzCore
import Testing
@testable import SailBrowser

@MainActor
struct CloseClockTests {
    private static let at120: CFTimeInterval = 1.0 / 120
    private static let at60: CFTimeInterval = 1.0 / 60

    // A step runs on the link tick nearest its own time, up to half a link frame early or late at any rate. At 120 Hz a
    // display frame falls halfway between two recorded 60 Hz frames.
    @Test func frameKIsTheFirstLinkFrameWithinHalfALinkFrameOfItsTime() {
        let begin: CFTimeInterval = 100
        #expect(CloseClock.frame(at: begin, since: begin, linkFrame: Self.at120) == 0)
        #expect(CloseClock.frame(at: begin + 6.0 / 60, since: begin, linkFrame: Self.at120) == 6)
        #expect(CloseClock.frame(at: begin + 5.8 / 60, since: begin, linkFrame: Self.at120) == 6)
        #expect(CloseClock.frame(at: begin + 6.4 / 60, since: begin, linkFrame: Self.at120) == 6)
        #expect(CloseClock.frame(at: begin + 5.5 / 60, since: begin, linkFrame: Self.at120) == 5)
        #expect(CloseClock.frame(at: begin + 1.0 / 120, since: begin, linkFrame: Self.at120) == 0)
    }

    // At 60 Hz a step whose next tick is 0.6 frame after it runs on the tick 0.4 frame before it.
    @Test func atSixtyHertzAStepRunsOnTheTickNearestItsTime() {
        let begin: CFTimeInterval = 100
        #expect(CloseClock.frame(at: begin + 5.6 / 60, since: begin, linkFrame: Self.at60) == 6)
        #expect(CloseClock.frame(at: begin + 5.4 / 60, since: begin, linkFrame: Self.at60) == 5)
    }

    @Test func eachStepRunsOnceOnItsOwnFrameInOrder() {
        let begin: CFTimeInterval = 100
        var ran: [Int] = []
        let clock = CloseClock(begin: begin, in: CALayer(), steps: [(5, { ran.append(5) }), (6, { ran.append(6) })])
        clock.advance(to: begin + 4.0 / 60, linkFrame: Self.at120)
        #expect(ran.isEmpty)
        clock.advance(to: begin + 5.0 / 60, linkFrame: Self.at120)
        #expect(ran == [5])
        clock.advance(to: begin + 5.0 / 60, linkFrame: Self.at120)
        #expect(ran == [5])
        clock.advance(to: begin + 8.0 / 60, linkFrame: Self.at120)
        #expect(ran == [5, 6])
    }

    @Test func aLateFrameRunsEveryStepThatIsDue() {
        let begin: CFTimeInterval = 100
        var ran: [Int] = []
        let clock = CloseClock(begin: begin, in: CALayer(), steps: [(5, { ran.append(5) }), (6, { ran.append(6) })])
        clock.advance(to: begin + 7.0 / 60, linkFrame: Self.at120)
        #expect(ran == [5, 6])
    }
}

@MainActor
struct SheetSpringTests {
    // The close keeps its top spring's speed, so a "+" during the close reopens with it.
    @Test func theTopsSpeedStartsAtItsVelocityPicksUpAndSettles() {
        let top = SheetSpring(
            begin: 100, travel: 500, spring: Theme.Motion.searchTapClose, velocity: Theme.Motion.searchTapCloseVelocity)
        #expect(abs(top.speed(at: 100) - 500) < 1e-6)
        #expect(top.speed(at: 100.08) > 1000)
        #expect(abs(top.speed(at: 102)) < 1)
    }
}
