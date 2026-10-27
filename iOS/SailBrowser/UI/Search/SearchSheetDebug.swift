#if DEBUG
import UIKit

extension SearchSheetController {
    private static let debugSettle: Duration = .milliseconds(2500)
    private static let debugGap: Duration = .milliseconds(1500)
    // A dark page, so a submit in a capture adds no white frames.
    private static let seedText =
        "data:text/html,%3Cbody%20style=%22background:%23\(Theme.Palette.demoSubmitPage)%22%3E"
    private static let grabDelay: Duration = .milliseconds(50)
    private static let typedQuery = "google"
    private static let keystrokeGap: Duration = .milliseconds(600)
    private static let answerWait: Duration = .seconds(4)
    private static let debugPoll: Duration = .milliseconds(50)
    private static let fingerSteps = 8
    // A finger on the rows, 74 to 117 pt above the keyboard as a real drag takes the sheet.
    private static let fingerAboveKeyboard: CGFloat = 90
    // A flick that speeds up to its release, then two returns that slow down.
    private static let flickClosed = SearchDrivers.path(240, steps: fingerSteps) { pow($0, 1.5) }
    private static let quickReturn = SearchDrivers.path(50, steps: fingerSteps) { 1 - pow(1 - $0, 2) }
    private static let flickDuration: TimeInterval = 0.2
    private static let quickReturnDuration: TimeInterval = 0.15
    // More recents than the four that show, so a removal brings one in at the bottom.
    private static let recentFixture = [
        ("https://www.swift.org/", "Swift"), ("https://www.wikipedia.org/", "Wikipedia"),
        ("https://www.apple.com/", "Apple"), ("https://news.ycombinator.com/", "Hacker News"),
        ("https://github.com/", "GitHub"), ("https://www.youtube.com/", "YouTube"),
    ]
    // At about 450 pt/s: a full pull to about 380 pt that removes, then a pull to about 181 pt (a 170 pt
    // capsule) that springs home.
    private static let recentRemovePull: CGFloat = 0.86
    private static let recentRemoveDuration: TimeInterval = 0.85
    private static let recentShortPull: CGFloat = 0.41
    private static let recentShortDuration: TimeInterval = 0.4

    // Return only submits text, so the submit types it first. The clear button only shows over text, so its driver
    // types in an earlier turn and watches the button hide.
    func publishDebugControls() {
        env.debugWatches[.searchSheet] = { [unowned self] in container.layer.presentation()!.frame.minY }
        env.debugWatches[.clearButton] = { [unowned self] in field.rightView!.layer.presentation()!.isHidden ? 0 : 1 }
        env.debugActions[.searchTyping] = { [unowned self] in seed() }
        env.debugActions[.searchClear] = { [unowned self] in
            (field.rightView as! UIButton).sendActions(for: .primaryActionTriggered)
        }
        env.debugActions[.searchSubmit] = { [unowned self] in
            seed()
            _ = textFieldShouldReturn(field)
        }
        env.debugActions[.privateToggle] = { [unowned self] in
            field.privateToggle.sendActions(for: .primaryActionTriggered)
        }
    }

    func withdrawDebugControls() {
        env.debugWatches[.searchSheet] = nil
        env.debugWatches[.clearButton] = nil
        env.debugActions[.searchTyping] = nil
        env.debugActions[.searchClear] = nil
        env.debugActions[.searchSubmit] = nil
        env.debugActions[.privateToggle] = nil
    }

    private func seed() {
        field.text = Self.seedText
        field.sendActions(for: .editingChanged)
    }

    func runDebugDemo() {
        let defaults = UserDefaults.standard
        guard let demo = defaults.string(forKey: "SailSearchDemo") else { return }
        Task {
            try await Task.sleep(for: Self.debugSettle)
            switch demo {
            case "text":
                field.text = defaults.string(forKey: "SailSearchText")!
                field.sendActions(for: .editingChanged)
            case "drag":
                try await runDragDemo()
            case "typing":
                try await runTypingDemo()
            case "recentSwipe":
                try await runRecentSwipeDemo()
            case "dismissOver":
                try await runDismissOver(background: defaults.string(forKey: "SailSearchPage")!)
            case let demo:
                fatalError("Unknown SailSearchDemo \(demo)")
            }
        }
    }

    private func runTypingDemo() async throws {
        for length in 1...Self.typedQuery.count {
            field.text = String(Self.typedQuery.prefix(length))
            field.sendActions(for: .editingChanged)
            try await Task.sleep(for: Self.keystrokeGap)
        }
        try await Task.sleep(for: Self.answerWait)
    }

    // Opens a plain page of one colour, raises search over it and flicks it closed into that page's bar.
    private func runDismissOver(background: String) async throws {
        let page = "<meta name='viewport' content='width=device-width'><body style='margin:0;background:#\(background)'>"
        env.open(URL(string: "data:text/html," + page.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!)
        while !env.activeController!.hasSettled {
            try await Task.sleep(for: Self.debugPoll)
        }
        env.ui.close(animated: false, deckTo: 0)
        try await Task.sleep(for: Self.debugGap)
        env.ui.open(.search, animated: false)
        try await Task.sleep(for: Self.debugGap)
        await drag(Self.flickClosed, over: Self.flickDuration)
        try await Task.sleep(for: Self.debugGap)
    }

    private func runRecentSwipeDemo() async throws {
        for (url, title) in Self.recentFixture {
            env.history.recordVisit(url: URL(string: url)!, title: title)
        }
        // The launch opens search before the seed; reopened, it shows the seeded recents.
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.debugGap)
        env.ui.open(.search)
        try await Task.sleep(for: Self.debugGap)
        try await swipeFirstRow(Self.recentRemovePull * container.bounds.width, over: Self.recentRemoveDuration)
        try await Task.sleep(for: Self.debugGap)
        try await swipeFirstRow(Self.recentShortPull * container.bounds.width, over: Self.recentShortDuration)
        try await Task.sleep(for: Self.debugGap)
    }

    // A steady leftward pull on the first row, one step a frame, then the release.
    private func swipeFirstRow(_ pull: CGFloat, over duration: TimeInterval) async throws {
        rowSwipeBegan(model.rows[0])
        let steps = Int(duration * Theme.Latency.frameRate)
        for step in 1...steps {
            try await Task.sleep(for: Theme.Latency.frame)
            rowSwipeChanged(pull * CGFloat(step) / CGFloat(steps))
        }
        rowSwipeEnded(velocity: pull / duration)
    }

    private func drag(_ path: [CGSize], over duration: TimeInterval) async {
        let start = CGPoint(x: view.bounds.midX, y: view.keyboardLayoutGuide.layoutFrame.minY - Self.fingerAboveKeyboard)
        await DebugFinger(path: path, duration: duration, start: start).run(into: env.debugSurfaces[.searchSheet]!)
    }

    private func runDragDemo() async throws {
        await drag(Self.flickClosed, over: Self.flickDuration)
        try await Task.sleep(for: Self.debugGap)
        env.ui.open(.search)
        try await Task.sleep(for: Self.debugGap)
        await drag(SearchDrivers.slowReturn, over: SearchDrivers.slowReturnDuration)
        try await Task.sleep(for: Self.debugGap)
        await drag(Self.quickReturn, over: Self.quickReturnDuration)
        try await Task.sleep(for: Self.debugGap)
        env.ui.close()
        try await Task.sleep(for: Self.debugGap)
        env.ui.open(.search)
        try await Task.sleep(for: Self.grabDelay)
        await drag(Self.flickClosed, over: Self.flickDuration)
        try await Task.sleep(for: Self.debugGap)
        env.ui.open(.search)
        try await Task.sleep(for: Self.debugGap)
        let sheetTop = env.debugWatches[.searchSheet]!
        let baseline = sheetTop()
        env.debugActions[.searchSubmit]!()
        _ = await InteractionProbe.watch(.searchSubmit, in: env, from: baseline, presented: sheetTop)
        try await Task.sleep(for: Self.debugGap)
    }
}
#endif
