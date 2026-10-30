import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingClear = false
    @State private var showsDownloads = false
    @State private var showsArchive = false
    @State private var showsImport = false
    private let blocklistVersion: String

    init(blocklistVersion: String) {
        self.blocklistVersion = blocklistVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Metrics.settingsButtonGap) {
                        pill("Downloads", systemImage: "folder", action: openDownloads)
                        pill("Archive", systemImage: "archivebox", action: openArchive)
                            #if DEBUG
                            .debugAction(.archiveOpen, openArchive)
                            #endif
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                DefaultBrowserSection()
                Section {
                    SearchEngineView(selection: changing(\.searchEngine))
                }
                Section {
                    Toggle(isOn: changing(\.autoOpenKeyboard)) {
                        SettingsLabel("Auto-Open Keyboard", systemImage: "keyboard", color: .yellow)
                    }
                    Picker(selection: changing(\.archiveInterval)) {
                        ForEach(ArchiveInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    } label: {
                        SettingsLabel("Archive tabs after", systemImage: "archivebox.fill", color: .purple)
                    }
                    Picker(selection: changing(\.opensAppLinksInApp)) {
                        Text("Native App").tag(true)
                        Text("Sailfish").tag(false)
                    } label: {
                        SettingsLabel("Open App Links in", systemImage: "arrow.up.forward.app", color: .blue)
                    }
                    Button {
                        confirmingClear = true
                    } label: {
                        SettingsLabel("Clear Browsing Data…", systemImage: "eraser.fill", color: .red)
                    }
                    .tint(.primary)
                    .confirmationDialog("Clear Browsing Data", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear Browsing Data", role: .destructive) {
                            Task { await env.clearBrowsingData() }
                        }
                    } message: {
                        Text("Website data, history and archived tabs will be removed. Open tabs stay.")
                    }
                }
                BlockingSection(changing: changing)
                TransferSection(showsImport: $showsImport)
                AcknowledgementsSection(footer: "Version \(Self.appVersion)\nBlocklists \(blocklistVersion)")
            }
            .contentMargins(.top, Theme.Metrics.settingsTop, for: .scrollContent)
            .navigationDestination(isPresented: $showsDownloads) { DownloadsView() }
            .navigationDestination(isPresented: $showsArchive) { ArchiveView() }
            .navigationDestination(isPresented: $showsImport) { ImportTabsView() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheetDoneButton()
        }
    }

    private func openDownloads() {
        env.haptics.fire(.settingsOpen)
        showsDownloads = true
    }

    private func openArchive() {
        env.haptics.fire(.archiveOpen)
        showsArchive = true
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.settingsButton)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: Theme.Metrics.settingsButtonHeight)
                .background(Theme.Palette.settingsButtonFill, in: .capsule)
        }
        .buttonStyle(.plain)
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
