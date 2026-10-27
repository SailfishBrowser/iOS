import UIKit
import WebKit

// A link's long-press menu. The preview stays WebKit's own (no preview provider), and the menu shows on WebKit's
// timing. Anything that is not a link keeps WebKit's default menu.
extension WebTabController {
    func webView(
        _ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(linkMenuConfiguration(for: elementInfo.linkURL))
    }

    // Committing the preview opens the link here, as Safari does.
    func webView(
        _ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating
    ) {
        guard let url = elementInfo.linkURL else { return }
        load(url)
    }

    func linkMenuConfiguration(for url: URL?) -> UIContextMenuConfiguration? {
        guard let url else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.linkMenu(for: url)
        }
    }

    func linkMenu(for url: URL) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.onOpenLink?(url, false)
            },
            UIAction(title: "Open in Background", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                self?.onOpenLink?(url, true)
            },
            UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = TrackingParams.strip(url)
            },
            UIAction(title: "Share Link", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                SharePresenter.share(url)
            },
        ])
    }
}
