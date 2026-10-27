import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingClear = false
    @State private var showsDownloads = false
    @State private var showsImport = false
    private let blocklistVersion: String

    init(blocklistVersion: String) {
        self.blocklistVersion = blocklistVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        env.haptics.fire(.settingsOpen)
                        showsDownloads = true
                    } label: {
                        Label("Downloads", systemImage: "folder")
                            .font(Theme.Typography.settingsButton)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.settingsButtonHeight)
                            .background(Theme.Palette.settingsButtonFill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                DefaultBrowserSection()
                Section {
                    SearchEngineView(selection: changing(\.searchEngine))
                    Toggle("Auto-Open Keyboard", isOn: changing(\.autoOpenKeyboard))
                    Picker("Archive tabs after", selection: changing(\.archiveInterval)) {
                        ForEach(ArchiveInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                }
                BlockingSection(changing: changing)
                AppLinksSection(opensInApp: changing(\.opensAppLinksInApp))
                TransferSection(showsImport: $showsImport)
                AcknowledgementsSection()
                Section {
                    Button("Clear Browsing Data", role: .destructive) {
                        confirmingClear = true
                    }
                    .confirmationDialog("Clear Browsing Data", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear Browsing Data", role: .destructive) {
                            Task { await env.clearBrowsingData() }
                        }
                    } message: {
                        Text("Website data, history and archived tabs will be removed. Open tabs stay.")
                    }
                } footer: {
                    Text("Version \(Self.appVersion)\nBlocklists \(blocklistVersion)")
                }
            }
            .navigationDestination(isPresented: $showsDownloads) { DownloadsView() }
            .navigationDestination(isPresented: $showsImport) { ImportTabsView() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheetDoneButton()
        }
    }

    private func changing<Value>(_ setting: WritableKeyPath<BrowserSettings, Value>) -> Binding<Value> {
        Binding {
            env.browser.settings[keyPath: setting]
        } set: {
            env.haptics.fire(.settingsChange)
            env.browser.settings[keyPath: setting] = $0
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary!
        return "\(info["CFBundleShortVersionString"] as! String) (\(info["CFBundleVersion"] as! String))"
    }
}
