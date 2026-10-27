#if DEBUG
import Foundation

@MainActor enum SearchDrivers {
    private static let dismissDistance: CGFloat = 140
    private static let dismissPerFrame: CGFloat = 30
    // A return that slows to rest and holds 0.4 s before the release.
    static let slowReturn = path(60, steps: 5, hold: 4) { 1 - pow(1 - $0, 2) }
    static let slowReturnDuration: TimeInterval = 0.9
    // "+" then a grab 30 ms into the open. The finger lands well below where the sheet is drawn, more than the open
    // lifts it in a frame, so the first frame that shows the sheet below its pre-grab top is the grab's own write.
    private static let grabDelay: Duration = .milliseconds(30)
    private static let grabPath = (1...4).map { CGSize(width: 0, height: 150 + 30 * CGFloat($0 - 1)) }
    private static let grabDuration: TimeInterval = 4 / Theme.Latency.frameRate

    static let table: [Interaction: DebugDriver] = [
        .searchDragDismiss: { env in
            await drag(
                path(dismissDistance, steps: 1) { $0 },
                over: dismissDistance / dismissPerFrame / Theme.Latency.frameRate, as: .searchDragDismiss, in: env)
        },
        .searchDragReturn: { env in
            await drag(slowReturn, over: slowReturnDuration, as: .searchDragReturn, in: env)
        },
        .searchSubmit: { env in await tap(.searchSubmit, in: env) },
        .suggestionTap: { env in await tap(.suggestionTap, in: env) },
        // The clear button only shows over text, so the text goes in a turn before the clear and the watch sees the
        // button hide.
        .searchClear: { env in
            let shown = InteractionProbe.present(env.debugWatches[.clearButton], .searchClear)
            let empty = shown()
            InteractionProbe.present(env.debugActions[.searchTyping], .searchClear)()
            await InteractionProbe.change(of: shown, from: empty)
            let baseline = shown()
            InteractionProbe.present(env.debugActions[.searchClear], .searchClear)()
            _ = await InteractionProbe.watch(.searchClear, in: env, from: baseline, presented: shown)
        },
        .searchDimTap: { env in await tap(.searchDimTap, in: env) },
        .searchGrabDuringOpen: { env in
            InteractionProbe.present(env.debugActions[.plusTap], .searchGrabDuringOpen)()
            try? await Task.sleep(for: grabDelay)
            let top = InteractionProbe.present(env.debugWatches[.searchSheet], .searchGrabDuringOpen)
            let before = top()
            _ = await InteractionProbe.drag(
                DebugFinger(path: grabPath, duration: grabDuration, start: .zero),
                into: InteractionProbe.present(env.debugSurfaces[.searchSheet], .searchGrabDuringOpen),
                watching: .searchGrabDuringOpen, in: env, presented: { top() > before ? 1 : 0 })
        },
    ]

    static func path(
        _ distance: CGFloat, steps: Int, hold: Int = 0, easing: (CGFloat) -> CGFloat
    ) -> [CGSize] {
        let moving = (0...steps).map { CGSize(width: 0, height: distance * easing(CGFloat($0) / CGFloat(steps))) }
        return moving + Array(repeating: moving.last!, count: hold)
    }

    // The sheet's handlers read only the translation, so the finger starts anywhere.
    private static func drag(
        _ path: [CGSize], over duration: TimeInterval, as interaction: Interaction, in env: AppEnvironment
    ) async {
        _ = await InteractionProbe.drag(
            DebugFinger(path: path, duration: duration, start: .zero),
            into: InteractionProbe.present(env.debugSurfaces[.searchSheet], interaction), watching: interaction,
            in: env, presented: InteractionProbe.present(env.debugWatches[.searchSheet], interaction))
    }

    private static func tap(_ interaction: Interaction, in env: AppEnvironment) async {
        let sheetTop = InteractionProbe.present(env.debugWatches[.searchSheet], interaction)
        let baseline = sheetTop()
        InteractionProbe.present(env.debugActions[interaction], interaction)()
        _ = await InteractionProbe.watch(interaction, in: env, from: baseline, presented: sheetTop)
    }
}
#endif
