#if DEBUG
import UIKit

enum DeckDrivers {
    // Two cards left at a steady 600 pt/s, so the settle lands on another card.
    private static let scrollCards: CGFloat = 2
    private static let scrollSpeed: CGFloat = 600
    // Slow lifts ease to a near stop before release. In card heights.
    private static let returnLift: CGFloat = 0.42
    private static let armLift: CGFloat = 0.65
    private static let slowLiftDuration: TimeInterval = 0.6
    private static let slowLift: [CGFloat] = (0...8).map { step in
        let t = CGFloat(step) / 8
        return t * (2 - t)
    }
    // A flick short of the line that commits through its projection.
    private static let throwLift: CGFloat = 0.4
    private static let throwDuration: TimeInterval = 0.15
    private static let tapDuration: TimeInterval = 0.05

    // Each step watches the deck driver's presented state from the sample that records it.
    static let table: [Interaction: DebugDriver] = [
        .deckScroll: { env in
            let layout = layout()
            let distance = scrollCards * layout.stride
            let path = [CGSize.zero, CGSize(width: -distance, height: 0)]
            await drag(env, path, over: distance / scrollSpeed, from: layout.slotCenter, as: .deckScroll)
        },
        .cardReturn: { env in
            await lift(env, by: returnLift, along: slowLift, over: slowLiftDuration, as: .cardReturn)
        },
        .cardArchiveArm: { env in
            await lift(env, by: armLift, along: slowLift, over: slowLiftDuration, as: .cardArchiveArm)
        },
        .cardThrow: { env in await lift(env, by: throwLift, along: [0, 1], over: throwDuration, as: .cardThrow) },
        .deckCardTap: { env in
            await drag(env, [.zero, .zero], over: tapDuration, from: layout().slotCenter, as: .deckCardTap)
        },
        .deckBackgroundTap: { env in
            let layout = layout()
            let aboveCards = CGPoint(
                x: layout.slotCenter.x, y: (layout.slotCenter.y - layout.cardSize.height / 2) / 2)
            await drag(env, [.zero, .zero], over: tapDuration, from: aboveCards, as: .deckBackgroundTap)
        },
    ]

    // A rapid close: the second drag starts `gap` after the first throw's release, while the first card still
    // flies off and its gap close runs.
    static func rapidDoubleThrow(_ env: AppEnvironment, gap: Duration) async throws {
        await table[.cardThrow]!(env)
        let release = env.haptics.records.last { $0.interaction == .cardThrow }!.at
        try await Task.sleep(until: release + gap)
        await table[.cardThrow]!(env)
    }

    static func layout() -> CardLayout {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        return CardLayout(screen: window.bounds.size)
    }

    private static func lift(
        _ env: AppEnvironment, by fraction: CGFloat, along shape: [CGFloat], over duration: TimeInterval,
        as interaction: Interaction
    ) async {
        let layout = layout()
        let height = fraction * layout.cardSize.height
        await drag(
            env, shape.map { CGSize(width: 0, height: -height * $0) }, over: duration, from: layout.slotCenter,
            as: interaction)
    }

    private static func drag(
        _ env: AppEnvironment, _ path: [CGSize], over duration: TimeInterval, from start: CGPoint,
        as interaction: Interaction
    ) async {
        _ = await InteractionProbe.drag(
            DebugFinger(path: path, duration: duration, start: start),
            into: InteractionProbe.present(env.debugSurfaces[.deck], interaction), watching: interaction, in: env,
            presented: InteractionProbe.present(env.debugWatches[.deck], interaction))
    }
}
#endif
