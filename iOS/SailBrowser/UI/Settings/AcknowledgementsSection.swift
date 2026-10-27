import SwiftUI

// The privacy policy, a page on the web, with the filter lists' attribution, the scriptlets' origins and Reader Mode's
// Readability licence.
struct AcknowledgementsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            Button("Privacy Policy") {
                env.openPrivacyPolicy()
            }
            NavigationLink("Acknowledgements") {
                ScrollView {
                    Text(Self.notice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Acknowledgements")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    static var notice: String {
        [("NOTICE", "txt"), ("Readability-0.6.0-LICENSE", "md")].map { name, type in
            try! String(contentsOf: Bundle.main.url(forResource: name, withExtension: type)!, encoding: .utf8)
        }.joined(separator: "\n")
    }
}
