import SwiftUI

// The three blocking toggles. Each reloads the shown page as it changes.
struct BlockingSection: View {
    let changing: (WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool>

    var body: some View {
        Section {
            Toggle(isOn: changing(\.blocksAds)) {
                SettingsLabel("Block Ads", systemImage: "nosign", color: .orange)
            }
            Toggle(isOn: changing(\.blocksTrackers)) {
                SettingsLabel("Block Trackers", systemImage: "eye.slash.fill", color: .indigo)
            }
            Toggle(isOn: changing(\.blocksCookieBanners)) {
                SettingsLabel("Block Cookie Banners", systemImage: "xmark.shield.fill", color: .teal)
            }
        }
    }
}
