import Foundation
import Testing
import UIKit
import WebKit
@testable import SailBrowser

private func link(_ url: String, _ type: WKNavigationType, mainFrame: Bool = true) -> LinkRequest {
    LinkRequest(url: URL(string: url)!, isMainFrame: mainFrame, type: type)
}

// Records what the controller asks of the system, answering with the given values.
@MainActor private final class OpenerProbe {
    var opened: [(url: URL, universalOnly: Bool)] = []
    var asked: [String] = []
    var appLinksOn = true
    var appLinkAnswer = false
    // How long iOS takes to answer whether an app claims a link.
    var appLinkDelay: Duration = .zero
    var confirmAnswer = true

    var opener: AppOpener {
        AppOpener(
            opensAppLinks: { [unowned self] in appLinksOn },
            open: { [unowned self] url, universalOnly in
                opened.append((url, universalOnly))
                guard universalOnly else { return true }
                // An answer that comes after the test has ended must not touch the probe.
                let (delay, answer) = (appLinkDelay, appLinkAnswer)
                try? await Task.sleep(for: delay)
                return answer
            },
            confirm: { [unowned self] app in
                asked.append(app)
                return confirmAnswer
            })
    }
}

struct ExternalLinksTests {
    @Test(arguments: [
        ("tel:+15551234567", ExternalLinks.Kind.external),
        ("mailto:a@b.test", .external),
        ("sms:+15551234567", .external),
        ("facetime:a@b.test", .external),
        ("maps://?q=cafe", .external),
        ("itms-apps://apps.apple.com/app/id1", .external),
        ("https://apps.apple.com/us/app/id6472513080", .external),
        ("https://itunes.apple.com/app/id1", .external),
        ("https://example.test/", .web),
        ("http://example.test/", .web),
        ("HTTPS://Example.test/", .web),
        ("about:blank", .page),
        ("javascript:void(0)", .page),
        ("blob:https://example.test/1", .page),
        ("data:text/html,a", .page),
        ("file:///tmp/a.html", .page),
    ])
    func classifies(_ link: String, _ kind: ExternalLinks.Kind) {
        #expect(ExternalLinks.kind(of: URL(string: link)!) == kind)
    }

    @Test(arguments: [
        ("tel:1", "Phone"), ("mailto:a@b.test", "Mail"), ("sms:1", "Messages"), ("facetime:a@b.test", "FaceTime"),
        ("facetime-audio:a@b.test", "FaceTime"), ("maps://?q=a", "Maps"), ("itms-apps://x", "App Store"),
        ("https://apps.apple.com/app/id1", "App Store"), ("zoomus://x", "another app"),
    ])
    func namesTheApp(_ link: String, _ app: String) {
        #expect(ExternalLinks.appName(for: URL(string: link)!) == app)
    }
}

@Suite(.serialized)
struct LinkPolicyTests {
    private static let page = URL(string: "https://page.test/")!

    // A controller showing a page on page.test, so links have a site to leave.
    private func controller(_ probe: OpenerProbe) async throws -> WebTabController {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(StalledSchemeHandler(), forURLScheme: "stall")
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: configuration), haptics: recordingHaptics())
        controller.appOpener = probe.opener
        controller.webView.loadSimulatedRequest(URLRequest(url: Self.page), responseHTML: "<p>page</p>")
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled && controller.url == Self.page }
        return controller
    }

    private func decide(_ controller: WebTabController, _ link: LinkRequest) async -> WKNavigationActionPolicy {
        await controller.leavesForApp(link) ? .cancel : .allow
    }

    @Test func aTappedPhoneLinkCancelsAndOpensOnce() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        #expect(await decide(controller, link("tel:+15551234567", .linkActivated)) == .cancel)
        #expect(probe.opened.map(\.url) == [URL(string: "tel:+15551234567")!])
        #expect(probe.opened.map(\.universalOnly) == [false])
        #expect(probe.asked.isEmpty)
    }

    @Test func aPhoneLinkInASubframeCancelsSilently() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        #expect(await decide(controller, link("tel:1", .other, mainFrame: false)) == .cancel)
        #expect(probe.opened.isEmpty)
        #expect(probe.asked.isEmpty)
    }

    @Test func aTappedMailLinkOpensMail() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        #expect(await decide(controller, link("mailto:a@b.test", .linkActivated)) == .cancel)
        #expect(probe.opened.map(\.url) == [URL(string: "mailto:a@b.test")!])
    }

    @Test func anUntappedMainFrameJumpAsksFirst() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        #expect(await decide(controller, link("itms-apps://apps.apple.com/app/id1", .other)) == .cancel)
        #expect(probe.asked == ["App Store"])
        #expect(probe.opened.count == 1)

        probe.confirmAnswer = false
        #expect(await decide(controller, link("itms-apps://apps.apple.com/app/id1", .other)) == .cancel)
        #expect(probe.asked.count == 2)
        #expect(probe.opened.count == 1)
    }

    @Test func pagesAndTheWebViewsOwnSchemesAreAllowed() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        for page in ["about:blank", "data:text/html,a", "blob:https://page.test/1", "stall://page/a"] {
            #expect(await decide(controller, link(page, .other)) == .allow)
        }
        #expect(probe.opened.isEmpty)
    }

    @Test func aTappedAppLinkTheSystemDeclinesProceeds() async throws {
        let probe = OpenerProbe()
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .allow)
        #expect(probe.opened.map(\.url) == [URL(string: "https://other.test/a")!])
        #expect(probe.opened.map(\.universalOnly) == [true])
    }

    @Test func aTappedAppLinkTheSystemOpensCancels() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .cancel)
        #expect(probe.opened.count == 1)
    }

    @Test func aTappedLinkLoadsOnceTheAppLinkDeadlinePassesWithNoAnswer() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        probe.appLinkDelay = .seconds(1)
        let controller = try await controller(probe)
        let clock = ContinuousClock()
        let start = clock.now

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .allow)
        #expect(clock.now - start < Theme.Latency.appLinkAnswer * 4)
        #expect(probe.opened.count == 1)
    }

    @Test func aYesWithinTheAppLinkDeadlineStillCancels() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        probe.appLinkDelay = Theme.Latency.appLinkAnswer / 5
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .cancel)
        #expect(probe.opened.count == 1)
    }

    @Test func aYesAfterTheAppLinkDeadlineHasAlreadyLetTheLoadThrough() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        probe.appLinkDelay = Theme.Latency.appLinkAnswer * 4
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .allow)
        try await Task.sleep(for: Theme.Latency.appLinkAnswer * 8)
        #expect(probe.opened.count == 1)
    }

    @Test(arguments: [WKNavigationType.reload, .backForward, .other, .formSubmitted, .formResubmitted])
    func onlyATapTriesAnAppLink(_ type: WKNavigationType) async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", type)) == .allow)
        #expect(probe.opened.isEmpty)
    }

    @Test func aTapWithinTheSameSiteNeverTriesAnAppLink() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://page.test/other", .linkActivated)) == .allow)
        #expect(probe.opened.isEmpty)
    }

    @Test func aTapInASubframeNeverTriesAnAppLink() async throws {
        let probe = OpenerProbe()
        probe.appLinkAnswer = true
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated, mainFrame: false)) == .allow)
        #expect(probe.opened.isEmpty)
    }

    @Test func withAppLinksOffATapStaysInTheBrowser() async throws {
        let probe = OpenerProbe()
        probe.appLinksOn = false
        probe.appLinkAnswer = true
        let controller = try await controller(probe)

        #expect(await decide(controller, link("https://other.test/a", .linkActivated)) == .allow)
        #expect(probe.opened.isEmpty)
    }

    @Test func aPhoneLinkTappedOnARealPageReachesTheOpener() async throws {
        let probe = OpenerProbe()
        let controller = WebTabController(
            tabID: UUID(), webView: PageWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            haptics: recordingHaptics())
        controller.appOpener = probe.opener
        let page = URL(string: "https://page.test/")!
        controller.webView.loadSimulatedRequest(
            URLRequest(url: page), responseHTML: #"<a id="call" href="tel:+15551234567">Call</a>"#)
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled && controller.url == page }

        _ = try await controller.webView.evaluateJavaScript("document.getElementById('call').click()")
        try await waitUntil { !probe.opened.isEmpty }

        #expect(probe.opened.map(\.url) == [URL(string: "tel:+15551234567")!])
        #expect(controller.url == page)
    }
}

@Suite(.serialized)
struct NewWindowLinkTests {
    nonisolated private static let targets = ["tel:+15551234567", "mailto:a@b.test", "itms-apps://apps.apple.com/app/id1"]
    // A target=_blank link, and a page's own window.open from a tap, as share-by-mail buttons do.
    nonisolated private static let openers = [
        #"<a id="out" target="_blank" href="TARGET">Out</a>"#,
        #"<button id="out" onclick="window.open('TARGET')">Out</button>"#,
    ]

    @Test(arguments: targets, openers)
    func aLinkToAnotherAppInANewWindowOpensNoTab(_ target: String, _ opener: String) async throws {
        let env = makeEnvironment()
        let page = URL(string: "https://page.test/")!
        env.open(page)
        let controller = try #require(env.activeController)
        let probe = OpenerProbe()
        controller.appOpener = probe.opener
        controller.webView.loadSimulatedRequest(
            URLRequest(url: page), responseHTML: opener.replacingOccurrences(of: "TARGET", with: target))
        try await waitUntil(timeout: .seconds(10)) { controller.hasSettled && controller.url == page }

        _ = try await controller.webView.evaluateJavaScript("document.getElementById('out').click()")
        try await waitUntil { !probe.opened.isEmpty }
        try await Task.sleep(for: .milliseconds(300))

        #expect(probe.opened.map(\.url) == [URL(string: target)!])
        #expect(env.browser.tabs.count == 1)
        #expect(env.activeController === controller)
    }
}

struct AppLinksSettingTests {
    @Test func appLinksOpenInTheirAppsByDefault() {
        #expect(BrowserSettings().opensAppLinksInApp)
    }

    @Test func aStateSavedBeforeTheSettingOpensAppLinksInTheirApps() throws {
        let saved = #"{"archiveInterval":"oneDay","adBlockingEnabled":true,"zoomByHost":{}}"#
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(saved.utf8))
        #expect(settings.opensAppLinksInApp)
    }

    @Test func theSettingRoundTrips() throws {
        var settings = BrowserSettings()
        settings.opensAppLinksInApp = false
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.opensAppLinksInApp)
    }

    @Test func aPageOffScreenCannotJumpToAnAppOnItsOwn() async {
        let env = makeEnvironment()
        env.open(page("a"))
        let controller = env.activeController!

        #expect(await controller.appOpener.confirm("Phone") == false)
        #expect(controller.dialogs.current == nil)
    }

    @Test func controllersFollowTheSetting() {
        let env = makeEnvironment()
        env.open(page("a"))
        let controller = env.activeController!
        #expect(controller.appOpener.opensAppLinks())
        env.browser.settings.opensAppLinksInApp = false
        #expect(!controller.appOpener.opensAppLinks())
    }
}
