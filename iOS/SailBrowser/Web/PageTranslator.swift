import NaturalLanguage
import os
import SwiftUI
import Translation
import WebKit

nonisolated struct PageText: Equatable, Sendable {
    let id: String
    let text: String
}

// The Translation framework's session, behind a seam: the real one needs the languages installed on the device. The
// session is not Sendable, so it never enters the main actor: it is used only from nonisolated code.
nonisolated protocol PageTranslationSession {
    @concurrent func prepareTranslation() async throws
    @concurrent func translate(_ batch: [PageText]) async throws -> [PageText]
}

nonisolated extension TranslationSession: PageTranslationSession {
    @concurrent func translate(_ batch: [PageText]) async throws -> [PageText] {
        try await translations(from: batch.map { Request(sourceText: $0.text, clientIdentifier: $0.id) })
            .map { PageText(id: $0.clientIdentifier!, text: $0.targetText) }
    }
}

// Translates a page in place, text node by text node, and keeps the originals so they can be put back without a
// reload. Context across inline tags is lost, and text the page adds afterwards or shows in frames stays as it was.
@Observable final class PageTranslator {
    enum State: Equatable {
        case idle, translating, translated(from: Locale.Language, to: Locale.Language), failed
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "translate")
    private static let world = WKContentWorld.world(name: "translate")
    private static let script = try! String(
        contentsOf: Bundle.main.url(forResource: "translate", withExtension: "js")!, encoding: .utf8)
    nonisolated private static let batchSize = 100
    // Below this the recognizer is guessing: one letter reads as Hungarian at 0.4, while a sentence reads at 0.99.
    private static let recognitionConfidence = 0.9

    private(set) var state = State.idle
    // The page's language when it can be translated to the target; nil hides the row.
    private(set) var source: Locale.Language?
    let target: Locale.Language

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let isSupported: (Locale.Language, Locale.Language) async -> Bool
    @ObservationIgnored private var page = 0

    nonisolated struct Run: Sendable {
        let page: Int
        let source: Locale.Language
    }

    init(
        webView: WKWebView, target: Locale.Language,
        isSupported: @escaping (Locale.Language, Locale.Language) async -> Bool
    ) {
        self.webView = webView
        self.target = target
        self.isSupported = isSupported
    }

    static func isAvailable(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) != .unsupported
    }

    static func isSame(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
            && Locale.Language(identifier: a.maximalIdentifier).script
                == Locale.Language(identifier: b.maximalIdentifier).script
    }

    // A page that comes back from the back-forward cache still shows its translation; otherwise the page's lang
    // attribute, else the language its text reads as.
    func detect() async {
        let page = page
        do {
            let sample = try await call("sample(\(Theme.Translate.sampleLength))") as! [String: Any]
            guard page == self.page else { return }
            if let from = sample["from"] as? String {
                source = Locale.Language(identifier: from)
                state = .translated(from: source!, to: target)
                return
            }
            let lang = sample["lang"] as! String
            let language =
                lang.isEmpty ? Self.recognizedLanguage(sample["text"] as! String) : Locale.Language(identifier: lang)
            guard let language, !Self.isSame(language, target), await isSupported(language, target),
                page == self.page
            else { return }
            source = language
        } catch {
            Self.logger.error("Language detection failed: \(error, privacy: .public)")
        }
    }

    // The tap: the run belongs to this page and its language, whenever the session starts.
    func begin() -> Run {
        state = .translating
        return Run(page: page, source: source!)
    }

    @concurrent nonisolated func translate(_ run: Run, using session: some PageTranslationSession) async {
        do {
            try await check(run.page)
            try await session.prepareTranslation()
            try await check(run.page)
            let texts = try await collect()
            try await check(run.page)
            for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
                let results = try await session.translate(Array(texts[start..<min(start + Self.batchSize, texts.count)]))
                try await check(run.page)
                try await apply(results)
                try await check(run.page)
            }
            try await finish(run)
        } catch {
            await stop(run.page, error)
        }
    }

    func showOriginal() async {
        await putBack()
        state = .idle
    }

    // A main-frame navigation: whatever is in flight belongs to the page that left.
    func reset() {
        page += 1
        state = .idle
        source = nil
    }

    func collect() async throws -> [PageText] {
        let texts = try await call("collect()") as! [[String: String]]
        return texts.map { PageText(id: $0["id"]!, text: $0["text"]!) }
    }

    func apply(_ results: [PageText]) async throws {
        _ = try await call("apply(results)", ["results": results.map { ["id": $0.id, "text": $0.text] }])
    }

    func mark(_ source: Locale.Language) async throws {
        _ = try await call("mark(from)", ["from": source.minimalIdentifier])
    }

    func restore() async throws {
        _ = try await call("restore()")
    }

    private func finish(_ run: Run) async throws {
        try await mark(run.source)
        try check(run.page)
        state = .translated(from: run.source, to: target)
    }

    // A cancelled run is not a failure: it puts its own page back and reads Translate again, quietly.
    private func stop(_ page: Int, _ error: any Error) async {
        guard page == self.page else { return }
        if Task.isCancelled {
            state = .idle
        } else {
            Self.logger.error("Translation failed: \(error, privacy: .public)")
            state = .failed
        }
        await putBack()
    }

    private func putBack() async {
        do {
            try await restore()
        } catch {
            Self.logger.error("Restoring the original text failed: \(error, privacy: .public)")
        }
    }

    private func check(_ page: Int) throws {
        try Task.checkCancellation()
        if page != self.page {
            throw CancellationError()
        }
    }

    private func call(_ function: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            "\(Self.script)\nreturn sailTranslate.\(function);", arguments: arguments, in: nil, contentWorld: Self.world)
    }

    private static func recognizedLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let best = recognizer.languageHypotheses(withMaximum: 1).first
        guard let best, best.value >= recognitionConfidence else { return nil }
        return Locale.Language(identifier: best.key.rawValue)
    }
}

// The one session host: the menu closes when Translate is tapped, so the session lives on the root view. One run at a
// time: a request made while another tab translates waits its turn rather than cancelling that run.
@Observable final class TranslationHost {
    private struct Request {
        let translator: PageTranslator
        let run: PageTranslator.Run
    }

    private(set) var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var current: Request?

    func request(_ translator: PageTranslator) {
        queue.append(Request(translator: translator, run: translator.begin()))
        if current == nil {
            startNext()
        }
    }

    @concurrent nonisolated func run(_ session: some PageTranslationSession) async {
        let request = await current!
        await request.translator.translate(request.run, using: session)
        await finished()
    }

    private func finished() {
        current = nil
        startNext()
    }

    private func startNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let target = next.translator.target
        if configuration?.source == next.run.source, configuration?.target == target {
            configuration!.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: next.run.source, target: target)
        }
    }
}
