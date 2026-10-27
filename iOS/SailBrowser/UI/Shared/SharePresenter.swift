import UIKit

enum SharePresenter {
    // A live page shares its print formatter too, so the sheet offers Print, and Save to Files offers a PDF.
    static func share(_ controller: WebTabController) {
        present(activityItems(for: controller))
    }

    // Where there is no web view, such as a link or an archived entry, only the URL is shared.
    static func share(_ url: URL) {
        present(activityItems(for: url))
    }

    // Text, such as the open tabs list: Copy, Notes, Messages, Mail and AirDrop all take it as it is.
    static func share(text: String) {
        present([text])
    }

    static func activityItems(for controller: WebTabController) -> [Any] {
        [SharedPage(url: controller.url!, subject: controller.title), controller.webView.viewPrintFormatter()]
    }

    static func activityItems(for url: URL) -> [Any] {
        [TrackingParams.strip(url)]
    }

    // A link from another app opens over the browser, so a share sheet the user left up goes first. SwiftUI's own
    // sheets are left to their bindings.
    static func dismiss() {
        var top = keyWindow.rootViewController!
        while let presented = top.presentedViewController {
            if presented is UIActivityViewController {
                top.dismiss(animated: false)
                return
            }
            top = presented
        }
    }

    private static var keyWindow: UIWindow {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
    }

    private static func present(_ items: [Any]) {
        var top = keyWindow.rootViewController!
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
    }
}

// The page's URL with its title as the subject, for activities such as Mail that have a subject field.
nonisolated final class SharedPage: NSObject, UIActivityItemSource {
    let url: URL
    let subject: String

    init(url: URL, subject: String) {
        self.url = TrackingParams.strip(url)
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject
    }
}
