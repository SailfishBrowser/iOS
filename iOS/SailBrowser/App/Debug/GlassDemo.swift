#if DEBUG
import Foundation
import os

// -SailDemo glass: the chrome's motions over two textured pages, one bright and one dark, each inside its own
// DebugProfiler.measure so the console carries one PROFILE line per motion under a "phase" signpost. On
// the phone the gate is Instruments' Animation Hitches over those phases and fps on every line; on the simulator it is
// the frame spans of the same demo on main.
@MainActor enum GlassDemo {
    struct Motion {
        let name: String
        // The measure's window: the motion's whole run, finger and springs.
        let window: Duration
        let play: @MainActor (AppEnvironment) async throws -> Void
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "probe")
    private static let rest: Duration = .seconds(1)
    // Between motions, and between the parts of one.
    static let gap: Duration = .milliseconds(600)
    // The bright page, then the dark one in front at the start; each is its own theme colour, so the bar reads light
    // over the first and dark over the second.
    nonisolated static let backgrounds = ["f4f4f4", "1b2333"]
    nonisolated private static let rows = 40
    // A 120 pt pull on the menu, short of its 140 pt dismiss, held before the release.
    private static let menuDragPath = [0, 60, 120, 120].map { CGSize(width: 0, height: $0) }
    private static let menuDragDuration: TimeInterval = 0.5

    // The bar's slide over a scroll hide and show; a bar swipe to the bright neighbour and back; the flick to it; the deck
    // zoom out and the zoom in over the bright page (DrawnBar's opacity fade); the menu's open, pull and dim tap; the
    // search sheet's open and tapped close over the bright page (the light look's hand-off).
    static let motions: [Motion] = [
        Motion(name: "barSlide", window: .seconds(2.4)) { env in
            await PolishDemo.drivers[.barHide]!(env)
            try await Task.sleep(for: gap)
            await PolishDemo.drivers[.barShow]!(env)
        },
        Motion(name: "barSwipe", window: .seconds(2.6)) { env in
            await BarDrivers.swipe(env, by: BarDrivers.swipeTravel)
            try await Task.sleep(for: gap)
            await BarDrivers.swipe(env, by: -BarDrivers.swipeTravel)
        },
        Motion(name: "flick", window: .seconds(1)) { env in
            await PolishDemo.drivers[.tabStackFlick]!(env)
        },
        Motion(name: "zoomOut", window: .milliseconds(800)) { env in
            env.showSwitcher(via: .tabStackTap)
        },
        Motion(name: "zoomIn", window: .milliseconds(800)) { env in
            env.showTab(env.browser.tabs[0].id, via: .deckCardTap)
        },
        Motion(name: "menu", window: .seconds(3)) { env in
            await PolishDemo.drivers[.chevronTap]!(env)
            try await Task.sleep(for: gap)
            await DebugFinger(path: menuDragPath, duration: menuDragDuration, start: .zero)
                .run(into: InteractionProbe.present(env.debugSurfaces[.menuSheet], .menuDragReturn))
            try await Task.sleep(for: gap)
            await PolishDemo.drivers[.menuDimTap]!(env)
        },
        Motion(name: "search", window: .seconds(1.6)) { env in
            await PolishDemo.drivers[.plusTap]!(env)
            try await Task.sleep(for: gap)
            await PolishDemo.drivers[.searchDimTap]!(env)
        },
    ]

    // texturedHTML's rows under a tall band of three colour fields, so the frost has colour to carry and the frame
    // counter has texture to see.
    nonisolated static func page(_ background: String) -> String {
        DebugLaunchOptions.texturedHTML(
            background, rows: rows,
            head: "<meta name='theme-color' content='#\(background)'>"
                + "<style>body::before{content:'';display:block;height:420px;margin:0 -16px;"
                + "background:linear-gradient(#c0392b 33%,#2e86de 33% 66%,#27ae60 66%)}</style>")
    }

    static func play(in env: AppEnvironment) async throws {
        try await Task.sleep(for: rest)
        let profiler = DebugProfiler()
        for motion in motions {
            let measured = Task { try await profiler.measure(motion.name, for: motion.window) }
            try await motion.play(env)
            try await measured.value
            try await Task.sleep(for: gap)
        }
        logger.notice("GLASS DONE")
    }
}
#endif
