import SwiftUI
import Testing
@testable import SailBrowser

@MainActor
struct InteractionProbeTests {
    @Test func aSharedActionIsRemovedOnlyByItsLastPublisher() {
        let env = makeEnvironment()
        let first = UUID()
        let second = UUID()
        var ran: [String] = []
        env.publishDebugAction(.plusTap, owner: first) { ran.append("browsing") }
        env.publishDebugAction(.plusTap, owner: second) { ran.append("switcher") }
        env.withdrawDebugAction(.plusTap, owner: first)
        env.debugActions[.plusTap]!()
        #expect(ran == ["switcher"])
        env.withdrawDebugAction(.plusTap, owner: second)
        #expect(env.debugActions[.plusTap] == nil)
    }

    @Test func aSurfaceAndAWatchAreRemovedOnlyByTheirLastPublisher() {
        let env = makeEnvironment()
        let outgoing = UUID()
        let incoming = UUID()
        var handled: [String] = []
        env.publishDebugSurface(.webScroll, owner: outgoing) { _, _ in handled.append("outgoing") }
        env.publishDebugWatch(.webScroll, owner: outgoing) { 1 }
        env.publishDebugSurface(.webScroll, owner: incoming) { _, _ in handled.append("incoming") }
        env.publishDebugWatch(.webScroll, owner: incoming) { 2 }

        env.withdrawDebugSurface(.webScroll, owner: outgoing)
        env.withdrawDebugWatch(.webScroll, owner: outgoing)
        let sample = DragSample(startLocation: .zero, location: .zero, translation: .zero, velocity: .zero, time: .now)
        env.debugSurfaces[.webScroll]!(.changed, sample)
        #expect(handled == ["incoming"])
        #expect(env.debugWatches[.webScroll]!() == 2)

        env.withdrawDebugSurface(.webScroll, owner: incoming)
        env.withdrawDebugWatch(.webScroll, owner: incoming)
        #expect(env.debugSurfaces[.webScroll] == nil)
        #expect(env.debugWatches[.webScroll] == nil)
    }

    @Test func aFingerBeginsMovesEachFrameAndEndsOnItsLastKeyframe() async {
        var phases: [DragPhase] = []
        var samples: [DragSample] = []
        let start = CGPoint(x: 200, y: 400)
        await DebugFinger(path: [.zero, CGSize(width: 0, height: 120)], duration: 0.1, start: start).run {
            phases.append($0)
            samples.append($1)
        }
        #expect(phases.first == .began)
        #expect(phases.last == .ended)
        #expect(phases.dropFirst().dropLast().allSatisfy { $0 == .changed })
        #expect(phases.count >= 4)
        #expect(samples.first!.translation == .zero)
        let last = samples.last!
        #expect(last.translation == CGSize(width: 0, height: 120))
        #expect(last.location == CGPoint(x: 200, y: 520))
        #expect(last.startLocation == start)
        #expect(last.velocity.height > 0)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    // A clamped final step can be a rounding error long: two frames that close must still keep their order.
    @Test func framesARoundingErrorApartKeepTheirOrderInSampleTime() {
        let origin: CFTimeInterval = 86_400.25
        let originTime = Date()
        let end = origin + 0.1
        let timestamps = [origin, end.nextDown.nextDown, end.nextDown, end, end]
        let times = timestamps.map { DebugFinger.time(of: $0, origin: origin, originTime: originTime) }
        #expect(times.first == originTime)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(times[3] == times[4])
    }

    @Test func aFifteenHundredthsThrowReleasesAtThePathsSpeed() async {
        for _ in 0..<5 {
            var released: DragSample?
            await DebugFinger(path: [.zero, CGSize(width: 0, height: -300)], duration: 0.15, start: .zero).run {
                if $0 == .ended { released = $1 }
            }
            let speed = released!.velocity.height
            #expect(abs(speed + 2000) < 20, "released at \(speed) pt/s")
            #expect(released!.translation.height == -300)
        }
    }

    @Test func aThrowWhoseLastFrameOvershootsEndsWithinItsFrameCount() async {
        let duration = 0.155
        var changed = 0
        var released: DragSample?
        await DebugFinger(path: [.zero, CGSize(width: 0, height: -310)], duration: duration, start: .zero).run {
            switch $0 {
            case .changed:
                changed += 1
                #expect($1.velocity.height.isFinite)
            case .ended: released = $1
            case .began, .cancelled: break
            }
        }
        #expect(changed <= Int((duration * Theme.Latency.frameRate).rounded(.up)) + 2)
        #expect(released!.translation.height == -310)
        #expect(abs(released!.velocity.height + 2000) < 20)
    }

    // 0.16 s is never a whole number of frames at 60 or 120 Hz, so the last frame always clamps. On this eased path
    // each step has its own speed, so the release must equal the last real step's, not the clamped step's.
    @Test func anEasedReleaseCarriesTheLastRealStepsVelocity() async {
        var steps: [DragSample] = []
        var released: DragSample?
        let path = (0...4).map { CGSize(width: 0, height: -10 * CGFloat($0 * $0)) }
        await DebugFinger(path: path, duration: 0.16, start: .zero).run {
            switch $0 {
            case .changed: steps.append($1)
            case .ended: released = $1
            case .began, .cancelled: break
            }
        }
        #expect(steps.count >= 2)
        #expect(released!.translation == path.last!)
        #expect(released!.velocity == steps[steps.count - 2].velocity)
    }

    @Test func theProbeMeasuresFromTheRecordToTheFirstChangedFrame() async {
        let env = makeEnvironment()
        var value: CGFloat = 0
        env.haptics.fire(.searchSubmit)
        Task {
            try await Task.sleep(for: .milliseconds(50))
            value = 1
        }
        let write = await InteractionProbe.watch(.searchSubmit, in: env, from: 0) { value }
        #expect(write >= .milliseconds(50))
        #expect(write < .milliseconds(500))
    }

    @Test(.timeLimit(.minutes(1))) func aValueAlreadyChangedBeforeTheWatchCountsFromTheCallersBaseline() async {
        let env = makeEnvironment()
        var value: CGFloat = 0
        env.haptics.fire(.pullRelease)
        value = 1
        let write = await InteractionProbe.watch(.pullRelease, in: env, from: 0) { value }
        #expect(write < .milliseconds(500))
    }

    // A drag recorded at its release: the value moved with every sample, then settles a while after the release.
    // A baseline read before the finger would return on the first frame; the release baseline waits for the settle.
    @Test(.timeLimit(.minutes(1))) func aDragWatchesFromTheSampleThatRecords() async {
        let env = makeEnvironment(hapticSink: LiveHapticSink())
        let sheet = Settling()
        let finger = DebugFinger(
            path: [.zero, CGSize(width: 0, height: 60)], duration: 0.1, start: .zero)
        let write = await InteractionProbe.drag(finger, into: { phase, _ in
            switch phase {
            case .changed:
                sheet.top += 1
            case .ended:
                env.haptics.fire(.searchDragReturn)
                Task {
                    try await Task.sleep(for: .milliseconds(150))
                    sheet.top = -1
                }
            case .began, .cancelled:
                break
            }
        }, watching: .searchDragReturn, in: env) { sheet.top }
        #expect(sheet.top == -1)
        #expect(write >= .milliseconds(120))
    }

    @Test(.timeLimit(.minutes(1))) func aRefusedDragReturnsNothing() async {
        let env = makeEnvironment()
        let finger = DebugFinger(path: [.zero, CGSize(width: -40, height: 0)], duration: 0.05, start: .zero)
        let write = await InteractionProbe.attemptDrag(finger, into: { _, _ in }, watching: .deckScroll, in: env) { 0 }
        #expect(write == nil)
    }

    // A spring's steps rise to a peak and fall away; its visible end is the first step at or under the fraction of
    // the peak, never the still start before it has moved.
    @Test func aMotionVisiblyEndsWhenItsStepFallsToAFractionOfItsFastest() {
        var end = VisibleEnd(fraction: 0.02)
        end.step(0)
        #expect(!end.isReached)
        for delta: CGFloat in [10, 40, 50, 20, 5, 1.5] {
            end.step(delta)
            #expect(!end.isReached)
        }
        end.step(-0.9)
        #expect(end.isReached)
    }
}

private final class Settling {
    var top: CGFloat = 0
}
