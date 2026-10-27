import SwiftUI

// "Open App Links in": a tapped link that an installed app claims opens in that app, or stays here.
struct AppLinksSection: View {
    let opensInApp: Binding<Bool>

    var body: some View {
        Section {
            Picker("Open App Links in", selection: opensInApp) {
                Text("Native App").tag(true)
                Text("Sailfish").tag(false)
            }
        }
    }
}
