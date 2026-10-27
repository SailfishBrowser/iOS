import Foundation
import Testing
import UIKit
import WebKit
@testable import SailBrowser

struct SitePermissionTests {
    private static let host = "cam.example"

    private final class Asks {
        var kinds: [[MediaKind]] = []
        var answer: Bool?

        init(answer: Bool?) {
            self.answer = answer
        }
    }

    private func asking(_ env: AppEnvironment, answer: Bool?) -> Asks {
        let asks = Asks(answer: answer)
        env.askMedia = { _, host, kinds in
            #expect(host == Self.host)
            asks.kinds.append(kinds)
            return asks.answer
        }
        return asks
    }

    private func onScreenWebView() -> (WKWebView, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let webView = WKWebView()
        window.addSubview(webView)
        window.isHidden = false
        return (webView, window)
    }

    @Test func siteSettingsSavedBeforeMediaPermissionsStillLoadEveryHost() throws {
        let directories = AppDirectories.temporary()
        try FileManager.default.createDirectory(at: directories.support, withIntermediateDirectories: true)
        let saved = """
            {"a.example":{"blocksTrackers":false,"allowsJavaScript":true},\
            "b.example":{"blocksTrackers":true,"allowsJavaScript":false}}
            """
        try Data(saved.utf8).write(to: directories.support.appending(path: "site-settings.json"))

        let store = SiteSettingsStore(directories: directories)
        #expect(store.byHost.count == 2)
        #expect(store["a.example"] == SiteSettings(blocksTrackers: false, camera: .ask, microphone: .ask))
        #expect(store["b.example"] == SiteSettings(allowsJavaScript: false, camera: .ask, microphone: .ask))
    }

    @Test func anAllowIsRememberedAndTheSecondRequestDoesNotAsk() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        let asks = asking(env, answer: true)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: webView))
        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: webView))
        #expect(asks.kinds == [[.camera]])
        #expect(env.sites[Self.host].camera == .allow)
    }

    @Test func aDenyIsRememberedAndAlsoDeniesTheCombinedRequest() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        let asks = asking(env, answer: false)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: webView) == false)
        asks.answer = true
        #expect(await env.decideMedia(host: Self.host, kinds: [.camera, .microphone], isPrivate: false, in: webView) == false)
        #expect(asks.kinds == [[.camera]])
        #expect(env.sites[Self.host].camera == .deny)
        #expect(env.sites[Self.host].microphone == .ask)
    }

    @Test func aCombinedRequestAsksOnlyForTheUnsetKind() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        env.sites[Self.host][.camera] = .allow
        let asks = asking(env, answer: true)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera, .microphone], isPrivate: false, in: webView))
        #expect(asks.kinds == [[.microphone]])
        #expect(env.sites[Self.host] == SiteSettings(camera: .allow, microphone: .allow))
    }

    @Test func aDismissedPromptDeniesAndRemembersNothing() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        let asks = asking(env, answer: nil)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera, .microphone], isPrivate: false, in: webView) == false)
        #expect(asks.kinds == [[.camera, .microphone]])
        #expect(env.sites[Self.host].camera == .ask)
        #expect(env.sites[Self.host].microphone == .ask)
        #expect(env.sites.byHost.isEmpty)
    }

    @Test func anOffScreenPageIsDeniedWithoutAsking() async {
        let env = makeEnvironment()
        let asks = asking(env, answer: true)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: WKWebView()) == false)
        #expect(asks.kinds.isEmpty)
        #expect(env.sites.byHost.isEmpty)
    }

    @Test func aPrivateTabAsksEveryTimeAndStoresNothing() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        env.sites[Self.host][.camera] = .allow
        let asks = asking(env, answer: false)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: true, in: webView) == false)
        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: true, in: webView) == false)
        #expect(asks.kinds == [[.camera], [.camera]])
        #expect(env.sites[Self.host] == SiteSettings(camera: .allow))
    }

    @Test func aSavedDenyChangedToAllowInSiteSettingsLetsTheNextRequestThrough() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        env.sites[Self.host][.camera] = .deny
        let asks = asking(env, answer: false)

        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: webView) == false)
        env.sites[Self.host][.camera] = .allow
        #expect(await env.decideMedia(host: Self.host, kinds: [.camera], isPrivate: false, in: webView))
        #expect(asks.kinds.isEmpty)
    }

    @Test func anAllowIsKeptForItsHostOnly() async {
        let env = makeEnvironment()
        let (webView, window) = onScreenWebView()
        defer { window.isHidden = true }
        env.sites[Self.host][.camera] = .allow
        let asks = Asks(answer: true)
        env.askMedia = { _, host, kinds in
            #expect(host == "other.example")
            asks.kinds.append(kinds)
            return asks.answer
        }

        #expect(await env.decideMedia(host: "other.example", kinds: [.camera], isPrivate: false, in: webView))
        #expect(asks.kinds == [[.camera]])
    }

    @Test func clearWebsiteDataResetsThatHostsPermissionsOnly() async {
        let env = makeEnvironment()
        env.sites["a.example"] = SiteSettings(blocksTrackers: false, camera: .allow, microphone: .deny)
        env.sites["b.example"] = SiteSettings(camera: .allow)
        // Site Settings opens over the active tab.
        env.open(URL(string: "about:blank")!)

        await env.clearSiteData(forHost: "a.example")
        #expect(env.sites["a.example"] == SiteSettings(blocksTrackers: false))
        #expect(env.sites["b.example"] == SiteSettings(camera: .allow))
    }

    @Test func clearBrowsingDataResetsEveryHostButKeepsTheToggles() async {
        let env = makeEnvironment()
        env.sites["a.example"] = SiteSettings(allowsJavaScript: false, microphone: .deny)
        env.sites["b.example"] = SiteSettings(camera: .allow)

        await env.clearBrowsingData()
        #expect(env.sites.byHost == ["a.example": SiteSettings(allowsJavaScript: false)])
    }

    @Test func theDelegateMapsCaptureTypesToKinds() async throws {
        let server = try await LocalPageServer { _ in "<p>page</p>" }
        let controller = WebTabController(tabID: UUID(), webView: PageWebView(), haptics: recordingHaptics())
        controller.load(server.url("/page"))
        try await waitUntil { controller.hasSettled }
        let asks = Asks(answer: true)
        var hosts: [String] = []
        controller.decideMedia = { host, kinds in
            hosts.append(host)
            asks.kinds.append(kinds)
            return asks.answer!
        }

        #expect(await controller.decideMedia(type: .camera) == .grant)
        #expect(await controller.decideMedia(type: .microphone) == .grant)
        asks.answer = false
        #expect(await controller.decideMedia(type: .cameraAndMicrophone) == .deny)
        #expect(asks.kinds == [[.camera], [.microphone], [.camera, .microphone]])
        #expect(hosts == Array(repeating: "127.0.0.1", count: 3))
    }
}
