import Testing
import UIKit
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct ReaderViewTests {
    private static let probe = ReaderArticle(
        title: "Probe", byline: nil,
        html: """
            <p>Text</p><script>document.title = 'ran'</script>\
            <img src="data:image/png;base64,AAAA" onerror="document.title = 'ran'">\
            <a id="out" href="https://example.test/next">Next</a> <a id="note" href="#note-1">1</a>
            """,
        lang: nil, dir: nil)

    @Test func theReaderPageRunsNoPageScriptAndKeepsNoData() {
        let configuration = ReaderController.configuration(ruleLists: [])
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

    @Test func theShellCarriesThePolicyTheStylesheetAndEscapedText() {
        let article = ReaderArticle(
            title: "A <b>&</b>", byline: "By \"Q\"", html: "<p>Body</p>", lang: "fr", dir: "rtl")
        let document = ReaderController.document(for: article)
        #expect(document.contains(
            #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">"#))
        #expect(document.contains("<style>\(ReaderController.stylesheet)</style>"))
        #expect(document.contains("<title>A &lt;b&gt;&amp;&lt;/b&gt;</title>"))
        #expect(document.contains("By &quot;Q&quot;"))
        #expect(document.contains(#"<html lang="fr" dir="rtl">"#))
        #expect(document.contains("<p>Body</p>"))
        #expect(document.range(of: "Content-Security-Policy")!.lowerBound < document.range(of: "<p>Body</p>")!.lowerBound)
    }

    // The stylesheet is reader.css with the Theme's reader tokens substituted at load, every placeholder filled.
    @Test func theStylesheetCarriesTheThemesReaderTokens() {
        let css = ReaderController.stylesheet
        for font in [Theme.Typography.readerBody, Theme.Typography.readerTitle] {
            #expect(css.contains("font: \(font.weight) \(Int(font.size))px \(font.family);"))
        }
        #expect(css.contains("max-width: \(Int(Theme.Metrics.readerMeasure))px;"))
        #expect(css.contains("padding: 0 \(Int(Theme.Metrics.readerInset))px;"))
        #expect(css.contains("color-scheme: light dark;"))
        #expect(!css.contains("{{"))
    }

    private func rgba(_ color: UIColor, in view: UIView) -> [CGFloat] {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.resolvedColor(with: view.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    // The page paints opaque in the reader's own background, so a scroll frame blends nothing; what shows until the
    // article paints, and past its ends, is that same colour.
    @Test func theReaderPageIsOpaqueInTheReaderBackground() throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        reader.present(Self.probe, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        #expect(page.isOpaque)
        #expect(page.backgroundColor == Theme.Palette.readerBackground)
        #expect(rgba(page.underPageBackgroundColor, in: page) == rgba(Theme.Palette.readerBackground, in: page))
    }

    @Test func scriptsInTheArticleNeverRun() async throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        reader.present(Self.probe, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil { !page.isLoading && page.title == "Probe" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(page.title == "Probe")
    }

    @Test func aLinkOpensInTheTabAndAnInPageLinkStaysInTheReader() async throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let opened = Recorded<URL>()
        reader.onOpen = { opened.values.append($0) }
        reader.present(Self.probe, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil { !page.isLoading && page.title == "Probe" }

        _ = try await page.callAsyncJavaScript("document.getElementById('note').click()", contentWorld: .defaultClient)
        try await waitUntil { page.url?.fragment == "note-1" }
        #expect(opened.values.isEmpty)

        _ = try await page.callAsyncJavaScript("document.getElementById('out').click()", contentWorld: .defaultClient)
        try await waitUntil { !opened.values.isEmpty }
        #expect(opened.values == [URL(string: "https://example.test/next")!])
        #expect(page.url?.absoluteString == "https://example.test/a#note-1")
    }

    @Test func theReaderPageTakesTheZoomAndTheTabsInsets() {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let insets = UIEdgeInsets(top: 62, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)
        reader.present(Self.probe, baseURL: nil, zoom: 1.25, insets: insets, ruleLists: [])
        let page = reader.page!
        #expect(page.pageZoom == 1.25)
        #expect(page.obscuredContentInsets == insets)
        #expect(page.scrollView.contentInset == insets)
        reader.setZoom(0.9)
        #expect(page.pageZoom == 0.9)
    }

    // Taken during its rise like the search sheet: past the line it closes, short of it the reader stays.
    @Test(arguments: [(90.0, Interaction.readerDragDismiss, false), (40.0, .readerDragReturn, true)])
    func aGrabDuringTheRiseDecidesOnTheFinger(height: CGFloat, release: Interaction, staysOpen: Bool) {
        let haptics = recordingHaptics()
        let (reader, window) = shownReader(haptics: haptics)
        defer { window.isHidden = true }
        let shown = Recorded<ReaderArticle?>()
        reader.onShown = { shown.values.append($0) }
        reader.present(Self.probe, baseURL: nil, zoom: 1, insets: .zero, ruleLists: [])
        #expect(reader.motion != nil)

        reader.dragBegan()
        reader.dragChanged(height)
        reader.dragEnded(translation: height, velocity: 0)

        #expect(reader.isOpen == staysOpen)
        #expect(shown.values == (staysOpen ? [] : [nil]))
        let record = haptics.records.last!
        #expect(record.interaction == release)
        #expect(!record.played)
    }

    // A reader taken during its close and held short of the line comes back, with its article.
    @Test func aGrabDuringTheCloseCanBringItBack() {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let shown = Recorded<ReaderArticle?>()
        reader.onShown = { shown.values.append($0) }
        reader.present(Self.probe, baseURL: nil, zoom: 1, insets: .zero, ruleLists: [])
        reader.dismiss()
        #expect(!reader.isOpen)

        reader.dragBegan()
        reader.dragChanged(-10)
        reader.dragEnded(translation: -10, velocity: 0)

        #expect(reader.isOpen)
        #expect(shown.values == [Self.probe])
    }

    @Test func atRestTheReaderIsHiddenAndTakesNoTouch() {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        #expect(reader.container.isHidden)
        #expect(reader.motion == nil)
        #expect(reader.view.hitTest(CGPoint(x: 10, y: 400), with: TouchEvent()) == nil)
    }

    private func shownReader(haptics: HapticsEngine = recordingHaptics()) -> (ReaderController, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let reader = ReaderController(haptics: haptics)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        return (reader, window)
    }

    private func drawnOffset(_ reader: ReaderController) -> CGFloat {
        reader.container.layer.presentation()!.affineTransform().ty
    }

    // A point on the drawn reader, 40 pt below its drawn top.
    private func onDrawnReader(_ reader: ReaderController) -> CGPoint {
        CGPoint(x: reader.view.bounds.midX, y: reader.container.layer.presentation()!.frame.minY + 40)
    }

    // Once its first frame is drawn, so the drawn reader can be read.
    private func rising() async throws -> (ReaderController, UIWindow) {
        let (reader, window) = shownReader()
        reader.present(Self.probe, baseURL: nil, zoom: 1, insets: .zero, ruleLists: [])
        try await waitUntil { reader.container.layer.presentation() != nil }
        return (reader, window)
    }

    // A touch-down on the rising reader holds it where it is drawn, in the touch's own hit test, so the article under
    // the finger takes the touch. Let go without a drag, the reader finishes its rise on the open's spring.
    @Test(.timeLimit(.minutes(1)), arguments: [0.3, 0.6])
    func aTouchDownMidRiseHoldsTheReaderWhereItIsDrawn(_ fraction: CGFloat) async throws {
        let (reader, window) = try await rising()
        defer { window.isHidden = true }
        let height = reader.view.bounds.height
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(reader) <= (1 - fraction) * height }
        #expect(drawnOffset(reader) > 0.1 * height)
        let drawn = drawnOffset(reader)
        let hit = try #require(reader.view.hitTest(onDrawnReader(reader), with: TouchEvent()))
        #expect(hit.isDescendant(of: reader.container))
        #expect(reader.container.layer.animationKeys() == nil)
        #expect(abs(reader.container.transform.ty - drawn) < 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(abs(drawnOffset(reader) - reader.container.transform.ty) < 0.5)

        reader.catchEnded()
        let rise = try #require(reader.container.layer.animation(forKey: "transform") as? CASpringAnimation)
        #expect(abs(rise.stiffness - Theme.Motion.readerOpen.spring.stiffness) < 0.01)
        try await waitUntil { reader.container.layer.animationKeys() == nil }
        #expect(abs(drawnOffset(reader)) < 0.5)
        #expect(reader.isOpen)
    }

    // A caught reader is still a moving one: a drag either way from the catch begins and moves it from where it is held,
    // and the finger's rate is voted for until the release.
    @Test(.timeLimit(.minutes(1)), arguments: [-40.0, 40.0])
    func aDragFromACatchMovesTheReaderFromWhereItIsHeld(_ travel: CGFloat) async throws {
        let (reader, window) = try await rising()
        defer { window.isHidden = true }
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(reader) <= 0.5 * reader.view.bounds.height }
        _ = reader.view.hitTest(onDrawnReader(reader), with: TouchEvent())
        let held = reader.container.transform.ty
        let pan = ReaderScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 10, y: travel * 10)
        #expect(reader.gestureRecognizerShouldBegin(pan))

        reader.dragBegan()
        #expect(reader.presence != nil)
        reader.dragChanged(travel)
        #expect(abs(reader.container.transform.ty - (held + travel)) < 0.5)
        reader.dragEnded(translation: travel, velocity: 0)
        #expect(reader.presence == nil)
    }

    // A catch let go without a drag is spent once the reader rises from it: at rest no drag begins and a tap's release
    // starts no spring, so the article scrolls.
    @Test(.timeLimit(.minutes(1)))
    func aReleasedCatchLeavesTheSettledReaderAtRest() async throws {
        let (reader, window) = try await rising()
        defer { window.isHidden = true }
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(reader) <= 0.5 * reader.view.bounds.height }
        _ = reader.view.hitTest(onDrawnReader(reader), with: TouchEvent())
        reader.catchEnded()
        try await waitUntil { reader.container.layer.animationKeys() == nil && reader.motion == nil }
        #expect(!reader.gestureRecognizerShouldBegin(reader.catcher))
        let pan = ReaderScriptedPan()
        pan.scriptedVelocity = CGPoint(x: 10, y: 400)
        #expect(!reader.gestureRecognizerShouldBegin(pan))
        let hit = reader.view.hitTest(onDrawnReader(reader), with: TouchEvent())
        #expect(hit.map { $0.isDescendant(of: reader.page!) } == true)
        reader.catchEnded()
        #expect(reader.container.layer.animationKeys() == nil)
    }

    // Above the drawn rising reader the page has the touch.
    @Test func aTouchAboveTheRisingReaderGoesToThePage() async throws {
        let (reader, window) = try await rising()
        defer { window.isHidden = true }
        try await waitUntil(timeout: .seconds(1)) { drawnOffset(reader) <= 0.5 * reader.view.bounds.height }
        #expect(reader.view.hitTest(CGPoint(x: 10, y: 10), with: TouchEvent()) == nil)
        #expect(reader.motion != nil)
    }

    // An article's meta refresh never navigates the reader's page.
    @Test func aMetaRefreshInTheArticleIsRefused() async throws {
        let (reader, window) = shownReader()
        defer { window.isHidden = true }
        let article = ReaderArticle(
            title: "Refresh", byline: nil,
            html: #"<meta http-equiv="refresh" content="0;url=https://example.test/elsewhere"><p>Text</p>"#,
            lang: nil, dir: nil)
        reader.present(article, baseURL: URL(string: "https://example.test/a"), zoom: 1, insets: .zero, ruleLists: [])
        let page = try #require(reader.page)
        try await waitUntil { !page.isLoading && page.title == "Refresh" }
        try await Task.sleep(for: .milliseconds(500))
        #expect(page.url?.absoluteString == "https://example.test/a")
    }

    // A closed reader lets its page go, freed, so the next article is built under the lists of its own moment.
    @Test func aClosedReaderReleasesItsPage() async throws {
        let (reader, window) = try await rising()
        defer { window.isHidden = true }
        weak var page = reader.page
        #expect(page != nil)
        reader.dismiss()
        try await waitUntil { reader.page == nil }
        #expect(reader.container.isHidden)
        try await waitUntil { page == nil }
    }
}

private final class ReaderScriptedPan: UIPanGestureRecognizer {
    var scriptedVelocity = CGPoint.zero

    override func velocity(in view: UIView?) -> CGPoint { scriptedVelocity }
}

final class Recorded<Value> {
    var values: [Value] = []
}
