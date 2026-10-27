import SwiftUI
import Translation

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    let hapticSink: LiveHapticSink

    var body: some View {
        let ui = env.ui
        ZStack {
            Theme.Palette.searchBackdrop
                .ignoresSafeArea()
            BehindHost(shrink: ui.searchShrink, deckProgress: ui.deckProgress, opacity: ui.behindOpacity)
                .ignoresSafeArea()
            PageMenuHost(isOpen: ui.overlay == .menu)
                .ignoresSafeArea()
            let dimTap: @MainActor () -> Void = {
                env.haptics.fire(.searchDimTap)
                ui.close()
            }
            // The dim itself is drawn behind, on Core Animation; this takes its taps.
            Color.clear
                .contentShape(.rect)
                .ignoresSafeArea()
                .onTapGesture { dimTap() }
                .allowsHitTesting(ui.overlay == .search)
                #if DEBUG
                .debugAction(.searchDimTap, dimTap)
                #endif
            SearchSheetHost(isActive: ui.overlay == .search, isSubmitting: ui.isSubmitting)
                .ignoresSafeArea()
        }
        .sheet(item: ui.presentedSheet) { item in
            Group {
                switch item {
                case .archive: ArchiveView()
                case .settings: SettingsView(blocklistVersion: env.blocklistVersion)
                case .siteSettings: SiteSettingsView(host: ui.siteSettingsHost!)
                }
            }
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
        }
        .background {
            HapticInstaller(sink: hapticSink, haptics: env.haptics)
            StatusBarStyler()
        }
        .task {
            await env.finishLaunch()
        }
        .translationTask(env.translation.configuration, action: env.translation.run)
        .ignoresSafeArea(.keyboard)
    }
}
