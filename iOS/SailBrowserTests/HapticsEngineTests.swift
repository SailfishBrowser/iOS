import CoreHaptics
import Testing
import UIKit
@testable import SailBrowser

@MainActor
struct HapticsEngineTests {
    private let sink = RecordingHapticSink(start: .now)

    @Test func throttleUsesTheSinksClockPerGenerator() {
        let engine = HapticsEngine(sink: sink)
        engine.fire(.zoomStep)
        engine.fire(.zoomStep)
        #expect(engine.records.map(\.played) == [true, false])
        sink.advance(by: Theme.Latency.frame)
        engine.fire(.zoomStep)
        engine.fire(.menuNav)
        #expect(engine.records.map(\.played) == [true, false, true, true])
        #expect(sink.played == [Theme.Haptic.selection, Theme.Haptic.selection, Theme.Haptic.medium])
    }

    @Test func aSilentInteractionRecordsWithoutPlaying() {
        let engine = HapticsEngine(sink: sink)
        engine.fire(.deckBackgroundTap)
        #expect(engine.records == [HapticRecord(interaction: .deckBackgroundTap, event: nil, played: false, at: sink.now)])
        #expect(sink.played.isEmpty)
    }

    @Test func recordsCarryTheEventAndTheSinksInstant() {
        let engine = HapticsEngine(sink: sink)
        sink.advance(by: .milliseconds(40))
        engine.fire(.suggestionTap)
        #expect(engine.records == [HapticRecord(interaction: .suggestionTap, event: .tabOpened, played: true, at: sink.now)])
        #expect(sink.played == [Theme.Haptic.medium])
    }

    // The trigger's own turn plays the haptic: the test cannot await between the fire and the check.
    @Test func aPreparedHapticPlaysInTheFiringTurn() {
        let engine = HapticsEngine(sink: sink)
        engine.prepare(.zoomStep, .chevronLongPress)
        engine.fire(.chevronLongPress)
        #expect(sink.calls == [.prepare(Theme.Haptic.selection), .prepare(Theme.Haptic.rigid), .play(Theme.Haptic.rigid)])
    }

    @Test func aGeneratorIsPreparedAgainOnlyOnceItGoesColdOrPlays() {
        let engine = HapticsEngine(sink: sink)
        engine.prepare(.menuNav)
        engine.prepare(.chevronTap)
        sink.advance(by: Theme.Haptic.preparedFor - .milliseconds(1))
        engine.prepare(.menuNav)
        #expect(sink.calls == [.prepare(Theme.Haptic.medium)])
        sink.advance(by: .milliseconds(1))
        engine.prepare(.menuNav)
        engine.fire(.menuNav)
        engine.prepare(.menuNav)
        #expect(
            sink.calls == [
                .prepare(Theme.Haptic.medium), .prepare(Theme.Haptic.medium), .play(Theme.Haptic.medium),
                .prepare(Theme.Haptic.medium),
            ])
    }

    @Test func aSilentFireRecordsWithoutPlaying() {
        let engine = HapticsEngine(sink: sink)
        engine.fire(.menuNav, playing: false)
        #expect(engine.records == [HapticRecord(interaction: .menuNav, event: .buttonTap, played: false, at: sink.now)])
        #expect(sink.calls.isEmpty)
    }

    // Every Core Haptics pattern plays on one engine, so preparing any of them warms them all and one play cools it.
    @Test func everyPatternSharesTheCoreHapticsEngine() {
        let engine = HapticsEngine(sink: sink)
        engine.prepare(.menuNav, .chevronLongPress, .pullArm, .zoomStep)
        engine.fire(.pullArm)
        engine.fire(.chevronLongPress)
        let h = Theme.Haptic.self
        #expect(sink.calls == [.prepare(h.medium), .prepare(h.selection), .play(h.refreshArm)])
        sink.advance(by: Theme.Latency.frame)
        engine.fire(.chevronLongPress)
        #expect(sink.played == [h.refreshArm, h.rigid])
    }

    @Test func aPullTickPlaysTheStepItReached() {
        let engine = HapticsEngine(sink: sink)
        for step in Theme.Haptic.refreshTicks.indices {
            engine.fire(.pullTick, step: step)
            sink.advance(by: Theme.Latency.frame)
        }
        #expect(sink.played == Theme.Haptic.refreshTicks)
        #expect(engine.records.map(\.event) == [HapticEvent?](repeating: .refreshNearing, count: Theme.Haptic.refreshTicks.count))
    }

    // A touch prepares every generator at once; each tick inside the window prepares them again, and the first tick
    // past it stops the cadence. A later touch starts it again.
    @Test func aTouchKeepsEveryGeneratorWarmUntilTheWindowAfterIt() {
        let engine = HapticsEngine(sink: sink)
        let h = Theme.Haptic.self
        let warm: [RecordingHapticSink.Call] = [.prepare(h.medium), .prepare(h.selection), .prepare(h.success)]
        #expect(!engine.isKeepingWarm)
        engine.touched()
        engine.touched()
        #expect(sink.calls == warm)
        #expect(engine.isKeepingWarm)
        sink.advance(by: h.keepWarmAfterTouch - .seconds(1))
        engine.runKeepWarmTick()
        #expect(sink.calls == warm + warm)
        sink.advance(by: .seconds(1))
        engine.runKeepWarmTick()
        #expect(sink.calls == warm + warm)
        #expect(!engine.isKeepingWarm)
        sink.advance(by: .seconds(h.keepWarmEvery))
        engine.runKeepWarmTick()
        #expect(sink.calls == warm + warm)
        engine.touched()
        #expect(sink.calls == warm + warm + warm)
        #expect(engine.isKeepingWarm)
    }

    // Under reduced energy a touch prepares each generator once, through the gated prepare, and no cadence starts; the
    // gate ending lets the next touch start it, and the gate returning ends it at the next tick.
    @Test func reducedEnergyPreparesOnceAndKeepsNothingWarm() {
        let engine = HapticsEngine(sink: sink)
        let h = Theme.Haptic.self
        let warm: [RecordingHapticSink.Call] = [.prepare(h.medium), .prepare(h.selection), .prepare(h.success)]
        var keepsWarm = false
        engine.keepsWarm = { keepsWarm }
        engine.touched()
        engine.touched()
        #expect(sink.calls == warm)
        #expect(!engine.isKeepingWarm)
        keepsWarm = true
        engine.touched()
        #expect(engine.isKeepingWarm)
        keepsWarm = false
        engine.runKeepWarmTick()
        #expect(!engine.isKeepingWarm)
    }

    // The observer reports the touch-down and can never cancel, delay or prevent another gesture. (Its fail at
    // touch-down only takes inside UIKit's own touch delivery, so a direct call cannot observe it.)
    @Test func theTouchObserverReportsATouchDownAndStepsAside() {
        var touches = 0
        let observer = TouchDownObserver { touches += 1 }
        observer.touchesBegan([], with: UIEvent())
        #expect(touches == 1)
        #expect(!observer.cancelsTouchesInView)
        #expect(!observer.delaysTouchesBegan)
        #expect(!observer.delaysTouchesEnded)
        #expect(!observer.canPrevent(UIPanGestureRecognizer()))
    }

    // A texture's levels reach the sink as they come; its stop reaches the sink once, and only after a level.
    @Test func aTextureStopsOnlyAfterItRan() {
        let engine = HapticsEngine(sink: sink)
        let texture = Theme.Haptic.pullTexture
        engine.stop(texture)
        #expect(sink.calls.isEmpty)
        let levels = [HapticTexture.Level(intensity: 0, sharpness: 0), HapticTexture.Level(intensity: 0.5, sharpness: 0.2)]
        levels.forEach { engine.drive(texture, $0) }
        engine.stop(texture)
        engine.stop(texture)
        #expect(sink.calls == [.drive(texture, levels[0]), .drive(texture, levels[1]), .stop(texture)])
        #expect(sink.levels == levels)
    }

    // The simulator has no haptics hardware: the sink builds no Core Haptics engine, and every play, level and stop
    // is silent.
    @Test func aLiveSinkWithoutHapticsHardwareStaysSilent() {
        let live = LiveHapticSink(supportsHaptics: false)
        live.attach(to: UIView())
        #expect(!live.playsCoreHaptics)
        let engine = HapticsEngine(sink: live)
        engine.touched()
        for interaction in Interaction.allCases {
            engine.fire(interaction)
        }
        engine.drive(Theme.Haptic.pullTexture, HapticTexture.Level(intensity: 1, sharpness: 1))
        engine.stop(Theme.Haptic.pullTexture)
        #expect(engine.records.count == Interaction.allCases.count)
    }

    // Suspension waits for the app to become active; any other stop restarts the engine at once, without a play.
    @Test(arguments: [
        (CHHapticEngine.StoppedReason.applicationSuspended, false), (.audioSessionInterrupt, true), (.idleTimeout, true),
        (.notifyWhenFinished, true), (.engineDestroyed, true), (.gameControllerDisconnect, true), (.systemError, true),
    ])
    func aStoppedEngineRestartsAtOnceUnlessSuspended(_ reason: CHHapticEngine.StoppedReason, _ restarts: Bool) {
        #expect(LiveHapticSink.restartsAtOnce(after: reason) == restarts)
    }

    @Test func aLiveSinkBeforeAttachPlaysNothingButStillRecords() {
        let engine = HapticsEngine(sink: LiveHapticSink())
        engine.prepare(.tabStackTap, .cardThrow)
        for interaction in Interaction.allCases {
            engine.fire(interaction)
        }
        engine.drive(Theme.Haptic.pullTexture, HapticTexture.Level(intensity: 1, sharpness: 1))
        engine.stop(Theme.Haptic.pullTexture)
        #expect(engine.records.count == Interaction.allCases.count)
    }
}
