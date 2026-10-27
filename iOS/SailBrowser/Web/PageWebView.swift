import WebKit

final class PageWebView: WKWebView {
    private var parkedTopOffset: CGPoint?

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil, scrollView.contentOffset.y < 0 {
            parkedTopOffset = scrollView.contentOffset
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, let offset = parkedTopOffset {
            parkedTopOffset = nil
            scrollView.contentOffset = offset
        }
    }
}
