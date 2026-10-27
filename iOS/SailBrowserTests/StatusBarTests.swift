import Testing
import UIKit
@testable import SailBrowser

struct StatusBarTests {
    @Test func theStatusWindowStepsAsideWhileAPageIsFullscreen() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let installer = StatusBarInstaller.InstallerView()
        installer.style = .darkContent
        window.addSubview(installer)
        let status = try #require(installer.statusWindow)
        defer { status.isHidden = true }
        #expect(!status.isHidden)
        #expect(status.style == .darkContent)

        installer.isFullscreen = true
        #expect(status.isHidden)
        #expect(status.style == .darkContent)
        installer.isFullscreen = false
        #expect(!status.isHidden)
    }

    // The page's tint changes under the video; the bar reads it the moment the window is back.
    @Test func aStyleChangedWhileHiddenShowsWhenTheWindowReturns() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let installer = StatusBarInstaller.InstallerView()
        window.addSubview(installer)
        let status = try #require(installer.statusWindow)
        defer { status.isHidden = true }
        installer.isFullscreen = true
        installer.style = .darkContent
        #expect(status.isHidden)

        installer.isFullscreen = false
        #expect(!status.isHidden)
        #expect(status.style == .darkContent)
        #expect(status.rootViewController?.preferredStatusBarStyle == .darkContent)
    }

    @Test func aStatusWindowInstalledMidFullscreenStartsHidden() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let installer = StatusBarInstaller.InstallerView()
        installer.isFullscreen = true
        window.addSubview(installer)
        let status = try #require(installer.statusWindow)
        defer { status.isHidden = true }
        #expect(status.isHidden)
        installer.isFullscreen = false
        #expect(!status.isHidden)
    }
}
