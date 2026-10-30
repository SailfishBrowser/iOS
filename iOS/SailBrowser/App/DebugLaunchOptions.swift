#if DEBUG
import Foundation
import os
import SwiftUI
import UIKit

nonisolated struct DebugLaunchOptions: Sendable {
    let resetState: Bool
    let seedURLs: [URL]
    let activeIndex: Int?
    let screen: String?
    let demo: String?
    let submitURL: URL?
    let scroll: String?
    // -SailPrivate 1: the seeded tabs are private.
    let isPrivate: Bool
    // -SailForceTranslation 1: every language pair reads as supported, so the simulator, where LanguageAvailability
    // reports none, offers the translate button for a foreign page. The translation itself still needs the language.
    let forceTranslation: Bool

    static func current() -> DebugLaunchOptions {
        let defaults = UserDefaults.standard
        return DebugLaunchOptions(
            resetState: defaults.bool(forKey: "SailResetState"),
            seedURLs: defaults.string(forKey: "SailSeedURLs")?.split(separator: ",").compactMap { URL(string: String($0)) }
                ?? [],
            activeIndex: defaults.object(forKey: "SailActiveIndex").map { _ in defaults.integer(forKey: "SailActiveIndex") },
            screen: defaults.string(forKey: "SailScreen"),
            demo: defaults.string(forKey: "SailDemo"),
            submitURL: defaults.string(forKey: "SailSubmitURL").flatMap(URL.init(string:)),
            scroll: defaults.string(forKey: "SailScroll"),
            isPrivate: defaults.bool(forKey: "SailPrivate"),
            forceTranslation: defaults.bool(forKey: "SailForceTranslation"))
    }
}

extension DebugLaunchOptions {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "debug")
    private static let pollInterval: Duration = .milliseconds(50)
    private static let paintDelay: Duration = .milliseconds(500)
    private static let demoColors = ["c0392b", "2e86de", "27ae60"]
    private static let demoBrowse: Duration = .seconds(31)
    private static let demoSwitcher: Duration = .seconds(1)
    private static let demoTab: Duration = .seconds(2)
    private static let profileZoom: Duration = .milliseconds(600)
    private static let fidelityStill: Duration = .seconds(3)
    private static let calibrationHold: Duration = .milliseconds(500)
    private static let calibrationTravel: CGFloat = 300
    private static let calibrationMove: Animation = .linear(duration: 0.30)
    // An even pull up on the tab stack over the previous card's whole rise, over 74 frames.
    private static let switchPullPath = [CGSize.zero, CGSize(width: 0, height: -12), CGSize(width: 0, height: -412)]
    private static let switchPullDuration: TimeInterval = 0.9
    nonisolated private static let texturedColors = ["2a1d1f", "1b2333", "1d2a22"]
    nonisolated private static let safeSpaceRows = 60
    nonisolated private static let safeSpaceTheme = "142167"
    nonisolated private static let safeSpaceLight = "f4f4f4"
    private static let safeSpaceMid: CGFloat = 600
    private static let safeSpaceHold: Duration = .seconds(60)
    private static let submitColor = Theme.Palette.demoSubmitPage
    nonisolated private static let texturedRows = 30
    private static let loadingStart = URL(string: "https://en.wikipedia.org/wiki/Main_Page")!
    private static let loadingTarget = URL(string: "https://en.wikipedia.org/wiki/World_War_II")!
    private static let profileScroll: Duration = .seconds(2)
    private static let profileFlick: Duration = .seconds(1)
    private static let profileRuns = 5
    private static let profileQuery = "google"
    private static let profileKeystroke: Duration = .milliseconds(150)
    private static let profileTyping: Duration = .milliseconds(1200)
    private static let profileLoad: Duration = .milliseconds(1500)
    private static let profileFewTabs = 3
    private static let profileRows = 200
    private static let profileColors = ["c0392b", "2e86de", "27ae60", "8e44ad", "d35400", "16a085", "2c3e50", "7f8c8d"]
    private static let latencySettle: Duration = .seconds(1)
    private static let latencyWindow: Duration = .seconds(8)
    private static let archiveFixture: [(url: String, title: String, daysAgo: Double)] = [
        ("https://www.apple.com", "Apple", 0.1),
        ("https://en.wikipedia.org/wiki/WebKit", "WebKit - Wikipedia", 1),
        ("https://news.ycombinator.com", "Hacker News", 3),
        ("https://github.com", "GitHub", 6),
        ("https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation", 18),
        ("https://www.swift.org", "Swift.org", 40),
    ]

    func prepare(_ directories: AppDirectories) {
        let files = FileManager.default
        if resetState {
            for folder in [directories.support, directories.caches]
            where files.fileExists(atPath: folder.path(percentEncoded: false)) {
                for item in try! files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    try! files.removeItem(at: item)
                }
            }
        }
        if screen == "archive" {
            let now = Date()
            let archived = Self.archiveFixture.map {
                ArchivedTab(
                    id: UUID(), url: URL(string: $0.url)!, title: $0.title,
                    archivedAt: now.addingTimeInterval(-$0.daysAgo * 24 * 3600))
            }
            let state = BrowserState(tabs: [], activeTabID: nil, settings: BrowserSettings())
            try! files.createDirectory(at: directories.support, withIntermediateDirectories: true)
            try! JSONEncoder().encode(state).write(to: directories.support.appending(path: "state.json"))
            try! JSONEncoder().encode(archived).write(to: directories.support.appending(path: "archive.json"))
        }
    }

    @MainActor func run(in env: AppEnvironment) async {
        if forceTranslation {
            env.pool.isTranslationSupported = { _, _ in true }
        }
        do {
            switch demo {
            case nil:
                try await seed(seedURLs, in: env)
                await showScreen(in: env)
            case "deckRoundTrip":
                try await runDeckRoundTrip(in: env)
            case "profile":
                try await runProfile(in: env)
            case "searchShrink":
                try await runSearchShrink(in: env)
            case "fidelity":
                try await runFidelity(in: env)
            case "switchMotion":
                try await runSwitchMotion(in: env)
            case "polish":
                try await runPolish(in: env, PolishDemo.play)
            case "followUps":
                try await runPolish(in: env, FollowUps.play)
            case "calibrate":
                try await prepareFidelity(in: env)
                try await calibrate()
                try await Task.sleep(for: Self.demoTab)
            case "loadingLine":
                try await runLoadingLine(in: env)
            case "submitLatency":
                try await runSubmitLatency(in: env)
            case "openLatency":
                try await runOpenLatency(in: env)
            case "safeSpace":
                try await runSafeSpace(in: env)
            case "glass":
                try await runGlass(in: env)
            case let demo?:
                fatalError("Unknown SailDemo \(demo)")
            }
        } catch {
            Self.logger.info("Debug launch stopped: \(error, privacy: .public)")
        }
    }

    @MainActor private func seed(_ urls: [URL], in env: AppEnvironment) async throws {
        guard !urls.isEmpty else { return }
        for url in urls {
            env.open(url, isPrivate: isPrivate)
            let controller = env.activeController!
            DebugProfiler.report("SEED opened \(env.browser.tabs.count)")
            while !controller.hasSettled {
                try await Task.sleep(for: Self.pollInterval)
            }
            try await Task.sleep(for: Self.paintDelay)
            env.captureSnapshot(of: controller.tabID)
            while env.snapshots.thumbnail(for: controller.tabID).image == nil {
                try await Task.sleep(for: Self.pollInterval)
            }
        }
        env.ui.close(animated: false, deckTo: 0)
        if let activeIndex {
            env.showTab(env.browser.tabs[activeIndex].id, via: .deckCardTap)
        }
        try await Task.sleep(for: Self.paintDelay)
        env.ui.open(.search, animated: false)
    }

    @MainActor private func showScreen(in env: AppEnvironment) async {
        switch screen {
        case nil, "search":
            break
        case "browse":
            env.ui.close(animated: false)
        case "reader":
            // The menu's Reader Mode row, on the active page.
            env.ui.close(animated: false)
            let controller = env.activeController!
            let lists = env.blocker.ruleLists(for: controller.webView.configuration.userContentController)
            await controller.openReader(ruleLists: lists)
        case "switcher":
            env.ui.close(animated: false, deckTo: 1)
        case "menu":
            env.ui.close(animated: false)
            env.ui.open(.menu, animated: false)
        case "archive":
            env.ui.close(animated: false, deckTo: 1)
            env.ui.open(.archive, animated: false)
        case "macTabs":
            env.ui.close(animated: false, deckTo: 1)
            env.ui.open(.macTabs, animated: false)
        case "settings":
            env.ui.close(animated: false, deckTo: 1)
            env.ui.open(.settings, animated: false)
        case let screen?:
            fatalError("Unknown SailScreen \(screen)")
        }
    }

    private static var demoURLs: [URL] {
        demoColors.map { URL(string: "data:text/html,%3Cbody%20style='margin:0;background:%23\($0)'%3E%3C/body%3E")! }
    }

    nonisolated private static func texturedRow(_ row: Int) -> String {
        "Row \(row): the quick brown fox jumps over the lazy dog \(row * 37) times"
    }

    static func texturedPage(_ background: String) -> URL {
        texturedPage(background, rows: texturedRows, head: "")
    }

    private static func profilePage(_ background: String) -> URL {
        texturedPage(background, rows: profileRows, head: "<title>Profile #\(background)</title>")
    }

    static func texturedPage(_ background: String, rows count: Int, head: String) -> URL {
        let html = texturedHTML(background, rows: count, head: head)
        return URL(string: "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    nonisolated static func texturedHTML(_ background: String, rows count: Int, head: String) -> String {
        let rows = (1...count).map { "<p>\(texturedRow($0))</p>" }.joined()
        return head + "<meta name='viewport' content='width=device-width'>"
            + "<body style='margin:0;padding:0 16px;background:#\(background);color:#c8c8c8;font:17px -apple-system'>"
            + rows + "</body>"
    }

    nonisolated private static func polishPage(_ background: String) -> String {
        texturedHTML(background, rows: texturedRows, head: "")
    }

    @MainActor private func prepareFidelity(in env: AppEnvironment) async throws {
        try await browseThird(of: Self.texturedColors.map(Self.texturedPage), in: env)
    }

    @MainActor private func browseThird(of pages: [URL], in env: AppEnvironment) async throws {
        try await seed(pages, in: env)
        env.ui.close(animated: false)
        env.showTab(env.browser.tabs[2].id, via: .deckCardTap)
        try await Task.sleep(for: Self.fidelityStill)
    }

    @MainActor private func calibrate() async throws {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        let layer = UIView(frame: window.bounds)
        layer.backgroundColor = UIColor(red: 0x2A / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
        for row in 1...Self.texturedRows {
            let label = UILabel(frame: CGRect(x: 16, y: CGFloat(row) * 31, width: window.bounds.width - 32, height: 21))
            label.text = Self.texturedRow(row)
            label.font = .systemFont(ofSize: 17)
            label.textColor = UIColor(white: 0.78, alpha: 1)
            layer.addSubview(label)
        }
        window.addSubview(layer)
        try await Task.sleep(for: Self.calibrationHold)
        UIView.animate(Self.calibrationMove) {
            layer.transform = CGAffineTransform(translationX: 0, y: Self.calibrationTravel)
        }
        // Video alignment anchor: steps with no watched value are timed against this commit.
        Self.logger.notice("CALIBRATE commit=\(String(format: "%.1f", CACurrentMediaTime() * 1000), privacy: .public)")
        try await Task.sleep(for: Self.calibrationHold)
        layer.removeFromSuperview()
    }

    @MainActor private func runFidelity(in env: AppEnvironment) async throws {
        try await prepareFidelity(in: env)
        try await calibrate()
        try await Task.sleep(for: Self.demoTab)
        env.ui.open(.search)
        try await Task.sleep(for: Self.demoTab)
        env.ui.close()
        try await Task.sleep(for: Self.demoTab)
        env.ui.open(.search)
        try await Task.sleep(for: Self.demoTab)
        env.submit(Self.texturedPage(Self.submitColor), via: .searchSubmit)
        try await Task.sleep(for: Self.fidelityStill)
        env.showSwitcher(via: .tabStackTap)
        try await Task.sleep(for: Self.demoTab)
        env.debugDeckThrow?()
        try await Task.sleep(for: Self.demoTab)
    }

    // Two motions for the frame counter: a bar swipe to the previous tab and a flick up on the tab stack back
    // to the tab it left, then the tab stack's tap zoom-out for reference.
    @MainActor private func runSwitchMotion(in env: AppEnvironment) async throws {
        try await prepareFidelity(in: env)
        try await calibrate()
        try await Task.sleep(for: Self.demoTab)
        let pager = env.pager!
        await DebugFinger(path: BarDrivers.swipePath(by: BarDrivers.swipeTravel), duration: BarDrivers.swipeDuration, start: .zero)
            .run { pager.swiped($0, $1) }
        try await Task.sleep(for: Self.demoTab)
        await DebugFinger(path: Self.switchPullPath, duration: Self.switchPullDuration, start: .zero)
            .run(into: env.debugSurfaces[.tabStack]!)
        try await Task.sleep(for: Self.demoTab)
        env.showSwitcher(via: .tabStackTap)
        try await Task.sleep(for: Self.demoTab)
    }

    // The fidelity pages plus the submit page, served over loopback: a data page has no host, so the menu would show
    // no zoom steps.
    // The page server serves until the script ends.
    @MainActor private func runPolish(
        in env: AppEnvironment, _ script: @MainActor (AppEnvironment) async throws -> Void
    ) async throws {
        let server = try await DemoPageServer(page: Self.polishPage)
        defer { server.stop() }
        try await browseThird(of: (Self.texturedColors + [Self.submitColor]).map(server.url), in: env)
        try await calibrate()
        try await script(env)
    }

    // The glass pages over loopback (a data page has no host, so the menu would show no zoom steps), the dark one in
    // front, then every chrome motion the frost touches, one PROFILE line each.
    @MainActor private func runGlass(in env: AppEnvironment) async throws {
        let server = try await DemoPageServer(page: GlassDemo.page)
        defer { server.stop() }
        try await seed(GlassDemo.backgrounds.map(server.url), in: env)
        env.ui.close(animated: false)
        env.showTab(env.browser.tabs[1].id, via: .deckCardTap)
        try await GlassDemo.play(in: env)
    }

    // A long themed page with fixed header and footer markers, left at its top, mid-page with the bar hidden by a
    // user scroll, or at its end, for screenshots of the page's top and bottom edges.
    @MainActor private func runSafeSpace(in env: AppEnvironment) async throws {
        let server = try await DemoPageServer(page: Self.safeSpacePage)
        defer { server.stop() }
        let markers = UserDefaults.standard.bool(forKey: "SailMarkers")
        let light = UserDefaults.standard.bool(forKey: "SailLight")
        try await seed([server.url(light ? Self.safeSpaceLight : Self.texturedColors[markers ? 2 : 1])], in: env)
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoTab)
        let scrollView = env.activeController!.webView.scrollView
        switch scroll {
        case nil, "top":
            break
        case "mid":
            scrollView.setContentOffset(CGPoint(x: 0, y: Self.safeSpaceMid), animated: false)
            await WebDrivers.table[.barHide]!(env)
        case "end":
            let insets = scrollView.adjustedContentInset
            scrollView.setContentOffset(
                CGPoint(x: 0, y: scrollView.contentSize.height + insets.bottom - scrollView.bounds.height),
                animated: false)
        case let scroll?:
            fatalError("Unknown SailScroll \(scroll)")
        }
        try await Task.sleep(for: Self.safeSpaceHold)
    }

    nonisolated private static func safeSpacePage(_ background: String) -> String {
        guard background == texturedColors[2] else {
            let theme = background == safeSpaceLight ? background : safeSpaceTheme
            return texturedHTML(background, rows: safeSpaceRows, head: "<meta name='theme-color' content='#\(theme)'>")
        }
        let marker = "position:fixed;left:0;right:0;height:24px;background:#e67e22;color:#000;font:13px -apple-system"
        return texturedHTML(
            background, rows: safeSpaceRows,
            head: "<meta name='theme-color' content='#\(safeSpaceTheme)'>"
                + "<div style='\(marker);top:0'>fixed top</div><div style='\(marker);bottom:0'>fixed bottom</div>")
    }

    @MainActor private func runLoadingLine(in env: AppEnvironment) async throws {
        try await seed([Self.loadingStart], in: env)
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoTab)
        env.activeController!.load(Self.loadingTarget)
    }

    @MainActor private func runSubmitLatency(in env: AppEnvironment) async throws {
        try await seed([Self.texturedPage(Self.texturedColors[0])], in: env)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        let behind = window.rootViewController!.firstDescendant(BehindController.self)!
        let field = window.firstDescendant(SearchField.self)!
        try await Task.sleep(for: Self.latencySettle)
        field.text = submitURL!.absoluteString
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: Self.latencySettle)
        let probe = SubmitProbe(env: env, stage: behind.stage)
        env.debugLoadStarted = { probe.loadStarted($0) }
        probe.start()
        _ = field.delegate!.textFieldShouldReturn!(field)
        probe.mark("handled")
        try await Task.sleep(for: Self.latencyWindow)
        probe.stop()
        Self.logger.notice("LATENCY \(probe.summary, privacy: .public)")
    }

    // The "+" opens on touch-down by running its own open action; this times that action to the sheet's first moving
    // frame.
    @MainActor private func runOpenLatency(in env: AppEnvironment) async throws {
        try await seed([Self.texturedPage(Self.texturedColors[0])], in: env)
        env.ui.close(animated: false)
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        let sheet = window.rootViewController!.firstDescendant(SearchSheetController.self)!
        for _ in 1...Self.profileRuns {
            try await Task.sleep(for: Self.latencySettle)
            let probe = OpenProbe(sheet: sheet.container)
            probe.start()
            env.debugActions[.plusTap]!()
            probe.mark("handled")
            try await Task.sleep(for: Self.latencySettle)
            probe.stop()
            Self.logger.notice("OPEN \(probe.summary, privacy: .public)")
            env.ui.close()
        }
    }

    @MainActor private func runSearchShrink(in env: AppEnvironment) async throws {
        try await seed(Self.demoURLs, in: env)
        env.ui.close(animated: false)
        for _ in 0..<2 {
            try await Task.sleep(for: Self.demoTab)
            env.ui.open(.search)
            try await Task.sleep(for: Self.demoTab)
            env.ui.close()
        }
    }

    @MainActor private func runProfile(in env: AppEnvironment) async throws {
        DebugProfiler.report("PROFILE maximumFramesPerSecond=\(DebugProfiler.maximumFramesPerSecond)")
        switch UserDefaults.standard.string(forKey: "SailProfileFocus") {
        case "manyTabs":
            try await runManyTabsProfile(in: env)
            return
        case "search":
            try await runSearchProfile(in: env)
            return
        default:
            break
        }
        try await seed(Self.profileColors.prefix(Self.profileFewTabs).map(Self.profilePage), in: env)
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoTab)
        let profiler = DebugProfiler()
        try await profiler.measure("idle", for: Self.profileScroll)
        try await profileZooms("\(Self.profileFewTabs)", in: env, with: profiler)
        try await profileSearch(in: env, with: profiler)
        let scrollView = env.activeController!.webView.scrollView
        for run in 1...Self.profileRuns {
            let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            let target = run.isMultiple(of: 2) ? -scrollView.adjustedContentInset.top : bottom
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            try await profiler.measure("pageScroll.\(run)", for: Self.profileZoom)
            try await Task.sleep(for: Self.demoSwitcher)
        }
        env.showSwitcher(via: .tabStackTap)
        try await Task.sleep(for: Self.demoTab)
        for run in 1...Self.profileRuns {
            let last = CGFloat(env.browser.tabs.count - 1)
            try await profiler.measure("cardScroll.\(run)", for: Self.profileFlick) { elapsed in
                let phase = min(1, elapsed / Double(Self.profileFlick.components.seconds))
                env.debugDeckPosition?(last * abs(1 - 2 * phase))
            }
        }
        env.showTab(env.browser.tabs[Self.profileFewTabs - 1].id, via: .deckCardTap)
        try await Task.sleep(for: Self.demoTab)
        try await seed(Self.profileColors.dropFirst(Self.profileFewTabs).map(Self.profilePage), in: env)
        try await profileManyTabs(in: env, with: profiler)
    }

    // Only the search flow the phone traced at 60 Hz, about 50 s, its submits adding five tabs.
    @MainActor private func runSearchProfile(in env: AppEnvironment) async throws {
        try await seed(Self.profileColors.prefix(Self.profileFewTabs).map(Self.profilePage), in: env)
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoTab)
        let profiler = DebugProfiler()
        try await profileSearch(in: env, with: profiler)
        for run in 1...Self.profileRuns {
            env.ui.open(.search)
            try await Task.sleep(for: Self.demoSwitcher)
            env.submit(Self.profilePage(Self.profileColors[Self.profileFewTabs + run - 1]), via: .searchSubmit)
            try await profiler.measure("searchSubmit.\(run)", for: Self.profileZoom)
            try await profiler.measure("pageLoad.\(run)", for: Self.profileLoad)
            try await Task.sleep(for: Self.demoSwitcher)
        }
        DebugProfiler.report("PROFILE done")
    }

    // The open, typing (each keystroke through the field's own edit path), the close, and a deck zoom started while
    // the close is still running.
    @MainActor private func profileSearch(in env: AppEnvironment, with profiler: DebugProfiler) async throws {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        let field = window.firstDescendant(SearchField.self)!
        let sheet = window.rootViewController!.firstDescendant(SearchSheetController.self)!
        for run in 1...Self.profileRuns {
            // The open's own main-thread time, from the call to the end of the turn that commits its first frame, split
            // into rise and the rest of that turn (SwiftUI's pass), and the responder change after it on its own.
            let opened = CACurrentMediaTime()
            let firstCommit = OpenCommit()
            env.ui.open(.search)
            AfterCommit.run { firstCommit.at = CACurrentMediaTime() }
            try await profiler.measure("searchOpen.\(run)", for: Self.profileZoom)
            let touchToCommit = firstCommit.at - opened
            let rise = Self.duration(of: "searchRise", in: sheet, since: opened)
            let part = { (name: String) in Self.duration(of: name, in: sheet, since: opened) * 1000 }
            DebugProfiler.report(String(
                format: "PROFILE openCommit.%d touchToCommit ms=%.2f rise ms=%.2f (prepare %.2f cover %.2f layout %.2f parts %.2f) restOfTurn ms=%.2f responder ms=%.2f",
                run, touchToCommit * 1000, rise * 1000, part("searchRisePrepare"), part("searchRiseCover"),
                part("searchRiseLayout"), part("searchRiseParts"), (touchToCommit - rise) * 1000, part("searchResponder")))
            async let typing: Void = profiler.measure("searchTyping.\(run)", for: Self.profileTyping)
            // Each keystroke split two ways: insertText, now UIKit's text input alone, and the sheet's edit with the ranking
            // (ours), which runs on the turn after the keystroke's commit. The rows lay out in SwiftUI's pass after it.
            var keystrokes: [String] = []
            for letter in Self.profileQuery {
                let begin = CACurrentMediaTime()
                field.insertText(String(letter))
                let uikit = CACurrentMediaTime() - begin
                try await Task.sleep(for: Self.profileKeystroke)
                keystrokes.append(String(
                    format: "%.2f/%.2f", Self.duration(of: "searchEdit", in: sheet, since: begin) * 1000, uikit * 1000))
            }
            try await typing
            DebugProfiler.report("PROFILE keystrokes.\(run) ours/uikit ms=" + keystrokes.joined(separator: ","))
            // The close's frames, then each piece of the sheet's own work in the window, as name@start+duration in ms
            // from the close, to set against the profile's longest frame (mainMaxAt).
            let closed = CACurrentMediaTime()
            env.ui.close()
            try await profiler.measure("searchClose.\(run)", for: Self.profileZoom)
            DebugProfiler.report("PROFILE closeWork.\(run) " + sheet.work.filter { $0.at >= closed }.map {
                String(format: "%@@%.1f+%.2f", $0.name, ($0.at - closed) * 1000, $0.duration * 1000)
            }.joined(separator: ","))
            try await Task.sleep(for: Self.demoSwitcher)
            env.ui.open(.search)
            try await Task.sleep(for: Self.demoSwitcher)
            env.ui.close()
            env.showSwitcher(via: .tabStackTap)
            try await profiler.measure("zoomOverClose.\(run)", for: Self.profileZoom)
            try await Task.sleep(for: Self.demoSwitcher)
            env.showTab(env.browser.activeTabID!, via: .deckCardTap)
            try await Task.sleep(for: Self.demoSwitcher)
        }
    }

    @MainActor private static func duration(
        of name: String, in sheet: SearchSheetController, since start: CFTimeInterval
    ) -> CFTimeInterval {
        sheet.work.last { $0.name == name && $0.at >= start }?.duration ?? 0
    }

    @MainActor private func runManyTabsProfile(in env: AppEnvironment) async throws {
        try await seed(Self.profileColors.map(Self.profilePage), in: env)
        try await profileManyTabs(in: env, with: DebugProfiler())
    }

    @MainActor private func profileManyTabs(in env: AppEnvironment, with profiler: DebugProfiler) async throws {
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoTab)
        try await profileZooms("\(env.browser.tabs.count)", in: env, with: profiler)
        env.showSwitcher(via: .tabStackTap)
        try await Task.sleep(for: Self.demoTab)
        for run in 1...Self.profileRuns {
            try await Task.sleep(for: Self.demoSwitcher)
            env.debugDeckThrow?()
            try await profiler.measure("cardThrow.\(run)", for: Self.profileZoom)
        }
        DebugProfiler.report("PROFILE done")
    }

    @MainActor private func profileZooms(_ label: String, in env: AppEnvironment, with profiler: DebugProfiler)
        async throws
    {
        for run in 1...Self.profileRuns {
            env.showSwitcher(via: .tabStackTap)
            try await profiler.measure("zoomOut\(label).\(run)", for: Self.profileZoom)
            try await Task.sleep(for: Self.demoSwitcher)
            env.showTab(env.browser.tabs[run % env.browser.tabs.count].id, via: .deckCardTap)
            try await profiler.measure("zoomIn\(label).\(run)", for: Self.profileZoom)
            try await Task.sleep(for: Self.demoSwitcher)
        }
    }

    @MainActor private func runDeckRoundTrip(in env: AppEnvironment) async throws {
        try await seed(Self.demoURLs, in: env)
        env.ui.close(animated: false)
        try await Task.sleep(for: Self.demoBrowse)
        env.showSwitcher(via: .tabStackTap)
        try await Task.sleep(for: Self.demoSwitcher)
        env.showTab(env.browser.tabs[0].id, via: .deckCardTap)
        try await Task.sleep(for: Self.demoTab)
        env.activatePreviousTab()
    }
}

private extension UIView {
    func firstDescendant<View: UIView>(_ type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstDescendant(type) {
                return match
            }
        }
        return nil
    }
}

private extension UIViewController {
    func firstDescendant<Controller: UIViewController>(_ type: Controller.Type) -> Controller? {
        for child in children {
            if let match = child as? Controller ?? child.firstDescendant(type) {
                return match
            }
        }
        return nil
    }
}

// Marks how long after its start each named moment first shows, in milliseconds and display frames.
class FrameProbe {
    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var frames = 0
    private var marks: [(name: String, ms: Double, frame: Int)] = []

    var summary: String {
        marks.map { "\($0.name)=\(String(format: "%.1f", $0.ms))ms@f\($0.frame)" }.joined(separator: " ")
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        startedAt = CACurrentMediaTime()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    final func mark(_ name: String, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard !isMarked(name) else { return }
        marks.append((name, (time - startedAt) * 1000, frames))
    }

    final func isMarked(_ name: String) -> Bool {
        marks.contains { $0.name == name }
    }

    func frame(at time: CFTimeInterval) {}

    @objc private func tick(_ link: CADisplayLink) {
        frames += 1
        frame(at: link.targetTimestamp)
    }
}

final class OpenProbe: FrameProbe {
    private let sheet: UIView
    private let barTop: CGFloat

    init(sheet: UIView) {
        self.sheet = sheet
        barTop = sheet.window!.bounds.height - Theme.Metrics.barTotalHeight
    }

    // The sheet starts with its top on the bar's top; its first frame above that is its first motion.
    override func frame(at time: CFTimeInterval) {
        guard !sheet.isHidden, let top = sheet.layer.presentation()?.frame.minY else { return }
        mark("shown", at: time)
        if top < barTop - 0.5 {
            mark("firstMotion", at: time)
        }
    }
}

final class SubmitProbe: FrameProbe {
    private let env: AppEnvironment
    private let stage: UIView
    private var tabID: Tab.ID?

    init(env: AppEnvironment, stage: UIView) {
        self.env = env
        self.stage = stage
    }

    func loadStarted(_ id: Tab.ID) {
        tabID = id
        mark("load")
    }

    override func frame(at time: CFTimeInterval) {
        if let opacity = stage.layer.presentation()?.opacity, opacity < 1 {
            mark("firstMotion", at: time)
        }
        if isMarked("handled"), !env.ui.isSubmitting {
            mark("hidden", at: time)
        }
        guard let tabID, let controller = env.pool.liveController(for: tabID) else { return }
        if controller.isRevealable {
            mark("revealed", at: time)
        }
        if !controller.title.isEmpty {
            mark("title", at: time)
        }
        if controller.hasSettled {
            mark("settled", at: time)
        }
    }
}

@MainActor private final class OpenCommit {
    var at: CFTimeInterval = 0
}
#endif
