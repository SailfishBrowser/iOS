import SwiftUI

// "Export Open Tabs…" and the way back in, so a user's tabs can move between browsers.
struct TransferSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showsImport: Bool

    var body: some View {
        Section {
            Button {
                env.haptics.fire(.settingsOpen)
                SharePresenter.share(text: TabExport.text(env.browser.tabs))
            } label: {
                SettingsLabel("Export Open Tabs…", systemImage: "square.and.arrow.up", color: .green)
            }
            .disabled(!env.browser.tabs.contains { !$0.isPrivate })
            Button {
                env.haptics.fire(.settingsOpen)
                showsImport = true
            } label: {
                SettingsLabel("Import Open Tabs…", systemImage: "square.and.arrow.down", color: .green)
            }
        }
        .tint(.primary)
    }
}
