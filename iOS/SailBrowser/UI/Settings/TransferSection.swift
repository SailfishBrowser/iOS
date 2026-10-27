import SwiftUI

// "Export Open Tabs…" and the way back in, so a user's tabs can move between browsers.
struct TransferSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var showsImport: Bool

    var body: some View {
        Section {
            Button("Export Open Tabs…") {
                env.haptics.fire(.settingsOpen)
                SharePresenter.share(text: TabExport.text(env.browser.tabs))
            }
            .disabled(!env.browser.tabs.contains { !$0.isPrivate })
            Button("Import Open Tabs…") {
                env.haptics.fire(.settingsOpen)
                showsImport = true
            }
        }
    }
}
