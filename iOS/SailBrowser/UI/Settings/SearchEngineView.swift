import SwiftUI

// The Settings row showing the chosen engine, which pushes the list to pick another.
struct SearchEngineView: View {
    let selection: Binding<SearchEngine>

    var body: some View {
        Picker("Search Engine", selection: selection) {
            ForEach(SearchEngine.allCases, id: \.self) { engine in
                Text(engine.name).tag(engine)
            }
        }
        .pickerStyle(.navigationLink)
    }
}
