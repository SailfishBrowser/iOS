#if DEBUG
import CoreGraphics
import Foundation

enum BarDrivers {
    static let tapPath = [CGSize.zero, .zero]
    static let tapDuration: TimeInterval = 0.05
    private static let flickPath = [CGSize.zero, CGSize(width: 0, height: -60)]
    private static let flickDuration: TimeInterval = 0.12
    // A swipe on the bar past half a page, locked on its first step and held still before the release, so it lands on
    // the neighbour: right (positive) to the previous tab, left to the next.
    static let swipeTravel: CGFloat = 250
    private static let swipeLockStep: CGFloat = 12
    static let swipeDuration: TimeInterval = 0.5

    static let table: [Interaction: DebugDriver] = [
        .tabStackTap: { env in
            await finger(tapPath, tapDuration, into: InteractionProbe.present(env.debugSurfaces[.tabStack], .tabStackTap))
        },
        .tabStackFlick: { env in
            await finger(flickPath, flickDuration, into: InteractionProbe.present(env.debugSurfaces[.tabStack], .tabStackFlick))
        },
        .chevronTap: { env in
            await finger(tapPath, tapDuration, into: InteractionProbe.present(env.debugSurfaces[.chevron], .chevronTap))
        },
        .barSwipe: { env in await swipe(env, by: swipeTravel) },
        .plusTap: { env in InteractionProbe.present(env.debugActions[.plusTap], .plusTap)() },
        .archiveOpen: { env in InteractionProbe.present(env.debugActions[.archiveOpen], .archiveOpen)() },
        .settingsOpen: { env in InteractionProbe.present(env.debugActions[.settingsOpen], .settingsOpen)() },
    ]

    static func swipePath(by travel: CGFloat) -> [CGSize] {
        let lock = travel < 0 ? -swipeLockStep : swipeLockStep
        return [.zero, CGSize(width: lock, height: 0), CGSize(width: travel, height: 0), CGSize(width: travel, height: 0)]
    }

    static func swipe(_ env: AppEnvironment, by travel: CGFloat) async {
        await finger(swipePath(by: travel), swipeDuration, into: InteractionProbe.present(env.debugSurfaces[.bar], .barSwipe))
    }

    private static func finger(
        _ path: [CGSize], _ duration: TimeInterval, into surface: (DragPhase, DragSample) -> Void
    ) async {
        await DebugFinger(path: path, duration: duration, start: .zero).run(into: surface)
    }
}
#endif
