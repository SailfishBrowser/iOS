import SwiftUI

// The three blocking toggles. Each reloads the shown page as it changes.
struct BlockingSection: View {
    let changing: (WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool>

    var body: some View {
        Section {
            Toggle("Block Ads", isOn: changing(\.blocksAds))
            Toggle("Block Trackers", isOn: changing(\.blocksTrackers))
            Toggle("Block Cookie Banners", isOn: changing(\.blocksCookieBanners))
        }
    }
}
