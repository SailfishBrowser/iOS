import SwiftUI
import UIKit

// The chrome's one frosted material: a classic UIKit blur that carries the page's colour through, tinted by a plain
// colour on its contentView. Controls, rows and hairlines go in contentView; corner shaping stays with the caller, as
// a clip on this view (a mask on a superview breaks the effect). A backdrop never fades by its own or an ancestor's
// alpha over the sharp page; a surface that must leave fades its effect, through show(nil).
class ChromeMaterial: UIVisualEffectView {
    private(set) var style: UIBlurEffect.Style?
    #if DEBUG
    private(set) var updates = 0
    #endif

    // nil draws no blur; a solid surface tints contentView instead.
    init(_ style: UIBlurEffect.Style?) {
        self.style = style
        super.init(effect: style.map { UIBlurEffect(style: $0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Assigning a fresh effect resets the backdrop and costs a frame, so the same style is a no-op.
    func show(_ style: UIBlurEffect.Style?) {
        #if DEBUG
        updates += 1
        #endif
        guard style != self.style else { return }
        self.style = style
        effect = style.map { UIBlurEffect(style: $0) }
    }

    // A linear overlay over the blur: 15% leaves 85% of it.
    func tint(_ color: UIColor, opacity: CGFloat) {
        contentView.backgroundColor = color.withAlphaComponent(opacity)
    }
}

// The SwiftUI face of the same view, for the bar's background.
struct ChromeMaterialView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> ChromeMaterial {
        ChromeMaterial(style)
    }

    func updateUIView(_ view: ChromeMaterial, context: Context) {
        view.show(style)
    }
}
