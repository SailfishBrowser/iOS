import SwiftUI

extension View {
    // The Done button shared by the archive and settings sheets.
    func sheetDoneButton() -> some View {
        modifier(SheetDoneButton())
    }
}

private struct SheetDoneButton: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
            #if DEBUG
            .debugAction(.sheetDone, done)
            #endif
    }

    private func done() {
        env.haptics.fire(.sheetDone)
        env.ui.close()
    }
}
