#if DEBUG
import Foundation

enum MenuDrivers {
    private static let dismissDistance: CGFloat = 140
    private static let dismissPerFrame: CGFloat = 30
    // Eases to 60 pt, then rests before letting go, so the release is slow.
    private static let returnPath: [CGFloat] = [0, 33, 51, 60, 60, 60]
    private static let returnDuration: TimeInterval = 0.9
    // The chevron, then a grab 30 ms into the open that drags on past the detent, so the menu closes from the grab.
    private static let grabDelay: Duration = .milliseconds(30)
    private static let grabPath = (1...4).map { CGSize(width: 0, height: 30 * CGFloat($0)) }
    private static let grabDuration: TimeInterval = 4 / Theme.Latency.frameRate

    static let table: [Interaction: DebugDriver] = [
        .menuDragDismiss: { env in
            await drag(
                [0, dismissDistance], over: dismissDistance / dismissPerFrame * (Theme.Latency.frame / .seconds(1)),
                as: .menuDragDismiss, in: env)
        },
        .menuDragReturn: { env in await drag(returnPath, over: returnDuration, as: .menuDragReturn, in: env) },
        .menuGrabDuringOpen: { env in
            await BarDrivers.table[.chevronTap]!(env)
            try? await Task.sleep(for: grabDelay)
            let top = InteractionProbe.present(env.debugWatches[.menuSheet], .menuGrabDuringOpen)
            let before = top()
            _ = await InteractionProbe.drag(
                DebugFinger(path: grabPath, duration: grabDuration, start: .zero),
                into: InteractionProbe.present(env.debugSurfaces[.menuSheet], .menuGrabDuringOpen),
                watching: .menuGrabDuringOpen, in: env, presented: { top() > before ? 1 : 0 })
        },
        .menuDimTap: tap(.menuDimTap),
        .menuNav: tap(.menuNav),
        .menuCopyLink: tap(.menuCopyLink),
        .pin: tap(.pin),
        .unpin: tap(.unpin),
        .zoomStep: tap(.zoomStep),
        .archiveRestore: tap(.archiveRestore),
        .sheetDone: tap(.sheetDone),
    ]

    private static func tap(_ interaction: Interaction) -> DebugDriver {
        { env in InteractionProbe.present(env.debugActions[interaction], interaction)() }
    }

    // The menu sheet reads only the vertical translation, so the finger starts at the origin.
    private static func drag(
        _ heights: [CGFloat], over duration: TimeInterval, as interaction: Interaction, in env: AppEnvironment
    ) async {
        let path = heights.map { CGSize(width: 0, height: $0) }
        await DebugFinger(path: path, duration: duration, start: .zero)
            .run(into: InteractionProbe.present(env.debugSurfaces[.menuSheet], interaction))
    }
}
#endif
