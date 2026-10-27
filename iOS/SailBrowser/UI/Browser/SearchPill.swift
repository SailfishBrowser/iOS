import SwiftUI

// Search opens on touch-down with no pressed state, moving on the first frame after the touch.
struct SearchPill: View {
    @Environment(AppEnvironment.self) private var env
    @GestureState private var isTouching = false
    let fill: Color
    let atDeck: Bool

    var body: some View {
        Image(systemName: "plus")
            .font(Theme.Typography.barPlusGlyph)
            .frame(width: Theme.Metrics.pillSize.width, height: Theme.Metrics.pillSize.height)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(Theme.Opacity.barEdge), lineWidth: Theme.Metrics.hairlineWidth))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, isTouching, _ in
                        if TouchDownLatch.fires(&isTouching) {
                            open()
                        }
                    })
            #if DEBUG
            .debugAction(.plusTap) { open() }
            #endif
            .accessibilityLabel(atDeck ? "New Tab" : "Search")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }

    // A swipe or a flick still springing lands first, as the switcher does, so search opens over the tab it was going
    // to and no landing runs under the sheet.
    private func open() {
        guard env.ui.canOpen(.search) else { return }
        env.flick?.finish()
        env.pager?.finish()
        env.haptics.fire(.plusTap)
        env.ui.open(.search)
    }
}

// Opens once per touch: gesture state resets when the touch ends or is cancelled, so "+" can never stay latched.
enum TouchDownLatch {
    static func fires(_ latched: inout Bool) -> Bool {
        defer { latched = true }
        return !latched
    }
}
