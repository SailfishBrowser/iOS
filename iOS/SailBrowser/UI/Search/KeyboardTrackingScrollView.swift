import UIKit

// A transparent, full-height scroll view with nothing to scroll, between the host view and the sheet's container: a
// drag that starts anywhere on the sheet then "begins in a scroll view", and UIKit's interactive dismissal takes the
// real keyboard with the touch once the finger reaches it. The sheet's own pan keeps moving the sheet; the two read one
// touch. The content never moves: the bounce is pinned back to zero each time it changes, so nothing is drawn with the
// rubber band and the scroll view stays dragging for UIKit's dismissal.
final class KeyboardTrackingScrollView: UIScrollView, UIScrollViewDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        backgroundColor = .clear
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size {
            contentSize = bounds.size
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if contentOffset != .zero {
            contentOffset = .zero
        }
    }

    // A pull that starts on the field, a control, is a drag like any other: UIKit would otherwise leave the touch to
    // the control and never begin the pan that tracks the keyboard.
    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }

    // Only the sheet under it takes touches; a touch beside the sheet goes behind, to the dim.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
