import SwiftUI

// The "Set as Default Browser" row. iOS lists Sail under Default Apps only once the build carries the browser
// entitlement, so the row waits for the flag the build writes, from SAIL_DEFAULT_BROWSER, rather than show a row that does nothing.
struct DefaultBrowserSection: View {
    @Environment(AppEnvironment.self) private var env

    static func isAvailable(_ flag: String?) -> Bool {
        flag == "YES"
    }

    var body: some View {
        if Self.isAvailable(Bundle.main.object(forInfoDictionaryKey: "SailfishDefaultBrowser") as? String) {
            Section {
                Button {
                    env.haptics.fire(.settingsOpen)
                    UIApplication.shared.open(URL(string: UIApplication.openDefaultApplicationsSettingsURLString)!)
                } label: {
                    SettingsLabel("Set Sailfish as Default Browser", systemImage: "globe", color: .blue)
                }
                .tint(.primary)
            }
        }
    }
}
