#if DEBUG
import Foundation

// Translations are the finger's: down pulls the page past its top, up scrolls it down.
enum WebDrivers {
    private static let pullDepth: CGFloat = 170
    // Inside the hysteresis, so the release still refreshes and the ring scale steps from under 1 to 1.
    private static let releaseDepth: CGFloat = 146
    private static let pullDuration: TimeInterval = 0.6
    // Out past the arm and back above the disarm line, so the release leaves the page alone.
    static let pullArmPath: [CGFloat] = [0, pullDepth, 0]
    static let pullArmDuration: TimeInterval = 2 * pullDuration
    static let pullReleasePath: [CGFloat] = [0, pullDepth, releaseDepth]
    static let pullReleaseDuration: TimeInterval = pullDuration
    private static let barHideTravel: CGFloat = 200
    private static let barHideDuration: TimeInterval = 0.4
    private static let barShowTravel: CGFloat = 40
    // Starting at the page top shows the bar whatever its state, then 200 pt down hides it in 0.4 s and 40 pt
    // back up shows it in 0.2 s: three equal 0.2 s legs.
    static let barShowPath: [CGFloat] = [0, -barHideTravel / 2, -barHideTravel, barShowTravel - barHideTravel]
    private static let barShowDuration: TimeInterval = 0.6

    static let table: [Interaction: DebugDriver] = [
        .pullArm: { env in
            _ = await probedScroll(env, pullArmPath, over: pullArmDuration, watching: .pullArm)
        },
        .pullRelease: { env in
            _ = await probedScroll(env, pullReleasePath, over: pullReleaseDuration, watching: .pullRelease)
        },
        .barHide: { env in
            await scroll(env, [0, -barHideTravel], over: barHideDuration, as: .barHide)
        },
        .barShow: { env in
            await scroll(env, barShowPath, over: barShowDuration, as: .barShow)
        },
    ]

    private static func scroll(
        _ env: AppEnvironment, _ heights: [CGFloat], over duration: TimeInterval, as interaction: Interaction
    ) async {
        let path = heights.map { CGSize(width: 0, height: $0) }
        await DebugFinger(path: path, duration: duration, start: .zero)
            .run(into: InteractionProbe.present(env.debugSurfaces[.webScroll], interaction))
    }

    static func probedScroll(
        _ env: AppEnvironment, _ heights: [CGFloat], over duration: TimeInterval, watching: Interaction
    ) async -> Duration {
        await InteractionProbe.drag(
            DebugFinger(path: heights.map { CGSize(width: 0, height: $0) }, duration: duration, start: .zero),
            into: InteractionProbe.present(env.debugSurfaces[.webScroll], watching), watching: watching, in: env,
            presented: InteractionProbe.present(env.debugWatches[.webScroll], watching))
    }
}
#endif
