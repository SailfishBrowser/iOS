import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PageTranslatorTests {
    private static let french = Locale.Language(identifier: "fr")
    private static let english = Locale.Language(identifier: "en")

    private static let fixture = """
        <html lang="fr"><body>
        <h1>Bonjour</h1>
        <p>Le <b>chat</b> dort.</p>
        <script>var x = "script";</script>
        <style>p { color: red }</style>
        <code>let code = 1</code>
        <p translate="no">Marque</p>
        <p style="display:none">Cach\u{E9}</p>
        <div contenteditable>Editable</div>
        <textarea>Zone</textarea>
        <noscript>Rien</noscript>
        <pre>pre</pre>
        <p>  Fin  </p>
        </body></html>
        """

    private func loaded(_ html: String) async -> WebTabController {
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics(), isTranslationSupported: { _, _ in true })
        await loadAndFinish(controller, html: html, base: "https://example.test/")
        return controller
    }

    private func translator(
        for controller: WebTabController, supported: Bool = true, target: Locale.Language = english
    ) -> PageTranslator {
        PageTranslator(webView: controller.webView, target: target) { _, _ in supported }
    }

    private func pageText(_ controller: WebTabController, _ script: String) async throws -> String {
        try await controller.webView.evaluateJavaScript(script) as! String
    }

    @Test func collectSkipsCodeAndHiddenTextAndKeepsDocumentOrder() async throws {
        let controller = await loaded(Self.fixture)
        let texts = try await translator(for: controller).collect()
        #expect(texts.map(\.text) == ["Bonjour", "Le", "chat", "dort.", "Fin"])
        #expect(Set(texts.map(\.id)).count == texts.count)
    }

    private func sample(_ controller: WebTabController) async throws -> String? {
        let translator = translator(for: controller)
        await translator.detect()
        let text = try await controller.webView.evaluateJavaScript(
            "sailTranslate.sample(\(Theme.Translate.sampleLength)).text", in: nil,
            contentWorld: WKContentWorld.world(name: "translate"))
        return text as? String
    }

    // The sample read for language detection is the text the page would translate, gathered node by node up to
    // Theme.Translate.sampleLength characters: never the body's innerText, which serialises a huge page after every
    // load.
    @Test func theSampleIsTheTranslatableTextUpToTheSampleLength() async throws {
        #expect(Theme.Translate.sampleLength == 2000)
        #expect(try await sample(await loaded(Self.fixture)) == "Bonjour Le chat dort. Fin")

        let paragraphs = (0..<300).map { "<p>mot \($0)</p>" }.joined()
        let long = try await sample(await loaded("<html lang=\"fr\"><body>\(paragraphs)</body></html>"))
        #expect(long?.count == Theme.Translate.sampleLength)
        #expect(long?.hasPrefix("mot 0 mot 1 mot 2 ") == true)
    }

    @Test func applyKeepsSpacingAndRestorePutsTheExactTextBack() async throws {
        let controller = await loaded(Self.fixture)
        let original = try await pageText(controller, "document.body.innerHTML")
        let translator = translator(for: controller)
        let texts = try await translator.collect()
        let english = ["Hello", "The", "cat", "sleeps.", "End"]
        try await translator.apply(zip(texts, english).map { PageText(id: $0.id, text: $1) })
        #expect(try await pageText(controller, "document.querySelector('p').textContent") == "The cat sleeps.")
        #expect(try await pageText(controller, "document.querySelector('h1').textContent") == "Hello")

        try await translator.restore()
        #expect(try await pageText(controller, "document.body.innerHTML") == original)
    }

    @Test func translatesInBatchesAndMapsEachResultToItsNodeById() async throws {
        let paragraphs = (0..<250).map { "<p>mot \($0)</p>" }.joined()
        let controller = await loaded("<html lang=\"fr\"><body>\(paragraphs)</body></html>")
        let translator = translator(for: controller)
        await translator.detect()
        let session = RecordingSession()

        await translator.translate(translator.begin(), using: session)
        #expect(session.batches.map(\.count) == [100, 100, 50])
        #expect(session.prepared)
        let shown = try await pageText(
            controller, "[...document.querySelectorAll('p')].map(p => p.textContent).join('|')")
        #expect(shown == (0..<250).map { "t:mot \($0)" }.joined(separator: "|"))
        #expect(translator.state == .translated(from: Self.french, to: Self.english))

        await translator.showOriginal()
        #expect(translator.state == .idle)
        let restored = try await pageText(
            controller, "[...document.querySelectorAll('p')].map(p => p.textContent).join('|')")
        #expect(restored == (0..<250).map { "mot \($0)" }.joined(separator: "|"))
    }

    @Test func aFailedBatchRestoresThePageAndFails() async throws {
        let paragraphs = (0..<150).map { "<p>mot \($0)</p>" }.joined()
        let controller = await loaded("<html lang=\"fr\"><body>\(paragraphs)</body></html>")
        let original = try await pageText(controller, "document.body.innerHTML")
        let translator = translator(for: controller)
        await translator.detect()

        await translator.translate(translator.begin(), using: RecordingSession(failingAfter: 1))
        #expect(translator.state == .failed)
        #expect(try await pageText(controller, "document.body.innerHTML") == original)
    }

    @Test func aNavigationDuringTranslatingStopsApplyingToTheNewPage() async throws {
        let controller = await loaded("<html lang=\"fr\"><body><p>un</p><p>deux</p></body></html>")
        try await waitUntil { controller.translator.source != nil }
        let session = GatedSession()
        let run = controller.translator.begin()
        let running = Task { await controller.translator.translate(run, using: session) }
        try await waitUntil { session.isWaiting }
        #expect(controller.translator.state == .translating)

        await loadAndFinish(controller, html: "<p>new</p>", base: "https://other.test/")
        #expect(controller.translator.state == .idle)
        session.release()
        await running.value
        #expect(controller.translator.state == .idle)
        #expect(try await pageText(controller, "document.body.textContent") == "new")
    }

    // A commit between the tap and the session's start: the run belongs to the page that left.
    @Test func aNavigationBeforeTheSessionStartsLeavesTheNewPageAlone() async throws {
        let controller = await loaded("<html lang=\"fr\"><body><p>un</p></body></html>")
        try await waitUntil { controller.translator.source != nil }
        let run = controller.translator.begin()
        #expect(controller.translator.state == .translating)

        await loadAndFinish(controller, html: "<html lang=\"de\"><body><p>neu</p></body></html>", base: "https://b.test/")
        let session = RecordingSession()
        await controller.translator.translate(run, using: session)
        #expect(session.batches.isEmpty)
        #expect(!session.prepared)
        #expect(controller.translator.state == .idle)
        #expect(try await pageText(controller, "document.body.textContent") == "neu")
    }

    // Going back to a page held in WebKit's back-forward cache commits and finishes it again with its document as it
    // was: still translated. A page loaded from a string has no entry to go back to, so these pages come from requests.
    @Test func aPageBackFromTheCacheStillReadsAsTranslated() async throws {
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(), haptics: recordingHaptics(), isTranslationSupported: { _, _ in true })
        await finishing(controller) {
            controller.webView.loadSimulatedRequest(
                URLRequest(url: URL(string: "https://a.test/")!),
                responseHTML: "<html lang=\"fr\"><body><p>un</p><p>deux</p></body></html>")
        }
        try await waitUntil { controller.translator.source != nil }
        await controller.translator.translate(controller.translator.begin(), using: RecordingSession())
        #expect(controller.translator.state == .translated(from: Self.french, to: controller.translator.target))

        await finishing(controller) {
            controller.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://b.test/")!), responseHTML: "<p>b</p>")
        }
        #expect(controller.translator.state == .idle)
        await finishing(controller) { controller.goBack() }
        try await waitUntil { controller.translator.source != nil }
        #expect(try await pageText(controller, "document.body.textContent") == "t:unt:deux")
        #expect(controller.translator.state == .translated(from: Self.french, to: controller.translator.target))

        await controller.translator.showOriginal()
        #expect(try await pageText(controller, "document.body.textContent") == "undeux")
    }

    private func finishing(_ controller: WebTabController, _ navigate: () -> Void) async {
        await withCheckedContinuation { continuation in
            controller.onFinish = { _, _ in
                controller.onFinish = nil
                continuation.resume()
            }
            navigate()
        }
    }

    // A commit just as a run finishes: the mark meant for the old page reaches the new one, which holds no collected
    // text, so it stays unmarked and reads as its own language.
    @Test func aMarkOnAPageWithNothingCollectedLeavesItUntranslated() async throws {
        let controller = await loaded("<html lang=\"de\"><body><p>eins</p></body></html>")
        let translator = translator(for: controller)
        try await translator.mark(Self.french)
        await translator.detect()
        #expect(translator.source == Locale.Language(identifier: "de"))
        #expect(translator.state == .idle)
    }

    @Test func aCancelledRunIsNotAFailureAndPutsItsPageBack() async throws {
        let controller = await loaded("<html lang=\"fr\"><body><p>un</p></body></html>")
        let translator = translator(for: controller)
        await translator.detect()
        let session = GatedSession()
        let running = Task { await translator.translate(translator.begin(), using: session) }
        try await waitUntil { session.isWaiting }

        running.cancel()
        session.release()
        await running.value
        #expect(translator.state == .idle)
        #expect(try await pageText(controller, "document.body.textContent") == "un")
    }

    @Test func detectReadsTheLangAttributeElseTheText() async {
        let tagged = await loaded("<html lang=\"fr\"><body><p>x</p></body></html>")
        let fromTag = translator(for: tagged)
        await fromTag.detect()
        #expect(fromTag.source == Self.french)

        let prose = "Le chat dort sur le canap\u{E9} pendant que la pluie tombe doucement sur la ville."
        let untagged = await loaded("<html><body><p>\(prose)</p><p>\(prose)</p></body></html>")
        let fromText = translator(for: untagged)
        await fromText.detect()
        #expect(fromText.source?.languageCode == Self.french.languageCode)

        // One letter reads as Hungarian at 40%: a guess, not a language.
        let letter = await loaded("<p>a</p>")
        let fromLetter = translator(for: letter)
        await fromLetter.detect()
        #expect(fromLetter.source == nil)
    }

    @Test func noOfferForTheSameLanguageOrAnUnsupportedPair() async {
        let british = await loaded("<html lang=\"en-GB\"><body><p>colour</p></body></html>")
        let same = translator(for: british, target: Locale.Language(identifier: "en-US"))
        await same.detect()
        #expect(same.source == nil)

        let french = await loaded("<html lang=\"fr\"><body><p>x</p></body></html>")
        let unsupported = translator(for: french, supported: false)
        await unsupported.detect()
        #expect(unsupported.source == nil)
    }

    @Test func sameLanguageComparesLanguageAndScript() {
        #expect(PageTranslator.isSame(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en-GB")))
        #expect(!PageTranslator.isSame(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
        #expect(!PageTranslator.isSame(Self.french, Self.english))
    }

    @Test func rowReadsTheStateAndTheLanguages() {
        let look = { (state: PageTranslator.State) in
            TranslateRow.look(state, source: Self.french, target: Self.english)
        }
        #expect(look(.idle) == TranslateRow.Look(title: "Translate", detail: "English", isEnabled: true))
        #expect(look(.failed) == TranslateRow.Look(title: "Translate", detail: "English", isEnabled: true))
        #expect(look(.translating) == TranslateRow.Look(title: "Translate", detail: nil, isEnabled: false))
        #expect(
            look(.translated(from: Self.french, to: Self.english))
                == TranslateRow.Look(title: "Show Original", detail: "French", isEnabled: true))
    }

    @Test func aRepeatedPairInvalidatesTheConfiguration() async {
        let controller = await loaded("<html lang=\"fr\"><body><p>x</p></body></html>")
        let translator = translator(for: controller)
        await translator.detect()
        let host = TranslationHost()
        host.request(translator)
        let first = host.configuration
        #expect(first?.source == Self.french)
        #expect(first?.target == Self.english)
        await host.run(RecordingSession())

        await translator.showOriginal()
        host.request(translator)
        #expect(host.configuration?.version != first?.version)
        #expect(host.configuration?.source == Self.french)
    }

    // One session at a time: a second tab's request waits for the first run instead of cancelling it.
    @Test func aSecondTabsRequestWaitsForTheFirstRun() async {
        let french = translator(for: await loaded("<html lang=\"fr\"><body><p>un</p></body></html>"))
        let german = translator(for: await loaded("<html lang=\"de\"><body><p>eins</p></body></html>"))
        await french.detect()
        await german.detect()
        let host = TranslationHost()
        host.request(french)
        host.request(german)
        #expect(host.configuration?.source == Self.french)
        #expect(german.state == .translating)

        await host.run(RecordingSession())
        #expect(french.state == .translated(from: Self.french, to: Self.english))
        #expect(host.configuration?.source == Locale.Language(identifier: "de"))
        await host.run(RecordingSession())
        #expect(german.state == .translated(from: Locale.Language(identifier: "de"), to: Self.english))
    }
}
