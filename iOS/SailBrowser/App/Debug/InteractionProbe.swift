#if DEBUG
import os
import QuartzCore
import SwiftUI

typealias DebugDriver = @MainActor (AppEnvironment) async -> Void

nonisolated enum DebugSurface: Hashable, Sendable {
    case deck, tabStack, chevron, translate, menuSheet, searchSheet, webScroll, clearButton, bar
}

extension AppEnvironment {
    // A shared key (both "+" pills publish .plusTap) is removed only by the owner that published it last.
    func publishDebugAction(_ interaction: Interaction, owner: UUID, _ action: @escaping @MainActor () -> Void) {
        debugActions[interaction] = action
        debugActionOwners[interaction] = owner
    }

    func withdrawDebugAction(_ interaction: Interaction, owner: UUID) {
        guard debugActionOwners[interaction] == owner else { return }
        debugActions[interaction] = nil
        debugActionOwners[interaction] = nil
    }

    // Surfaces and watches follow the same rule: on a tab switch the outgoing page view may leave after the
    // incoming one has published.
    func publishDebugSurface(
        _ surface: DebugSurface, owner: UUID, _ handler: @escaping (DragPhase, DragSample) -> Void
    ) {
        debugSurfaces[surface] = handler
        debugSurfaceOwners[surface] = owner
    }

    func withdrawDebugSurface(_ surface: DebugSurface, owner: UUID) {
        guard debugSurfaceOwners[surface] == owner else { return }
        debugSurfaces[surface] = nil
        debugSurfaceOwners[surface] = nil
    }

    func publishDebugWatch(_ surface: DebugSurface, owner: UUID, _ watch: @escaping () -> CGFloat) {
        debugWatches[surface] = watch
        debugWatchOwners[surface] = owner
    }

    func withdrawDebugWatch(_ surface: DebugSurface, owner: UUID) {
        guard debugWatchOwners[surface] == owner else { return }
        debugWatches[surface] = nil
        debugWatchOwners[surface] = nil
    }

    // The deck's hooks close over the deck, so the deck withdraws them as it goes.
    func publishDebugDeck(
        owner: UUID, position: @escaping (CGFloat) -> Void,
        drawn: @escaping () -> (cards: Set<UUID>, lifts: [UUID: CGFloat]), throwCard: @escaping () -> Void
    ) {
        debugDeckPosition = position
        debugDeckDrawn = drawn
        debugDeckThrow = throwCard
        debugDeckOwner = owner
    }

    func withdrawDebugDeck(owner: UUID) {
        guard debugDeckOwner == owner else { return }
        debugDeckPosition = nil
        debugDeckDrawn = nil
        debugDeckThrow = nil
        debugDeckOwner = nil
    }
}

extension View {
    func debugAction(_ interaction: Interaction, _ action: @escaping @MainActor () -> Void) -> some View {
        modifier(DebugActionPublisher(interaction: interaction, action: action))
    }

    func debugSurface(_ surface: DebugSurface, _ handler: @escaping (DragPhase, DragSample) -> Void) -> some View {
        modifier(DebugSurfacePublisher(surface: surface, handler: handler))
    }

    func debugWatch(_ surface: DebugSurface, _ watch: @escaping () -> CGFloat) -> some View {
        modifier(DebugWatchPublisher(surface: surface, watch: watch))
    }
}

private struct DebugActionPublisher: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var owner = UUID()
    let interaction: Interaction
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { env.publishDebugAction(interaction, owner: owner, action) }
            .onDisappear { env.withdrawDebugAction(interaction, owner: owner) }
    }
}

private struct DebugSurfacePublisher: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var owner = UUID()
    let surface: DebugSurface
    let handler: (DragPhase, DragSample) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { env.publishDebugSurface(surface, owner: owner, handler) }
            .onDisappear { env.withdrawDebugSurface(surface, owner: owner) }
    }
}

private struct DebugWatchPublisher: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var owner = UUID()
    let surface: DebugSurface
    let watch: () -> CGFloat

    func body(content: Content) -> some View {
        content
            .onAppear { env.publishDebugWatch(surface, owner: owner, watch) }
            .onDisappear { env.withdrawDebugWatch(surface, owner: owner) }
    }
}

// Replays a finger along `path`, keyframes of translation evenly spaced over `duration`, one sample per frame.
@MainActor final class DebugFinger {
    private let path: [CGSize]
    private let duration: TimeInterval
    private let start: CGPoint

    init(path: [CGSize], duration: TimeInterval, start: CGPoint) {
        self.path = path
        self.duration = duration
        self.start = start
    }

    func run(into surface: (DragPhase, DragSample) -> Void) async {
        let frames = DisplayFrames()
        let origin = await frames.next()
        let originTime = Date()
        var last = sample(at: originTime, translation: path[0], velocity: .zero)
        var lastTimestamp = origin
        surface(.began, last)
        // The last frame is clamped to the path's end. The loop compares against `end` itself, because
        // origin + duration - origin can round below duration and would repeat the clamped frame forever.
        // A clamped final step can be as short as a rounding error, so once a real step exists the release keeps
        // that step's velocity.
        let end = origin + duration
        repeat {
            let frame = await frames.next()
            let timestamp = min(frame, end)
            let translation = translation(at: timestamp == end ? 1 : (timestamp - origin) / duration)
            let elapsed = timestamp - lastTimestamp
            let keepsLastStep = frame > end && lastTimestamp > origin
            let velocity =
                keepsLastStep
                ? last.velocity
                : CGSize(
                    width: (translation.width - last.translation.width) / elapsed,
                    height: (translation.height - last.translation.height) / elapsed)
            last = sample(
                at: Self.time(of: timestamp, origin: origin, originTime: originTime), translation: translation,
                velocity: velocity)
            lastTimestamp = timestamp
            surface(.changed, last)
        } while lastTimestamp < end
        frames.stop()
        surface(.ended, last)
    }

    private func translation(at progress: Double) -> CGSize {
        let position = progress * Double(path.count - 1)
        let index = min(Int(position), path.count - 2)
        let fraction = CGFloat(position - Double(index))
        let from = path[index]
        let to = path[index + 1]
        return CGSize(
            width: from.width + (to.width - from.width) * fraction,
            height: from.height + (to.height - from.height) * fraction)
    }

    // Every sample's time is the display link's timestamp offset from one wall-clock read, so time follows frame order.
    static func time(of timestamp: CFTimeInterval, origin: CFTimeInterval, originTime: Date) -> Date {
        originTime.addingTimeInterval(timestamp - origin)
    }

    private func sample(at time: Date, translation: CGSize, velocity: CGSize) -> DragSample {
        DragSample(
            startLocation: start,
            location: CGPoint(x: start.x + translation.width, y: start.y + translation.height),
            translation: translation, velocity: velocity,
            time: time)
    }
}

@MainActor enum InteractionProbe {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "probe")

    // A step whose control is not on screen at its turn stops the demo by name.
    static func present<Handler>(_ handler: Handler?, _ interaction: Interaction) -> Handler {
        guard let handler else {
            logger.fault("POLISH MISSING \(interaction.rawValue, privacy: .public)")
            fatalError("POLISH MISSING \(interaction.rawValue)")
        }
        return handler
    }

    // Write latency: from the interaction's latest record to the first display-link tick where the watched value
    // differs from `baseline`. The caller reads the baseline synchronously before it acts, because by the time this
    // runs the view may already have applied the change.
    static func watch(
        _ interaction: Interaction, in env: AppEnvironment, from baseline: CGFloat,
        presented: @escaping () -> CGFloat
    ) async -> Duration {
        let record = env.haptics.records.last { $0.interaction == interaction }!
        await change(of: presented, from: baseline)
        let write = ContinuousClock.now - record.at
        logger.notice(
            "INTERACTION \(describe(record), privacy: .public) write=\(milliseconds(write / .seconds(1)), privacy: .public)"
        )
        return write
    }

    // Feeds the finger into `surface` and watches the sample that records `interaction`: the value read just before
    // that sample is the baseline. A drag recorded at its release so measures release to settle, not the first move.
    static func drag(
        _ finger: DebugFinger, into surface: (DragPhase, DragSample) -> Void, watching interaction: Interaction,
        in env: AppEnvironment, presented: @escaping () -> CGFloat
    ) async -> Duration {
        guard let write = await attemptDrag(finger, into: surface, watching: interaction, in: env, presented: presented)
        else { fatalError("POLISH UNRECORDED \(interaction.rawValue)") }
        return write
    }

    // As drag, but a finger the app refuses (nothing recorded) returns nil.
    static func attemptDrag(
        _ finger: DebugFinger, into surface: (DragPhase, DragSample) -> Void, watching interaction: Interaction,
        in env: AppEnvironment, presented: @escaping () -> CGFloat
    ) async -> Duration? {
        let recorded = env.haptics.records.count
        var probe: Task<Duration, Never>?
        await finger.run { phase, sample in
            let baseline = presented()
            surface(phase, sample)
            if probe == nil, env.haptics.records[recorded...].contains(where: { $0.interaction == interaction }) {
                probe = Task { await watch(interaction, in: env, from: baseline, presented: presented) }
            }
        }
        return await probe?.value
    }

    // Waits for the tick where a running motion's step falls to `fraction` of its fastest step: the frame its motion
    // visibly ends. Returns that tick's time.
    static func visibleEnd(of presented: () -> CGFloat, fraction: CGFloat) async -> ContinuousClock.Instant {
        let frames = DisplayFrames()
        var end = VisibleEnd(fraction: fraction)
        var last = presented()
        repeat {
            _ = await frames.next()
            let value = presented()
            end.step(value - last)
            last = value
        } while !end.isReached
        frames.stop()
        return .now
    }

    static func nextFrame() async {
        let frames = DisplayFrames()
        _ = await frames.next()
        frames.stop()
    }

    // Waits for the first display-link tick where `presented` differs from `baseline`.
    static func change(of presented: () -> CGFloat, from baseline: CGFloat) async {
        let frames = DisplayFrames()
        repeat {
            _ = await frames.next()
        } while presented() == baseline
        frames.stop()
    }

    // Every record a step wrote, watched or not, so its haptic and any interaction fired inside it are in the log.
    static func report(_ record: HapticRecord) {
        logger.notice("RECORD \(describe(record), privacy: .public)")
    }

    private static func describe(_ record: HapticRecord) -> String {
        let event = CACurrentMediaTime() - (ContinuousClock.now - record.at) / .seconds(1)
        let haptic = record.event.map { "\($0)" } ?? "none"
        return "\(record.interaction.rawValue) event=\(milliseconds(event)) haptic=\(haptic) played=\(record.played)"
    }

    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}

// A motion has visibly ended once it has moved and its latest step is at most `fraction` of its fastest.
nonisolated struct VisibleEnd: Sendable {
    let fraction: CGFloat
    private var peak: CGFloat = 0
    private(set) var isReached = false

    init(fraction: CGFloat) {
        self.fraction = fraction
    }

    mutating func step(_ delta: CGFloat) {
        peak = max(peak, abs(delta))
        isReached = peak > 0 && abs(delta) <= peak * fraction
    }
}

private final class DisplayFrames: NSObject {
    private var link: CADisplayLink?
    private var waiting: CheckedContinuation<CFTimeInterval, Never>?

    func next() async -> CFTimeInterval {
        await withCheckedContinuation { continuation in
            waiting = continuation
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.preferredFrameRateRange = Theme.Latency.frameRateRange
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: link.targetTimestamp)
    }
}
#endif
