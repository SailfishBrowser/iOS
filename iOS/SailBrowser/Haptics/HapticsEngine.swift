import CoreHaptics
import os
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

nonisolated enum HapticEvent: CaseIterable, Sendable {
    case switcherOpened, tabSwitched, cardSettled, searchOpened, menuOpened, buttonTap,
         tabOpened, refreshArmed, pinToggled, longPress, linkCopied, zoomStepped, dataCleared, tabPaged,
         recentArmed, refreshNearing, refreshLanded
}

// One Core Haptics event. Intensity is strength; sharpness runs from round (0) to crisp (1). A pulse with no fade is
// a transient; one with a fade is continuous, and its intensity falls to nothing over the fade so it never buzzes.
nonisolated struct HapticPulse: Hashable, Sendable {
    let at: TimeInterval
    let intensity: Float
    let sharpness: Float
    let fade: TimeInterval

    static func tap(_ intensity: Float, _ sharpness: Float, at: TimeInterval = 0) -> HapticPulse {
        HapticPulse(at: at, intensity: intensity, sharpness: sharpness, fade: 0)
    }

    static func fade(_ intensity: Float, _ sharpness: Float, over fade: TimeInterval, at: TimeInterval = 0) -> HapticPulse {
        HapticPulse(at: at, intensity: intensity, sharpness: sharpness, fade: fade)
    }
}

nonisolated struct HapticPattern: Hashable, Sendable {
    let pulses: [HapticPulse]

    init(_ pulses: HapticPulse...) {
        self.pulses = pulses
    }

    func coreHaptics(strength: Float) throws -> CHHapticPattern {
        let events = pulses.map { pulse in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity * strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
            ]
            return pulse.fade == 0
                ? CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: pulse.at)
                : CHHapticEvent(
                    eventType: .hapticContinuous, parameters: parameters, relativeTime: pulse.at, duration: pulse.fade)
        }
        let fades = pulses.filter { $0.fade > 0 }.map { pulse in
            CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                    CHHapticParameterCurve.ControlPoint(relativeTime: pulse.fade, value: 0),
                ],
                relativeTime: pulse.at)
        }
        return try CHHapticPattern(events: events, parameterCurves: fades)
    }
}

// A continuous event a gesture drives frame by frame: the sink starts it at the first level, moves its intensity and
// sharpness with every level through dynamic parameters, and stops it at the gesture's end. A level is a share of the
// texture's intensity and of its sharpness range, 0 to 1 each; the strength knob scales the intensity as it does every
// pattern's.
nonisolated struct HapticTexture: Hashable, Sendable {
    struct Level: Equatable, Sendable {
        let intensity: Float
        let sharpness: Float
    }

    // Core Haptics' longest continuous event.
    static let longest: TimeInterval = 30

    let intensity: Float
    let sharpness: ClosedRange<Float>

    func coreHaptics(strength: Float) throws -> CHHapticPattern {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness.lowerBound),
            ],
            relativeTime: 0, duration: Self.longest)
        return try CHHapticPattern(events: [event], parameters: [])
    }

    // The intensity control multiplies the event's intensity; the sharpness control adds to its sharpness.
    func parameters(at level: Level) -> [CHHapticDynamicParameter] {
        [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level.intensity, relativeTime: 0),
            CHHapticDynamicParameter(
                parameterID: .hapticSharpnessControl,
                value: level.sharpness * (sharpness.upperBound - sharpness.lowerBound), relativeTime: 0),
        ]
    }
}

nonisolated enum HapticFeedback: Hashable, Sendable {
    // Every pattern plays on the one Core Haptics engine, so the engine is one generator.
    enum Generator: Hashable, Sendable {
        case core, selection, notification
    }

    case pattern(HapticPattern)
    case selection
    case notification(UINotificationFeedbackGenerator.FeedbackType)

    var generator: Generator {
        switch self {
        case .pattern: .core
        case .selection: .selection
        case .notification: .notification
        }
    }
}

nonisolated struct HapticRecord: Equatable, Sendable {
    let interaction: Interaction
    let event: HapticEvent?
    let played: Bool
    let at: ContinuousClock.Instant
}

@MainActor protocol HapticSink: AnyObject {
    var now: ContinuousClock.Instant { get }
    func prepare(_ feedback: HapticFeedback)
    func play(_ feedback: HapticFeedback)
    func drive(_ texture: HapticTexture, _ level: HapticTexture.Level)
    func stop(_ texture: HapticTexture)
}

// Before attach there are no generators or engine, so plays do nothing. Without haptics
// hardware (the simulator) there is no Core Haptics engine and patterns stay silent.
@MainActor final class LiveHapticSink: HapticSink {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "haptics")
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier!, category: "haptics")

    private let supportsHaptics: Bool
    private var engine: CHHapticEngine?
    private var players: [HapticPattern: any CHHapticPatternPlayer] = [:]
    private var textures: [HapticTexture: any CHHapticAdvancedPatternPlayer] = [:]
    private var driving: Set<HapticTexture> = []
    private var isRunning = false
    private var isStarting = false
    private var selection: UISelectionFeedbackGenerator?
    private var notification: UINotificationFeedbackGenerator?
    private var activation: (any NSObjectProtocol)?

    init(supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics) {
        self.supportsHaptics = supportsHaptics
    }

    var now: ContinuousClock.Instant { .now }

    #if DEBUG
    var playsCoreHaptics: Bool {
        engine != nil
    }
    #endif

    func attach(to view: UIView) {
        selection = UISelectionFeedbackGenerator(view: view)
        notification = UINotificationFeedbackGenerator(view: view)
        if supportsHaptics, engine == nil {
            makeEngine()
        }
    }

    // The system stops the engine on suspension; it starts again as the app becomes active, before the first touch.
    private func observeActivation() {
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    // A suspended app restarts on activation; any other stop restarts at once, so no play finds the engine stopped.
    nonisolated static func restartsAtOnce(after reason: CHHapticEngine.StoppedReason) -> Bool {
        reason != .applicationSuspended
    }

    func prepare(_ feedback: HapticFeedback) {
        switch feedback {
        case .pattern: start()
        case .selection: selection?.prepare()
        case .notification: notification?.prepare()
        }
    }

    func play(_ feedback: HapticFeedback) {
        switch feedback {
        case .pattern(let pattern): play(pattern)
        case .selection: selection?.selectionChanged()
        case .notification(let type): notification?.notificationOccurred(type)
        }
    }

    // The first level starts the texture's player; every level moves its controls at once.
    func drive(_ texture: HapticTexture, _ level: HapticTexture.Level) {
        guard let engine, let player = textures[texture] else { return }
        do {
            try startInline(engine)
            if driving.insert(texture).inserted {
                try player.start(atTime: CHHapticTimeImmediate)
            }
            try player.sendParameters(texture.parameters(at: level), atTime: CHHapticTimeImmediate)
        } catch {
            Self.logger.error("Haptic texture failed: \(error, privacy: .public)")
        }
    }

    func stop(_ texture: HapticTexture) {
        guard driving.remove(texture) != nil, let player = textures[texture] else { return }
        do {
            try player.stop(atTime: CHHapticTimeImmediate)
        } catch {
            Self.logger.error("Haptic texture stop failed: \(error, privacy: .public)")
        }
    }

    // Lowest start latency: haptics only, every player built ahead, and the engine kept running by the touch cadence.
    private func makeEngine() {
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            Self.observe(engine, for: self)
            self.engine = engine
            makePlayers(on: engine)
            observeActivation()
            start()
        } catch {
            Self.logger.error("Haptic engine unavailable: \(error, privacy: .public)")
        }
    }

    private func makePlayers(on engine: CHHapticEngine) {
        players = [:]
        textures = [:]
        driving = []
        for case .pattern(let pattern) in Theme.Haptic.all {
            do {
                players[pattern] = try engine.makePlayer(with: pattern.coreHaptics(strength: Theme.Haptic.strength))
            } catch {
                Self.logger.error("Haptic player failed: \(error, privacy: .public)")
            }
        }
        for texture in Theme.Haptic.textures {
            do {
                textures[texture] = try engine.makeAdvancedPlayer(
                    with: texture.coreHaptics(strength: Theme.Haptic.strength))
            } catch {
                Self.logger.error("Haptic texture player failed: \(error, privacy: .public)")
            }
        }
    }

    private func start() {
        guard let engine, !isRunning, !isStarting else { return }
        isStarting = true
        Self.start(engine, for: self)
    }

    private func play(_ pattern: HapticPattern) {
        guard let engine, let player = players[pattern] else { return }
        do {
            try startInline(engine)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Self.logger.error("Haptic play failed: \(error, privacy: .public)")
        }
    }

    // The last resort: a play or a level that finds the engine stopped starts it in line, so the haptic still lands,
    // late. The signpost shows on the phone whether this ever runs and what it costs.
    private func startInline(_ engine: CHHapticEngine) throws {
        guard !isRunning else { return }
        let interval = Self.signposter.beginInterval("HapticInlineStart")
        defer { Self.signposter.endInterval("HapticInlineStart", interval) }
        try engine.start()
        isRunning = true
    }

    private func started(_ error: (any Error)?) {
        isStarting = false
        if let error {
            Self.logger.error("Haptic engine start failed: \(error, privacy: .public)")
        } else {
            isRunning = true
        }
    }

    // A stop ends any running texture with the engine; its next level starts it again.
    private func stopped(_ reason: CHHapticEngine.StoppedReason) {
        isRunning = false
        driving = []
        Self.logger.notice("Haptic engine stopped: \(reason.rawValue, privacy: .public)")
        if Self.restartsAtOnce(after: reason) {
            start()
        }
    }

    // After a haptic server reset the players are gone; the engine and its patterns survive.
    private func reset() {
        isRunning = false
        isStarting = false
        makePlayers(on: engine!)
        start()
    }

    // The engine calls these on its own queue, so the closures are made outside the main actor and hop back to it.
    private nonisolated static func observe(_ engine: CHHapticEngine, for sink: LiveHapticSink) {
        engine.stoppedHandler = { [weak sink] reason in
            Task { @MainActor [sink] in sink?.stopped(reason) }
        }
        engine.resetHandler = { [weak sink] in
            Task { @MainActor [sink] in sink?.reset() }
        }
    }

    private nonisolated static func start(_ engine: CHHapticEngine, for sink: LiveHapticSink) {
        engine.start { [weak sink] error in
            Task { @MainActor [sink] in sink?.started(error) }
        }
    }
}

#if DEBUG
@MainActor final class RecordingHapticSink: HapticSink {
    enum Call: Equatable {
        case prepare(HapticFeedback), play(HapticFeedback)
        case drive(HapticTexture, HapticTexture.Level), stop(HapticTexture)
    }

    private(set) var now: ContinuousClock.Instant
    private(set) var calls: [Call] = []

    var played: [HapticFeedback] {
        calls.compactMap { call in
            guard case .play(let feedback) = call else { return nil }
            return feedback
        }
    }

    var levels: [HapticTexture.Level] {
        calls.compactMap { call in
            guard case .drive(_, let level) = call else { return nil }
            return level
        }
    }

    init(start: ContinuousClock.Instant) {
        now = start
    }

    func advance(by duration: Duration) {
        now += duration
    }

    func prepare(_ feedback: HapticFeedback) {
        calls.append(.prepare(feedback))
    }

    func play(_ feedback: HapticFeedback) {
        calls.append(.play(feedback))
    }

    func drive(_ texture: HapticTexture, _ level: HapticTexture.Level) {
        calls.append(.drive(texture, level))
    }

    func stop(_ texture: HapticTexture) {
        calls.append(.stop(texture))
    }
}
#endif

// One play per generator per frame, so a double fire in one frame cannot stack.
nonisolated struct HapticThrottle: Sendable {
    private var lastPlay: [HapticFeedback.Generator: ContinuousClock.Instant] = [:]

    mutating func admits(_ feedback: HapticFeedback, at now: ContinuousClock.Instant) -> Bool {
        let generator = feedback.generator
        if let last = lastPlay[generator], now - last < Theme.Latency.frame {
            return false
        }
        lastPlay[generator] = now
        return true
    }
}

@MainActor final class HapticsEngine {
    private let sink: any HapticSink
    private var throttle = HapticThrottle()
    private var preparedAt: [HapticFeedback.Generator: ContinuousClock.Instant] = [:]
    private var driving: Set<HapticTexture> = []
    private var lastTouch: ContinuousClock.Instant
    private var warmTimer: Timer?
    // False under reduced energy: a touch then prepares once through the gated prepare and no cadence runs.
    var keepsWarm: () -> Bool = { true }
    #if DEBUG
    private(set) var records: [HapticRecord] = []
    #endif

    init(sink: any HapticSink) {
        self.sink = sink
        lastTouch = sink.now
    }

    var now: ContinuousClock.Instant {
        sink.now
    }

    #if DEBUG
    var isKeepingWarm: Bool {
        warmTimer != nil
    }

    func runKeepWarmTick() {
        keepWarmTick()
    }
    #endif

    // Cheap enough for every touch update: a generator is prepared again only once it has played or gone cold.
    func prepare(_ interactions: Interaction...) {
        prepare(interactions)
    }

    private func prepare(_ feedback: HapticFeedback, force: Bool = false) {
        let now = sink.now
        if !force, let last = preparedAt[feedback.generator], now - last < Theme.Haptic.preparedFor {
            return
        }
        preparedAt[feedback.generator] = now
        sink.prepare(feedback)
    }

    // UIKit lets its haptic engine cool down a few seconds after the last use. Any touch in the window prepares
    // every generator, and keeps preparing them on a cadence under that cooldown until the user stops touching.
    func touched() {
        lastTouch = sink.now
        guard keepsWarm() else {
            Theme.Haptic.all.forEach { prepare($0) }
            return
        }
        guard warmTimer == nil else { return }
        rewarm()
        let timer = Timer(timeInterval: Theme.Haptic.keepWarmEvery, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.keepWarmTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        warmTimer = timer
    }

    private func keepWarmTick() {
        if keepsWarm(), sink.now - lastTouch < Theme.Haptic.keepWarmAfterTouch {
            rewarm()
        } else {
            warmTimer?.invalidate()
            warmTimer = nil
        }
    }

    private func rewarm() {
        var warmed: Set<HapticFeedback.Generator> = []
        for feedback in Theme.Haptic.all where warmed.insert(feedback.generator).inserted {
            prepare(feedback, force: true)
        }
    }

    private func prepare(_ interactions: [Interaction]) {
        for interaction in interactions {
            if let event = Theme.Feedback.event(for: interaction) {
                prepare(Theme.Feedback.feedback(for: event))
            }
        }
    }

    // A silent fire records the interaction for the probes without playing. The step picks a pull tick's pattern.
    func fire(_ interaction: Interaction, playing: Bool = true, step: Int = 0) {
        let event = Theme.Feedback.event(for: interaction)
        var played = false
        if let event, playing {
            let feedback = Theme.Feedback.feedback(for: event, step: step)
            played = throttle.admits(feedback, at: sink.now)
            if played {
                sink.play(feedback)
                preparedAt[feedback.generator] = nil
            }
        }
        #if DEBUG
        records.append(HapticRecord(interaction: interaction, event: event, played: played, at: sink.now))
        #endif
    }

    // A texture follows a gesture frame by frame: every level reaches the sink, and the stop at the gesture's end
    // reaches it only for a texture that ran.
    func drive(_ texture: HapticTexture, _ level: HapticTexture.Level) {
        driving.insert(texture)
        sink.drive(texture, level)
    }

    func stop(_ texture: HapticTexture) {
        guard driving.remove(texture) != nil else { return }
        sink.stop(texture)
    }
}

struct HapticInstaller: UIViewRepresentable {
    final class InstallerView: UIView {
        private let sink: LiveHapticSink
        private let touches: TouchDownObserver

        init(sink: LiveHapticSink, haptics: HapticsEngine) {
            self.sink = sink
            touches = TouchDownObserver { haptics.touched() }
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                sink.attach(to: self)
                window.addGestureRecognizer(touches)
            }
        }
    }

    let sink: LiveHapticSink
    let haptics: HapticsEngine

    func makeUIView(context: Context) -> InstallerView {
        InstallerView(sink: sink, haptics: haptics)
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {}
}

// Sees each touch-down in the window, then fails at once, so it never delays, cancels or competes for a touch.
final class TouchDownObserver: UIGestureRecognizer {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
