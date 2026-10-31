import SwiftUI

// The privacy policy, a page on the web, with the filter lists' attribution, the scriptlets' origins and Reader Mode's
// Readability licence. The app's and the blocklists' versions sit under it.
struct AcknowledgementsSection: View {
    @Environment(AppEnvironment.self) private var env
    let footer: String

    var body: some View {
        Section {
            Button {
                env.openPrivacyPolicy()
            } label: {
                SettingsLabel("Privacy Policy", systemImage: "hand.raised.fill", color: .blue)
            }
            .tint(.primary)
            NavigationLink {
                ScrollView {
                    Text(Self.notice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Acknowledgements")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                SettingsLabel("Acknowledgements", systemImage: "doc.text.fill", color: .gray)
            }
        } footer: {
            Text(footer)
        }
    }

    static var notice: String {
        [("NOTICE", "txt"), ("Readability-0.6.0-LICENSE", "md")].map { name, type in
            try! String(contentsOf: Bundle.main.url(forResource: name, withExtension: type)!, encoding: .utf8)
        }.joined(separator: "\n")
    }
}
