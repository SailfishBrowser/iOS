#if DEBUG
import UIKit

// "Next action right after": each pair plays its lead-in steps, then its first step. On the frame after the first
// step's motion visibly ends the second is tried, and again on every frame until the app takes it. Accept is from the
// first try to the second step's record; write is from that record to its first changed frame.
enum FollowUps {
    struct Pair {
        let leadIn: [Interaction]
        let first: Interaction
        let then: Interaction
    }

    // A motion has visibly ended once its step per frame falls to this fraction of its fastest step.
    private static let visibleEndFraction: CGFloat = 0.02
    private static let giveUp: Duration = .seconds(2)
    // A drag tried right after a motion is a short quick nudge, so a refused try costs a few frames.
    private static let nudgeDistance: CGFloat = 40
    private static let nudgeSpeed: CGFloat = 600

    static let pairs: [Pair] = [
        Pair(leadIn: [.plusTap], first: .searchDimTap, then: .tabStackTap),
        Pair(leadIn: [], first: .deckScroll, then: .deckCardTap),
        Pair(leadIn: [.chevronTap], first: .menuDimTap, then: .chevronTap),
        Pair(leadIn: [.menuDimTap, .plusTap], first: .searchSubmit, then: .plusTap),
        Pair(leadIn: [.searchDimTap, .tabStackTap], first: .cardThrow, then: .deckScroll),
    ]

    static func play(in env: AppEnvironment) async throws {
        try await Task.sleep(for: PolishDemo.stepGap)
        for pair in pairs {
            for step in pair.leadIn {
                await PolishDemo.drivers[step]!(env)
                try await Task.sleep(for: PolishDemo.stepGap)
            }
            await PolishDemo.drivers[pair.first]!(env)
            let firstAt = env.haptics.records.last { $0.interaction == pair.first }!.at
            let end = await visibleEnd(of: pair.first, in: env)
            await InteractionProbe.nextFrame()
            let (attempts, accept, write) = await follow(pair.then, in: env)
            let line =
                "\(pair.first.rawValue)->\(pair.then.rawValue) end=\(ms(end - firstAt)) attempts=\(attempts) "
                + "accept=\(ms(accept)) write=\(ms(write))"
            PolishDemo.logger.notice("FOLLOWUP \(line, privacy: .public)")
            try await Task.sleep(for: PolishDemo.stepGap)
        }
        PolishDemo.logger.notice("FOLLOWUPS DONE")
    }

    private static func visibleEnd(
        of interaction: Interaction, in env: AppEnvironment
    ) async -> ContinuousClock.Instant {
        switch interaction {
        case .menuDimTap:
            return await InteractionProbe.visibleEnd(of: watch(.menuSheet, env), fraction: visibleEndFraction)
        case .searchDimTap, .searchSubmit:
            return await InteractionProbe.visibleEnd(of: watch(.searchSheet, env), fraction: visibleEndFraction)
        case .deckScroll, .cardThrow:
            return await InteractionProbe.visibleEnd(of: watch(.deck, env), fraction: visibleEndFraction)
        default:
            preconditionFailure("No visible end for \(interaction.rawValue)")
        }
    }

    private static func follow(_ interaction: Interaction, in env: AppEnvironment) async -> (
        attempts: Int, accept: Duration, write: Duration
    ) {
        let start = ContinuousClock.now
        var attempts = 0
        while ContinuousClock.now - start < giveUp {
            attempts += 1
            let recorded = env.haptics.records.count
            if let write = await attempt(interaction, in: env) {
                let record = env.haptics.records[recorded...].first { $0.interaction == interaction }!
                return (attempts, record.at - start, write)
            }
            await InteractionProbe.nextFrame()
        }
        PolishDemo.logger.fault(
            "FOLLOWUP REFUSED \(interaction.rawValue, privacy: .public) attempts=\(attempts, privacy: .public)")
        fatalError("FOLLOWUP REFUSED \(interaction.rawValue)")
    }

    // One try; nil when the app records nothing for it.
    private static func attempt(_ interaction: Interaction, in env: AppEnvironment) async -> Duration? {
        switch interaction {
        case .tabStackTap:
            return await tap(interaction, finger: .tabStack, watching: watch(.deck, env), in: env)
        case .chevronTap:
            return await tap(interaction, finger: .chevron, watching: { env.ui.overlay == .menu ? 1 : 0 }, in: env)
        case .deckCardTap:
            return await tap(
                interaction, finger: .deck, at: DeckDrivers.layout().slotCenter, watching: watch(.deck, env), in: env)
        case .plusTap:
            let sheetTop = watch(.searchSheet, env)
            let baseline = sheetTop()
            let recorded = env.haptics.records.count
            InteractionProbe.present(env.debugActions[.plusTap], .plusTap)()
            guard env.haptics.records[recorded...].contains(where: { $0.interaction == .plusTap }) else { return nil }
            return await InteractionProbe.watch(.plusTap, in: env, from: baseline, presented: sheetTop)
        case .deckScroll:
            let finger = DebugFinger(
                path: [.zero, CGSize(width: -nudgeDistance, height: 0)], duration: nudgeDistance / nudgeSpeed,
                start: DeckDrivers.layout().slotCenter)
            return await InteractionProbe.attemptDrag(
                finger, into: InteractionProbe.present(env.debugSurfaces[.deck], interaction), watching: interaction,
                in: env, presented: watch(.deck, env))
        default:
            preconditionFailure("No try for \(interaction.rawValue)")
        }
    }

    private static func tap(
        _ interaction: Interaction, finger surface: DebugSurface, at start: CGPoint = .zero,
        watching presented: @escaping () -> CGFloat, in env: AppEnvironment
    ) async -> Duration? {
        let baseline = presented()
        let recorded = env.haptics.records.count
        await DebugFinger(path: BarDrivers.tapPath, duration: BarDrivers.tapDuration, start: start)
            .run(into: InteractionProbe.present(env.debugSurfaces[surface], interaction))
        guard env.haptics.records[recorded...].contains(where: { $0.interaction == interaction }) else { return nil }
        return await InteractionProbe.watch(interaction, in: env, from: baseline, presented: presented)
    }

    private static func watch(_ surface: DebugSurface, _ env: AppEnvironment) -> () -> CGFloat {
        env.debugWatches[surface]!
    }

    private static func ms(_ duration: Duration) -> String {
        InteractionProbe.milliseconds(duration / .seconds(1))
    }
}
#endif
