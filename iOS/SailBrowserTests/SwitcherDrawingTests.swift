import QuartzCore
import SwiftUI
import Synchronization
import Testing
import UIKit
import WebKit
@testable import SailBrowser

private final class CountingBand: PrivateBandView {
    var layouts = 0

    override func layoutSubviews() {
        layouts += 1
        super.layoutSubviews()
    }
}

// Holds every request until the test answers the page with a document whose image never arrives, so the load's
// progress steps while the load goes on.
private final class HeldPageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let page = URL(string: "hang://page/a")!
    private var held: [any WKURLSchemeTask] = []
    private(set) var started: [URL] = []

    func answerPage() {
        for task in held where task.request.url == Self.page {
            task.didReceive(
                URLResponse(url: Self.page, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
            task.didReceive(Data((String(repeating: "<p>page</p>", count: 2000) + "<img src='hang://page/image'>").utf8))
            task.didFinish()
        }
        held.removeAll { $0.request.url == Self.page }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        started.append(urlSchemeTask.request.url!)
        held.append(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        held.removeAll { $0 === urlSchemeTask }
    }
}

private final class Seen: Sendable {
    let progress = Mutex(0.0)
}

// Reads the controller's progress in the same update as the line, so the test knows when the line has seen a step.
private struct ProgressProbe: View {
    let controller: WebTabController
    let seen: Seen

    var body: some View {
        Color.clear.onChange(of: controller.progress, initial: true) { _, new in seen.progress.withLock { $0 = new } }
    }
}

struct SwitcherDrawingTests {
    // The refresh ring's spin asks for the deck's rate, as the arm pulse does; left to the system it turned at 60 Hz.
    @Test func theRingsSpinAsksForTheDecksRate() throws {
        let ring = RingView()
        ring.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        ring.update(progress: 0, isSpinning: true, isArmed: false)
        let gradient = try #require(ring.layer.sublayers?.first?.sublayers?.first)
        let spin = try #require(
            gradient.animationKeys()?.lazy.compactMap { gradient.animation(forKey: $0) as? CABasicAnimation }
                .first { $0.keyPath == "transform.rotation.z" })
        #expect(spin.asksForFullRate)
    }

    // The page's host hands the band its safe top on every frame the card moves: the band lays out when it changes
    // and not again for the same one. Its own size still lays it out.
    @Test func theBandLaysOutOnceForOneSafeTop() {
        let band = CountingBand(frame: CGRect(x: 0, y: 0, width: 440, height: 62 + Theme.Metrics.privateBandExtra))
        band.layout(safeTop: 62)
        band.layout(safeTop: 62)
        #expect(band.layouts == 1)
        #expect(!band.ring.isHidden)
        band.layout(safeTop: 47)
        #expect(band.layouts == 2)
        #expect(band.ring.isHidden)
        band.frame.size.width = 402
        band.layoutIfNeeded()
        #expect(band.layouts == 3)
        #expect(band.label.center.x == 201)
    }

    // The band's picture is the band laid out for its safe top: the label row carries ink that is not the band's.
    @Test func thePictureIsTheLaidOutBand() {
        let picture = PrivateBandView.picture(width: 440, safeTop: 62)
        #expect(picture.size == CGSize(width: 440, height: 62 + Theme.Metrics.privateBandExtra))
        let band = components(Theme.Palette.privateBand)
        let row = (picture.size.height - Theme.Metrics.privateBandLabelCenterFromBottom) / picture.size.height
        let inked = (0..<40).filter { pixel(picture, at: CGPoint(x: 0.3 + 0.4 * CGFloat($0) / 39, y: row)) != band }
        #expect(!inked.isEmpty)
        #expect(pixel(picture, at: CGPoint(x: 0.05, y: row)) == band)
    }

    // A progress step moves the line on SwiftUI's clock, so it holds no vote; the line's fade in and out do.
    @Test(.timeLimit(.minutes(1))) func aProgressStepHoldsNoVote() async throws {
        let handler = HeldPageSchemeHandler()
        let controller = hangingController(hanging: handler)
        defer { controller.webView.stopLoading() }
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let seen = Seen()
        let host = UIHostingController(
            rootView: ZStack {
                LoadingLine(controller: controller)
                ProgressProbe(controller: controller, seen: seen)
            })
        host.view.frame = window.bounds
        window.addSubview(host.view)
        window.isHidden = false

        // Names the wait that ran out, with the state it saw.
        func stage(_ name: String, _ condition: () -> Bool) async throws {
            do {
                try await waitUntil(condition)
            } catch {
                let state = (controller.progress, seen.progress.withLock { $0 }, controller.isLoading, handler.started)
                Issue.record("\(name): \(state) hold \(FrameRateVote.heldUntil - CACurrentMediaTime())")
                throw error
            }
        }
        controller.load(HeldPageSchemeHandler.page)
        try await stage("start") { seen.progress.withLock { $0 } > 0 && handler.started.contains(HeldPageSchemeHandler.page) }
        #expect(controller.isLoading)
        try await stage("start hold over") { CACurrentMediaTime() > FrameRateVote.heldUntil }
        let held = FrameRateVote.heldUntil
        handler.answerPage()
        try await stage("step") { seen.progress.withLock { $0 } > 0.1 }
        #expect(controller.isLoading)
        #expect(FrameRateVote.heldUntil == held)

        controller.webView.stopLoading()
        try await stage("stop") { FrameRateVote.heldUntil > held }
    }
}
