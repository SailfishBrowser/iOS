import SwiftUI

@Observable final class UIState {
    enum Overlay: Equatable, Sendable { case none, search, menu, macTabs, settings, siteSettings }

    // How the behind card and its dim follow the latest searchShrink change, on Core Animation; nil sets it at once.
    struct ShrinkMotion: Equatable {
        let token: MotionToken
        let velocity: CGFloat
    }

    enum SheetItem: String, Identifiable, Sendable {
        case macTabs, settings, siteSettings
        var id: String { rawValue }
    }

    private(set) var overlay: Overlay = .none
    // The site the Site Settings sheet was opened for, kept while the page under it may navigate.
    private(set) var siteSettingsHost: String?
    private(set) var deckProgress: CGFloat = 0
    // Draws the deck's zoom and the bars' cross-fade from one display link.
    let deck = DeckDriver()
    private(set) var searchShrink: CGFloat = 0
    @ObservationIgnored private(set) var searchShrinkMotion: ShrinkMotion?
    private(set) var behindOpacity: CGFloat = 1
    private(set) var isSubmitting = false
    private(set) var isBarIntroPending = false {
        didSet { onBarChanged?() }
    }
    // The bar follows its intro and the search cover from the call that flips them, never through an update.
    @ObservationIgnored var onBarChanged: (() -> Void)?
    // While the search sheet lies over the browsing bar (its open and its close) it draws the bar itself, so the
    // bar beneath stays hidden: a material over a material would read lighter than the bar does alone.
    private(set) var isSearchCoveringBar = false {
        didSet { onBarChanged?() }
    }
    private(set) var barIntroTask: Task<Void, Never>?
    // Incognito: while on, the search sheet's next tab is private. It is never saved.
    private(set) var isPrivateMode = false
    // Whether the tab the search sheet opens over is private; nil with no tab, where the mode keeps its last toggle.
    @ObservationIgnored var activeTabIsPrivate: () -> Bool? = { nil }
    private var pendingSubmit: (hidden: () -> Void, cancel: () -> Void)?
    @ObservationIgnored private let haptics: HapticsEngine

    init(haptics: HapticsEngine) {
        self.haptics = haptics
    }

    var presentedSheet: Binding<SheetItem?> {
        Binding(
            get: {
                switch self.overlay {
                case .macTabs: .macTabs
                case .settings: .settings
                case .siteSettings: .siteSettings
                case .none, .search, .menu: nil
                }
            },
            set: { item in
                if item == nil, [.macTabs, .settings, .siteSettings].contains(self.overlay) {
                    self.close()
                }
            })
    }

    @discardableResult func openSiteSettings(for host: String) -> Bool {
        guard canOpen(.siteSettings) else { return false }
        siteSettingsHost = host
        return open(.siteSettings)
    }

    func setPrivateMode(_ on: Bool) {
        isPrivateMode = on
    }

    func searchCoversBar(_ covering: Bool) {
        isSearchCoveringBar = covering
    }

    // The deck takes grabs only at the switcher. During a zoom-in the page takes every touch where it is drawn.
    var deckTakesTouches: Bool {
        deckProgress == 1 && overlay == .none
    }

    func canOpen(_ overlay: Overlay) -> Bool {
        guard self.overlay == .none else { return false }
        switch overlay {
        case .none: return false
        case .menu: return !deck.barsShowDeck
        case .siteSettings: return deckProgress == 0
        case .macTabs, .settings: return deck.barsShowDeck
        case .search: return true
        }
    }

    @discardableResult func open(_ overlay: Overlay, animated: Bool = true) -> Bool {
        guard canOpen(overlay) else { return false }
        if overlay == .search {
            restoreBehind()
            if let isPrivate = activeTabIsPrivate() {
                isPrivateMode = isPrivate
            }
        }
        // A control on a bar drawn during the opposite zoom acts as it would at rest: the zoom turns back to its
        // bar's state as the control opens.
        if let home = Self.home(of: overlay), deckProgress != home {
            setDeck(home, animated: animated)
        }
        guard animated else {
            self.overlay = overlay
            if overlay == .search {
                shrinkSearch(to: 1, nil)
            }
            return true
        }
        switch overlay {
        case .search:
            self.overlay = overlay
            shrinkSearch(to: 1, ShrinkMotion(token: .keyboard, velocity: 0))
        case .macTabs, .settings, .siteSettings:
            FrameRateVote.hold(for: Theme.Latency.systemSheetHold)
            self.overlay = overlay
        case .menu, .none:
            self.overlay = overlay
        }
        return true
    }

    func close(animated: Bool = true, deckTo progress: CGFloat? = nil) {
        let closing = overlay
        let apply = {
            self.overlay = .none
            if closing == .search {
                self.shrinkSearch(
                    to: 0,
                    animated
                        ? ShrinkMotion(
                            token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity)
                        : nil)
            }
            if let progress {
                self.moveDeck(to: progress, animated: animated)
            }
        }
        guard animated else {
            apply()
            return
        }
        switch closing {
        // Each sheet's host moves it on Core Animation from where it is drawn.
        case .search, .menu: apply()
        case .macTabs, .settings, .siteSettings, .none:
            if closing != .none {
                FrameRateVote.hold(for: Theme.Latency.systemSheetHold)
            }
            overlay = .none
            if let progress {
                setDeck(progress)
            }
        }
    }

    func setDeck(_ progress: CGFloat, animated: Bool = true) {
        guard animated else {
            moveDeck(to: progress, animated: false)
            return
        }
        FrameRateVote.hold(Theme.Motion.zoom)
        withAnimation(Theme.Motion.zoom.animation) { moveDeck(to: progress, animated: true) }
    }

    private func shrinkSearch(to shrink: CGFloat, _ motion: ShrinkMotion?) {
        searchShrinkMotion = motion
        searchShrink = shrink
    }

    private func moveDeck(to progress: CGFloat, animated: Bool) {
        deckProgress = progress
        deck.follow(progress, animated: animated)
    }

    private static func home(of overlay: Overlay) -> CGFloat? {
        switch overlay {
        case .menu: 0
        case .macTabs, .settings: 1
        case .none, .search, .siteSettings: nil
        }
    }

    func submitSearch(onHidden: @escaping () -> Void, onCancel: @escaping () -> Void) {
        precondition(pendingSubmit == nil)
        overlay = .none
        isSubmitting = true
        isBarIntroPending = true
        barIntroTask?.cancel()
        pendingSubmit = (onHidden, onCancel)
        behindOpacity = 0
    }

    func submitHidden() {
        guard let pending = pendingSubmit else { return }
        pendingSubmit = nil
        // Before the hand-off, so a submitted tab that only downloaded can close and send the deck to the switcher.
        moveDeck(to: 0, animated: false)
        pending.hidden()
        shrinkSearch(to: 0, nil)
        isSubmitting = false
        behindOpacity = 1
    }

    func scheduleBarIntro() {
        guard isBarIntroPending else { return }
        barIntroTask?.cancel()
        barIntroTask = Task {
            guard (try? await Task.sleep(for: .seconds(Theme.Motion.barIntroDelay))) != nil else { return }
            haptics.fire(.barIntro)
            isBarIntroPending = false
        }
    }

    func endBarIntro() {
        barIntroTask?.cancel()
        isBarIntroPending = false
    }

    private func restoreBehind() {
        barIntroTask?.cancel()
        let cancelled = pendingSubmit
        pendingSubmit = nil
        behindOpacity = 1
        isSubmitting = false
        isBarIntroPending = false
        cancelled?.cancel()
    }
}

