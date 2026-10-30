#if DEBUG
import Foundation
import os

enum PolishDemo {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "probe")
    static let stepGap: Duration = .milliseconds(1500)
    static let rapidThrowGap: Duration = .milliseconds(120)
    // Both throws and the second gap close.
    private static let rapidThrowMeasure: Duration = .milliseconds(1400)

    static let drivers: [Interaction: DebugDriver] = [
        DeckDrivers.table, BarDrivers.table, SearchDrivers.table, MenuDrivers.table, WebDrivers.table,
    ].reduce(into: [:]) { merged, table in
        merged.merge(table) { _, _ in preconditionFailure("A driver key is in two tables") }
    }

    // The last step repeats until the deck is empty.
    static let script: [Interaction] = [
        .pullArm, .pullRelease, .barHide, .barShow,
        .chevronTap, .zoomStep, .pin, .unpin, .menuNav, .menuCopyLink, .menuDragReturn, .menuDragDismiss,
        .menuGrabDuringOpen, .chevronTap, .menuDimTap,
        .plusTap, .searchClear, .searchDragReturn, .searchDragDismiss, .searchGrabDuringOpen, .plusTap, .searchDimTap,
        .plusTap,
        .suggestionTap,
        .tabStackFlick, .tabStackTap, .deckScroll, .cardReturn, .cardThrow, .cardArchiveArm,
        .archiveOpen, .archiveRestore, .tabStackTap, .settingsOpen, .sheetDone,
        .tabStackTap, .deckBackgroundTap, .tabStackTap, .deckCardTap, .plusTap, .searchSubmit, .tabStackTap,
        .cardThrow,
    ]

    // Fired inside scripted steps; the log shows them under their step.
    static let covered: Set<Interaction> = [
        .deckSettle, .cardLift, .barIntro, .deckEmptied, .pullTick, .refreshLand,
    ]

    // Real launches measure launch and foregroundRaise; the device pass checks the rest by hand.
    static let manual: Set<Interaction> = [
        .launch, .foregroundRaise,
        .searchTyping, .chevronLongPress, .menuFind, .menuShare, .archiveDelete, .settingsChange, .webEdgeSwipe,
        .clearData, .menuAddressEdit, .menuAddressSubmit, .desktopToggle, .displayOptionsToggle, .menuTranslate, .restorePage,
        .barSwipe, .barSwipeTick, .barSwipeSettle,
        .barTranslate,
        .recentArm, .recentRemove, .recentReturn,
        .readerOpen, .readerClose, .readerDragDismiss, .readerDragReturn,
        .permissionAnswer,
        .privateToggle,
        .pinchSwitcher,
        .macTabsOpen, .macTabsPick,
    ]

    static func play(in env: AppEnvironment) async throws {
        try await Task.sleep(for: stepGap)
        for (index, step) in script.enumerated() {
            try await perform(step, number: index + 1, in: env)
        }
        var count = script.count + 1
        try await performRapidDoubleThrow(number: count, in: env)
        while !env.haptics.records.contains(where: { $0.interaction == .deckEmptied }) {
            count += 1
            try await perform(script.last!, number: count, in: env)
        }
        logger.notice("POLISH DONE \(count, privacy: .public)")
    }

    // The step's frames are profiled for late ones while both throws run.
    private static func performRapidDoubleThrow(number: Int, in env: AppEnvironment) async throws {
        logger.notice("POLISH STEP \(number, privacy: .public) rapidDoubleThrow")
        let recorded = env.haptics.records.count
        let profiler = DebugProfiler()
        let measured = Task { try await profiler.measure("rapidDoubleThrow", for: rapidThrowMeasure) }
        try await DeckDrivers.rapidDoubleThrow(env, gap: rapidThrowGap)
        try await measured.value
        try await Task.sleep(for: stepGap)
        env.haptics.records[recorded...].forEach(InteractionProbe.report)
    }

    // Records written in the step's gap belong to it too: the bar intro lands after its delay.
    private static func perform(_ step: Interaction, number: Int, in env: AppEnvironment) async throws {
        logger.notice("POLISH STEP \(number, privacy: .public) \(step.rawValue, privacy: .public)")
        let recorded = env.haptics.records.count
        await drivers[step]!(env)
        try await Task.sleep(for: stepGap)
        env.haptics.records[recorded...].forEach(InteractionProbe.report)
    }
}
#endif
