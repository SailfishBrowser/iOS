import Foundation
import Testing
import UIKit
import WebKit
@testable import SailBrowser

// The bar is hosted as BarSlideHitTests.placed (BarTests.swift) hosts it, over a controller that supports every
// language pair, so a French page offers a translation in the simulator. The press is scripted through the button's
// DEBUG surface as the tab stack's is; DragSample's time is the test's, so a hold costs no sleep.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TranslateButtonTests {
    private static let french = Locale.Language(identifier: "fr")
    private static let english = Locale.Language(identifier: "en")
    private static let frenchPage = "<html lang=\"fr\"><body><p>Le chat dort.</p></body></html>"

    private struct Hosted {
        let env: AppEnvironment
        let controller: WebTabController
        let bar: BarSlideView
        let window: UIWindow
    }

    private func hosted() -> Hosted {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(), haptics: env.haptics, isTranslationSupported: { _, _ in true })
        let bar = BarSlideView(BarContent(env: env, controller: controller), hidden: false)
        bar.frame = CGRect(x: 0, y: 300, width: window.bounds.width, height: Theme.Metrics.barTotalHeight)
        window.addSubview(bar)
        window.makeKeyAndVisible()
        bar.layoutIfNeeded()
        return Hosted(env: env, controller: controller, bar: bar, window: window)
    }

    // Loads a French page and waits for the offer and the button it brings.
    private func loadFrench(_ hosted: Hosted, html: String = Self.frenchPage) async throws {
        await loadAndFinish(hosted.controller, html: html, base: "https://example.test/fr")
        try await waitUntil { hosted.controller.translator.source == Self.french }
        try await waitUntil { hosted.env.debugSurfaces[.translate] != nil }
    }

    // A touch down at t and a release at t + held, the finger `travel` from where it began.
    private func press(_ hosted: Hosted, travel: CGSize = .zero, held: TimeInterval = 0.1) {
        let surface = hosted.env.debugSurfaces[.translate]!
        let down = Date()
        let start = CGPoint(x: 100, y: 20)
        surface(.began, DragSample(startLocation: start, location: start, translation: .zero, velocity: .zero, time: down))
        surface(
            .ended,
            DragSample(
                startLocation: start, location: CGPoint(x: start.x + travel.width, y: start.y + travel.height),
                translation: travel, velocity: .zero, time: down.addingTimeInterval(held)))
    }

    private func sample(_ dx: CGFloat, _ dy: CGFloat) -> DragSample {
        DragSample(
            startLocation: .zero, location: CGPoint(x: dx, y: dy), translation: CGSize(width: dx, height: dy),
            velocity: .zero, time: Date())
    }

    private func currentLook(_ hosted: Hosted) -> TranslateButton.Look {
        TranslateButton.look(hosted.controller.translator.state, target: hosted.controller.translator.target)
    }

    @Test func theLookFollowsTheStateAndATapIsShortStillAndNotASwipe() {
        let look = { (state: PageTranslator.State) in TranslateButton.look(state, target: Self.english) }
        let translate = TranslateButton.Look(showsSpinner: false, isTranslated: false, label: "Translate to English")
        #expect(look(.idle) == translate)
        #expect(look(.failed) == translate)
        #expect(look(.translating).showsSpinner)
        #expect(!look(.translating).isTranslated)
        #expect(
            look(.translated(from: Self.french, to: Self.english))
                == TranslateButton.Look(showsSpinner: false, isTranslated: true, label: "Show Original"))

        #expect(TranslateButton.isTap(sample(3, 2), duration: 0.1, isSwiping: false))
        #expect(!TranslateButton.isTap(sample(12, 0), duration: 0.1, isSwiping: false))
        #expect(!TranslateButton.isTap(sample(0, 0), duration: 0.4, isSwiping: false))
        #expect(!TranslateButton.isTap(sample(0, 0), duration: 0.1, isSwiping: true))
    }

    // The offer comes from detection and goes at the next commit; the reader covers the page and takes the button with
    // it. The fade runs before onDisappear withdraws the surface, so each change is waited for.
    @Test func theButtonAppearsWithTheOfferLeavesOnACommitAndHidesUnderTheReader() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        try await loadFrench(hosted)

        let target = hosted.controller.translator.target.minimalIdentifier
        await loadAndFinish(
            hosted.controller, html: "<html lang=\"\(target)\"><body><p>same</p></body></html>",
            base: "https://example.test/same")
        try await waitUntil { hosted.env.debugSurfaces[.translate] == nil }
        #expect(hosted.controller.translator.source == nil)

        try await loadFrench(
            hosted, html: ReaderFixtures.html("readability-001").replacing("lang=\"en\"", with: "lang=\"fr\""))
        await hosted.controller.openReader(ruleLists: [])
        #expect(hosted.controller.readerArticle != nil)
        try await waitUntil { hosted.env.debugSurfaces[.translate] == nil }
        #expect(hosted.controller.translator.source == Self.french)

        hosted.controller.closeReader()
        try await waitUntil { hosted.env.debugSurfaces[.translate] != nil }
    }

    @Test func theTapRequestsThroughTheHostAndASecondTapShowsTheOriginal() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        try await loadFrench(hosted)
        let before = hosted.env.haptics.records.count

        press(hosted)
        #expect(hosted.env.translation.configuration?.source == Self.french)
        #expect(hosted.controller.translator.state == .translating)
        #expect(currentLook(hosted).showsSpinner)
        let record = hosted.env.haptics.records.last
        #expect(record?.interaction == .barTranslate)
        #expect(record?.played == true)
        #expect(hosted.env.ui.overlay == .none)

        // A tap on the spinner queues nothing.
        press(hosted)
        #expect(hosted.env.haptics.records.count == before + 1)

        await hosted.env.translation.run(RecordingSession())
        #expect(hosted.controller.translator.state == .translated(from: Self.french, to: hosted.controller.translator.target))
        #expect(currentLook(hosted).isTranslated)
        #expect(currentLook(hosted).label == "Show Original")

        press(hosted)
        try await waitUntil { hosted.controller.translator.state == .idle }
        #expect(hosted.env.haptics.records.count == before + 2)
        #expect(hosted.env.haptics.records.last?.interaction == .barTranslate)
        #expect(!currentLook(hosted).isTranslated)
    }

    // A commit resets the translator in one turn and SwiftUI removes the button in the next; a tap between the two has
    // no language to run with and does nothing.
    @Test func aTapInTheTurnAfterAResetDoesNothing() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        try await loadFrench(hosted)
        let records = hosted.env.haptics.records.count

        hosted.controller.translator.reset()
        press(hosted)
        #expect(hosted.env.translation.configuration == nil)
        #expect(hosted.controller.translator.state == .idle)
        #expect(hosted.env.haptics.records.count == records)
    }

    // The tap rule, wired: a release after travel or after a hold requests nothing and records no haptic (the prepare
    // on touch-down records none); a short still release requests. The isSwiping arm is the pure test's, since the
    // hosted bar has no pager. A swipe that starts on the button is the bar's: its recognizer sits on the bar view
    // above the button's host and cancels the press as it begins.
    @Test func aReleaseAfterTravelOrAHoldIsNoTapAndAShortStillReleaseIs() async throws {
        let hosted = hosted()
        defer { hosted.window.isHidden = true }
        try await loadFrench(hosted)
        let records = hosted.env.haptics.records.count

        press(hosted, travel: CGSize(width: 30, height: 0))
        press(hosted, held: 0.4)
        #expect(hosted.env.translation.configuration == nil)
        #expect(hosted.controller.translator.state == .idle)
        #expect(hosted.env.haptics.records.count == records)

        press(hosted)
        #expect(hosted.env.translation.configuration?.source == Self.french)
        #expect(hosted.controller.translator.state == .translating)
        #expect(hosted.env.haptics.records.count == records + 1)
        #expect(hosted.bar.gestureRecognizers?.contains(where: { $0 is BarSwipeRecognizer }) == true)
    }
}
