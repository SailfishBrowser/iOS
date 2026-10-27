import os
import UIKit
import WebKit

// The app-link check sits on the tap-to-load path; this interval lets a phone trace measure it.
private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)

nonisolated enum ExternalLinks {
    enum Kind: Equatable, Sendable {
        // Loads in the web view.
        case page
        // An http or https link, which an installed app may claim.
        case web
        // Belongs to another app: phone, mail, messages, App Store and the like.
        case external
    }

    private static let pageSchemes: Set<String> = ["about", "data", "blob", "file", "javascript"]
    private static let appStoreHosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]

    static func kind(of url: URL) -> Kind {
        let scheme = url.scheme?.lowercased() ?? ""
        if pageSchemes.contains(scheme) { return .page }
        guard scheme == "http" || scheme == "https" else { return .external }
        return appStoreHosts.contains(url.host()?.lowercased() ?? "") ? .external : .web
    }

    static func appName(for url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "tel": "Phone"
        case "mailto": "Mail"
        case "sms": "Messages"
        case "facetime", "facetime-audio": "FaceTime"
        case "maps": "Maps"
        case "itms-apps", "http", "https": "App Store"
        default: "another app"
        }
    }
}

// What a tab asks of the system for links that leave the browser. Tests stand in their own.
struct AppOpener {
    var opensAppLinks: () -> Bool
    // Opens the URL in another app; with universalOnly it opens only an app that claims the link.
    var open: (_ url: URL, _ universalOnly: Bool) async -> Bool
    // Asks whether a page may switch to the named app without a tap.
    var confirm: (_ app: String) async -> Bool

    static let none = AppOpener(opensAppLinks: { false }, open: { _, _ in false }, confirm: { _ in false })

    static func live(opensAppLinks: @escaping () -> Bool, confirm: @escaping (String) async -> Bool) -> AppOpener {
        AppOpener(
            opensAppLinks: opensAppLinks,
            open: { url, universalOnly in
                await UIApplication.shared.open(url, options: universalOnly ? [.universalLinksOnly: true] : [:])
            },
            confirm: confirm)
    }
}

// What a navigation's policy needs to know about where it goes and how it started.
struct LinkRequest {
    let url: URL
    // A new window counts as the main frame: it would open a tab.
    let isMainFrame: Bool
    let type: WKNavigationType

    init(url: URL, isMainFrame: Bool, type: WKNavigationType) {
        self.url = url
        self.isMainFrame = isMainFrame
        self.type = type
    }

    init?(_ action: WKNavigationAction) {
        guard let url = action.request.url else { return nil }
        self.init(url: url, isMainFrame: action.targetFrame?.isMainFrame ?? true, type: action.navigationType)
    }
}

extension WebTabController {
    // True when another app takes the navigation, which is then cancelled here. A page's window.open to another app
    // reaches the popup delegate instead, which hands it here and makes no tab. A link to another app's scheme opens
    // that app: at once from a tap, after asking when the page jumps there itself, never from a subframe. A tapped
    // link to another site first goes to an app that claims it, unless the setting is off; reloads, history moves,
    // redirects and links within the page's own site stay here, so a page cannot bounce the user out.
    func leavesForApp(_ link: LinkRequest) async -> Bool {
        let tapped = link.type == .linkActivated
        switch ExternalLinks.kind(of: link.url) {
        case .page:
            return false
        case .external:
            if webView.configuration.urlSchemeHandler(forURLScheme: link.url.scheme!) != nil { return false }
            guard link.isMainFrame else { return true }
            let allowed = tapped ? true : await appOpener.confirm(ExternalLinks.appName(for: link.url))
            if allowed {
                _ = await appOpener.open(link.url, false)
            }
            return true
        case .web:
            guard link.isMainFrame, tapped, link.url.host() != webView.url?.host(), appOpener.opensAppLinks() else {
                return false
            }
            let open = appOpener.open
            let interval = signposter.beginInterval("appLinkCheck")
            let opened = await answer(within: Theme.Latency.appLinkAnswer, { await open(link.url, true) }) {
                [weak self] in self?.stopLoad(of: link.url)
            }
            signposter.endInterval("appLinkCheck", interval)
            return opened
        }
    }

    // A yes that came after the limit let the page load: the app is opening on top, so the load is stopped where it
    // stands, unless a newer navigation has taken the web view since. Short of a commit that leaves the page before.
    private func stopLoad(of url: URL) {
        guard webView.url == url else { return }
        webView.stopLoading()
    }
}

// The system's answer, or no once the limit passes. The system call cannot be cancelled, so whichever side comes first
// resumes, once; a yes after the limit has still opened its app, and goes to `late`. Both tasks run on the main actor.
private func answer(
    within limit: Duration, _ ask: @escaping @MainActor () async -> Bool, late: @escaping @MainActor () -> Void
) async -> Bool {
    let once = Once()
    return await withCheckedContinuation { done in
        Task {
            let yes = await ask()
            if !once.resume(done, returning: yes), yes {
                late()
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(done, returning: false)
        }
    }
}

private final class Once {
    private var isDone = false

    // False when the other side had already resumed.
    @discardableResult
    func resume(_ continuation: CheckedContinuation<Bool, Never>, returning value: Bool) -> Bool {
        guard !isDone else { return false }
        isDone = true
        continuation.resume(returning: value)
        return true
    }
}
