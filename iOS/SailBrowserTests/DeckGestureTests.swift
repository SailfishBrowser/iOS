import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

struct DeckGestureTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))

    @Test func axisLockDoesNotJump() {
        var gesture = DeckGesture(start: 2, startCard: 2, cardIndex: 2, cardHeight: layout.cardSize.height)
        #expect(gesture.lock(CGSize(width: 6, height: 2)) == nil)
        #expect(gesture.lock(CGSize(width: 12, height: 1)) == .horizontal)
        #expect(gesture.lock(CGSize(width: 30, height: 1)) == nil)
        #expect(gesture.axis == .horizontal)
        let effective = gesture.effective(CGSize(width: 20, height: 1))
        #expect(effective.width == 8)
        #expect(effective.height == 0)
        let position = gesture.start - effective.width / layout.stride
        #expect(layout.stretched(position, count: 5) == position)
    }

    @Test func verticalLockArmsAtTheCardLine() {
        var gesture = DeckGesture(start: 1, startCard: 1, cardIndex: 1, cardHeight: layout.cardSize.height)
        #expect(gesture.lock(CGSize(width: 3, height: -10)) == .vertical)
        #expect(gesture.archive.line == Theme.Gesture.archiveCommitFraction * layout.cardSize.height)
        #expect(gesture.archive.update(gesture.archive.line - 1) == nil)
        #expect(gesture.archive.update(gesture.archive.line) == .armed)
    }

    @Test func flickIsClampedToTwoCards() {
        let slots: [CGFloat] = [0, 1, 2, 3, 4, 5]
        let aim = 1 - (-100 + Magnet.project(velocity: -1500, rate: Theme.Gesture.decelerationNormal)) / layout.stride
        #expect(abs(aim - 4.45) < 0.01)
        #expect(layout.snapTarget(start: 1, translation: -100, velocity: -1500, slots: slots).index == 3)
    }

    @Test func settleCarriesTheFingerTowardTheTargetOnly() {
        let slots: [CGFloat] = [0, 1, 2, 3, 4]
        let stride = layout.stride
        let carried = layout.snapTarget(start: 1, translation: -0.5 * stride, velocity: -600, slots: slots)
        #expect(carried.index == 3)
        #expect(abs(carried.velocity - Double(600 / stride / 1.5)) < 1e-9)
        let away = layout.snapTarget(start: 1, translation: -0.4 * stride, velocity: -20, slots: slots)
        #expect(away.index == 1)
        #expect(away.velocity == 0)
        let arrived = layout.snapTarget(start: 1, translation: -0.02 * stride, velocity: 200, slots: slots)
        #expect(arrived.index == 1)
        #expect(arrived.velocity == 0)
    }

    // The largest overshoot past the target, as a fraction of the distance, over the snap's whole run.
    private func overshoot(_ snap: DeckSnap) -> CGFloat {
        let duration = snap.spring.settlingDuration
        let samples = (0...2000).map { snap.position(at: snap.start + .seconds(duration * Double($0) / 2000)) }
        return (samples.max()! - snap.to) / (snap.to - snap.from)
    }

    // A hard flick the two-card clamp stops short keeps the finger's speed into the snap: the spring stiffens instead.
    @Test func hardFlickNearItsTargetKeepsTheFingersSpeed() {
        let release = layout.snapTarget(start: 3.9, translation: 0, velocity: -5000, slots: [0, 1, 2, 3, 4])
        #expect(release.index == 4)
        #expect(abs(release.velocity * 0.1 - 5000 / Double(layout.stride)) < 1e-9)
        let back = layout.snapTarget(start: 0.1, translation: 0, velocity: 5000, slots: [0, 1, 2, 3, 4])
        #expect(back.index == 0)
        #expect(abs(back.velocity * 0.1 - 5000 / Double(layout.stride)) < 1e-9)
        let start = ContinuousClock.now
        let snap = DeckSnap(
            from: 3.9, to: 4, velocity: release.velocity, start: start, spring: DeckSnap.release(release.velocity))
        #expect(abs(snap.velocity(at: start) * layout.stride - 5000) < 1e-6)
    }

    // The stiffened spring keeps the bound the overshoot cap set: no more overshoot than a release at the snap's
    // natural frequency, about 1.3 percent of the distance left.
    @Test func aStiffenedSnapOvershootsNoMoreThanTheCappedOne() {
        let start = ContinuousClock.now
        let natural = (DeckSnap.snap.stiffness / DeckSnap.snap.mass).squareRoot()
        let bound = overshoot(DeckSnap(from: 0, to: 1, velocity: natural, start: start))
        #expect(bound > 0.005 && bound < 0.02)
        #expect(DeckSnap.release(natural) == DeckSnap.snap)
        #expect(DeckSnap.release(0.5) == DeckSnap.snap)
        for velocity in [natural * 1.5, natural * 4, 200] {
            let spring = DeckSnap.release(velocity)
            #expect(abs(spring.dampingRatio - DeckSnap.snap.dampingRatio) < 1e-9)
            let snap = DeckSnap(from: 0, to: 1, velocity: velocity, start: start, spring: spring)
            #expect(overshoot(snap) <= bound + 1e-6)
        }
    }

    @Test func slowLiftShortOfTheLineReturns() {
        #expect(abs(layout.cardSize.height - 621.4) < 1e-6)
        #expect(!layout.commitsArchive(armed: false, lift: -260, velocity: 0))
        #expect(layout.commitsArchive(armed: true, lift: -368, velocity: 0))
        #expect(layout.commitsArchive(armed: false, lift: -150, velocity: -1500))
    }

    @Test func slowDriftDoesNotFlick() {
        #expect(!layout.commitsArchive(armed: false, lift: -260, velocity: -100))
        #expect(!layout.commitsArchive(armed: false, lift: -300, velocity: -400))
        #expect(layout.commitsArchive(armed: false, lift: -150, velocity: -1500))
    }

    @Test func liftFollowsUpAndStretchesDown() {
        #expect(layout.lift(for: -200) == -200)
        #expect(layout.lift(for: 0) == 0)
        let down = layout.lift(for: 100)
        #expect(down > 0)
        #expect(down < Theme.Gesture.liftStretch)
        #expect(abs(layout.lift(for: 0.01) / 0.01 - Theme.Gesture.rubberBandCoefficient) < 0.001)
    }

    @Test func liftReturnKeepsTheFingersSpeed() {
        let start = ContinuousClock.now
        let slow = layout.liftReturn(from: -100, velocity: 800, start: start)
        #expect(slow.from == -100)
        #expect(slow.to == 0)
        #expect(slow.start == start)
        #expect(abs(slow.velocity - 8) < 1e-9)
        #expect(slow.spring == DeckSnap.snap)
        let hard = layout.liftReturn(from: -100, velocity: 3000, start: start)
        #expect(abs(hard.velocity - 30) < 1e-9)
        #expect(hard.spring == DeckSnap.release(30))
        #expect(layout.liftReturn(from: -100, velocity: 0, start: start).velocity == 0)
    }

    // A re-grab of a springing card takes the lift it shows and adds the finger to it, banding only the sum.
    @Test func aRegrabbedLiftContinuesFromWhereItShows() {
        #expect(layout.lift(for: 0, from: -180) == -180)
        #expect(layout.lift(for: -40, from: -180) == -220)
        #expect(layout.lift(for: 60, from: -180) == -120)
        let banded = layout.lift(for: 30)
        #expect(abs(layout.lift(for: 0, from: banded) - banded) < 1e-9)
        #expect(abs(layout.lift(for: -30, from: banded)) < 1e-9)
        #expect(layout.lift(for: 220, from: -180) == layout.lift(for: 40))
    }

    @Test func rubberBandInverseUndoesTheBand() {
        for overshoot: CGFloat in [-120, -3, 0, 0.5, 25, 400] {
            let band = Magnet.rubberBand(overshoot, stretch: Theme.Gesture.liftStretch)
            #expect(abs(Magnet.rubberBandInverse(band, stretch: Theme.Gesture.liftStretch) - overshoot) < 1e-6)
        }
    }
}

struct DeckEmptiedTests {
    @Test func throwingTheLastCardEmptiesTheDeck() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment())
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        env.open(page("only"))
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let throwCard = try #require(env.debugDeckThrow)
        throwCard()
        let deadline = ContinuousClock.now + .seconds(2)
        while !env.browser.tabs.isEmpty || !env.haptics.records.contains(where: { $0.interaction == .deckEmptied }),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(env.browser.tabs.isEmpty)
        let thrown = env.haptics.records.filter { $0.interaction == .cardThrow || $0.interaction == .deckEmptied }
        #expect(thrown.map(\.interaction) == [.cardThrow, .deckEmptied])
        #expect(thrown.last?.played == false)
        window.isHidden = true
    }
}

#if DEBUG
struct DeckDriversTests {
    @Test func everyDeckStepHasADriver() {
        let expected: Set<Interaction> = [
            .deckScroll, .cardReturn, .cardArchiveArm, .cardThrow, .deckCardTap, .deckBackgroundTap,
        ]
        #expect(Set(DeckDrivers.table.keys) == expected)
    }

    // Each deck gesture that plays runs through the real touch path and finds its generator prepared when it plays.
    // The card tap's zoom-in is silent.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (Interaction.deckScroll, Interaction.deckSettle),
    ])
    func everyDeckHapticIsPreparedBeforeItPlays(_ driven: Interaction, _ playing: Interaction) async throws {
        let sink = RecordingHapticSink(start: .now)
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment(hapticSink: sink))
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for name in ["first", "second", "third", "fourth"] {
            env.open(page(name))
        }
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil { env.debugWatches[.deck] != nil && env.debugSurfaces[.deck] != nil }
        await DeckDrivers.table[driven]!(env)
        try await waitUntil { env.haptics.records.contains { $0.interaction == playing && $0.played } }
        #expect(sink.playsArePrepared)
        window.isHidden = true
    }

    // Explicit samples, not the frame-paced arm driver: the axis lock subtracts whatever the first frame carries, so
    // a slow simulator frame can leave that driver's lift short of the line. The lift crosses the line, wobbles back
    // below it and crosses again, then releases armed: one tap, at the first crossing, and a silent release.
    @Test(.timeLimit(.minutes(1))) func anArmedThrowTapsOnceAtTheLineThroughAWobble() async throws {
        let sink = RecordingHapticSink(start: .now)
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment(hapticSink: sink))
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for name in ["first", "second", "third"] {
            env.open(page(name))
        }
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil { env.debugWatches[.deck] != nil && env.debugSurfaces[.deck] != nil }
        let layout = DeckDrivers.layout()
        let height = layout.cardSize.height
        let lock = Theme.Gesture.deckAxisLock + 2
        let rises: [CGFloat] = [0, lock, lock + 0.4 * height, lock + 0.7 * height, lock + 0.5 * height, lock + 0.7 * height]
        let surface = env.debugSurfaces[.deck]!
        for (step, rise) in rises.enumerated() {
            let translation = CGSize(width: 0, height: -rise)
            let sample = DragSample(
                startLocation: layout.slotCenter,
                location: CGPoint(x: layout.slotCenter.x, y: layout.slotCenter.y - rise), translation: translation,
                velocity: .zero, time: .now)
            surface(step == 0 ? .began : .changed, sample)
            await InteractionProbe.nextFrame()
            if step == rises.count - 1 {
                surface(.ended, sample)
            }
        }
        let archive = env.haptics.records.filter { $0.interaction == .cardArchiveArm || $0.interaction == .cardThrow }
        #expect(archive.map(\.interaction) == [.cardArchiveArm, .cardThrow])
        let events = archive.compactMap(\.event)
        #expect(events.isEmpty)
        #expect(sink.played.isEmpty)
        window.isHidden = true
    }

    // The throw records at its release, so the deck watch only returns once the card flies off after it.
    @Test(.timeLimit(.minutes(1)), .timingSensitive) func throwDriverWatchesTheDeckFromItsRelease() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let sink = RecordingHapticSink(start: .now)
        let controller = BehindController(env: makeEnvironment(hapticSink: sink))
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        env.open(page("first"))
        env.open(page("second"))
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil { env.debugWatches[.deck] != nil && env.debugSurfaces[.deck] != nil }
        let before = env.haptics.records.count
        await DeckDrivers.table[.cardThrow]!(env)
        #expect(env.haptics.records.map(\.interaction).contains(.cardThrow))
        try await waitUntil { env.browser.tabs.count == 1 }
        // A swipe up closes a tab without a tap: the whole throw records no haptic event.
        let events = env.haptics.records[before...].compactMap(\.event)
        #expect(events.isEmpty)
        #expect(sink.played.isEmpty)
        window.isHidden = true
    }

    // A rapid close: a second throw 100 ms after the first release is taken while the first card still flies
    // off. Both cards are archived, the first before the second, and neither leaves the drawn deck while on screen.
    @Test(.timeLimit(.minutes(1)), .timingSensitive) func twoThrowsAHundredMillisecondsApartBothFlyOffAndArchiveInOrder() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment())
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for name in ["a", "b", "c", "d"] {
            env.open(page(name))
        }
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil {
            env.debugWatches[.deck] != nil && env.debugSurfaces[.deck] != nil && env.debugDeckDrawn != nil
        }
        let ids = env.browser.tabs.map(\.id)
        let drawn = try #require(env.debugDeckDrawn)
        let layout = DeckDrivers.layout()
        let offScreen = -(layout.slotCenter.y + layout.cardSize.height / 2)
        let thrown = [ids[2], ids[3]]
        let sampling = Task {
            var lastLift: [UUID: CGFloat] = [:]
            var dropped: [UUID] = []
            while !Task.isCancelled {
                await InteractionProbe.nextFrame()
                let (cards, lifts) = drawn()
                for card in thrown {
                    if cards.contains(card) {
                        lastLift[card] = lifts[card] ?? 0
                    } else if let last = lastLift.removeValue(forKey: card), last > offScreen {
                        dropped.append(card)
                    }
                }
            }
            return dropped
        }

        let start = ContinuousClock.now
        await DeckDrivers.table[.cardThrow]!(env)
        #expect(env.browser.tabs.count == 4)
        try await Task.sleep(until: start + .milliseconds(250))
        await DeckDrivers.table[.cardThrow]!(env)
        #expect(env.browser.tabs.map(\.id) == [ids[0], ids[1], ids[3]])
        try await waitUntil { env.browser.tabs.count == 2 }
        try await Task.sleep(for: .milliseconds(500))
        sampling.cancel()
        #expect(await sampling.value.isEmpty)
        #expect(env.browser.tabs.map(\.id) == [ids[0], ids[1]])
        window.isHidden = true
    }

    // The second throw's grab lands inside the first one's gap close: it is taken, and the first card is archived
    // at that grab, before the second.
    @Test(.timeLimit(.minutes(1)), .timingSensitive) func aThrowDuringTheGapCloseIsTakenAndArchivesThePendingCardFirst() async throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let controller = BehindController(env: makeEnvironment())
        let env = controller.env
        window.rootViewController = controller
        window.makeKeyAndVisible()
        for name in ["first", "second", "third"] {
            env.open(page(name))
        }
        env.ui.close(animated: false, deckTo: 1)
        controller.view.layoutIfNeeded()
        try await waitUntil { env.debugWatches[.deck] != nil && env.debugSurfaces[.deck] != nil }
        // The deck opens on "second" (left of the active "third"); the first throw takes it, and the gap close
        // brings "third" under the finger. The second grab lands once the close is nearly through but before it
        // settles and archives, so it must take "third", never "first". A grab in the close's first frames finds
        // "third" still to the right and takes the card drawn under the finger instead.
        let ids = env.browser.tabs.map(\.id)
        await DeckDrivers.table[.cardThrow]!(env)
        try await Task.sleep(for: .milliseconds(250))
        #expect(env.browser.tabs.count == 3)
        await DeckDrivers.table[.cardThrow]!(env)
        #expect(env.browser.tabs.map(\.id) == [ids[0], ids[2]])
        try await waitUntil { env.browser.tabs.count == 1 }
        #expect(env.browser.tabs.map(\.id) == [ids[0]])
        #expect(env.haptics.records.filter { $0.interaction == .cardThrow }.count == 2)
        window.isHidden = true
    }
}
#endif
