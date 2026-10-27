import SwiftUI
import UniformTypeIdentifiers

// Any text that holds links, pasted or read from a file; the tabs already open are skipped, and the rest join the
// end of the deck when the sheet closes onto the switcher.
struct ImportTabsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var text = ""
    @State private var choosingFile = false

    var body: some View {
        let all = TabImport.tabs(from: text)
        let openURLs = Set(env.browser.tabs.filter { !$0.isPrivate }.map(\.url.absoluteString))
        let tabs = all.filter { !openURLs.contains($0.url.absoluteString) }
        let alreadyOpen = all.count - tabs.count
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: Theme.Metrics.importEditorHeight)
                HStack {
                    PasteButton(payloadType: String.self) { text = $0.joined(separator: "\n") }
                    Spacer()
                    Button("Choose File…") { choosingFile = true }
                }
            } footer: {
                if alreadyOpen > 0 {
                    Text("^[\(tabs.count) link](inflect: true) to open, \(alreadyOpen) already open")
                } else {
                    Text("^[\(tabs.count) link](inflect: true) to open")
                }
            }
            Section {
                Button("Open ^[\(tabs.count) Tab](inflect: true)") {
                    env.importTabs(tabs)
                    env.ui.close()
                }
                .disabled(tabs.isEmpty)
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.text]) { result in
            // The user's file is a real boundary: one that cannot be read leaves the text as it was.
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents
            }
        }
        .navigationTitle("Import Open Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .sheetDoneButton()
    }
}
