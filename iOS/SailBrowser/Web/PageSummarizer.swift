import Foundation
import FoundationModels
import os

// A page's summary from the on-device model behind Apple Intelligence. Where the model is unavailable the feature does
// not exist, so availability is read at the moment of use and never cached. A page longer than one request is
// summarized a chunk at a time, each chunk's request carrying the previous chunk's summary, and the chunk summaries
// are then combined. The window is 4,096 tokens and tokenCount(for:) needs iOS 26.4, so the budget is an estimate.
// With permissive guardrails a String answer never throws a guardrail violation, but it can be a refusal sentence;
// a String gives no reliable way to tell one from a summary, so none is looked for.
@Observable final class PageSummarizer {
    enum State: Equatable { case idle, summarizing(String), done(String), noSummary }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "summary")
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private static let outputTokens = 300
    private static let maximumChunks = 8
    // Past this a title is no help to the summary, and it keeps a pathological one inside the window.
    private static let titleLength = 200
    private static let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: outputTokens)
    private static let pageInstructions = """
        Summarize the page in three to five short sentences of plain prose, in the page's own language. \
        Do not open with a line about the page.
        """
    private static let chunkInstructions = """
        Summarize this part of a page in three to five short sentences of plain prose, in its own language. \
        Text after "Earlier:" summarizes the part before it and is there only for context.
        """
    private static let combineInstructions = """
        These are summaries of consecutive parts of one page. Combine them into one summary of the page in three to \
        five short sentences of plain prose, in the page's own language. Do not open with a line about the page.
        """
    // Scripts written without spaces, and Vietnamese, count about a token per character ("Managing the context
    // window"); other languages about three characters a token.
    private static let characterTokenLanguages: Set<String> = ["zh", "ja", "ko", "th", "vi", "lo", "km", "my"]

    private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    static var isAvailable: Bool {
        model.isAvailable
    }

    func start(_ content: PageContent) {
        task?.cancel()
        guard !content.text.isEmpty, let language = content.language, Self.supports(language) else {
            task = nil
            state = .noSummary
            return
        }
        state = .summarizing("")
        task = Task { [weak self] in await self?.run(content, in: language) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    // A page's lang is usually regional (en-US), and Locale.Language equality includes the region, so the match is
    // the language code and the script.
    private static func supports(_ language: Locale.Language) -> Bool {
        model.supportedLanguages.contains { PageTranslator.isSame($0, language) }
    }

    // The thrown error is the model's boundary: whatever it is, the page has no summary.
    private func run(_ content: PageContent, in language: Locale.Language) async {
        let title = String(content.title.prefix(Self.titleLength))
        let perToken = Self.characterTokenLanguages.contains(language.languageCode?.identifier ?? "") ? 1 : 3
        let overhead = (Self.chunkInstructions.count + title.count) / perToken + 1
        let budget = (Self.model.contextSize - overhead - 2 * Self.outputTokens) * perToken
        let chunks = SummaryChunks.split(content.text, budget: budget).prefix(Self.maximumChunks)
        do {
            if chunks.count == 1 {
                try await stream(Self.pageInstructions, Self.prompt(title, chunks[0]))
                return
            }
            var summaries: [String] = []
            for chunk in chunks {
                let session = LanguageModelSession(model: Self.model, instructions: Self.chunkInstructions)
                let body = summaries.last.map { "Earlier: \($0)\n\n\(chunk)" } ?? chunk
                summaries.append(try await session.respond(to: Self.prompt(title, body), options: Self.options).content)
                try Task.checkCancellation()
            }
            try await stream(Self.combineInstructions, Self.prompt(title, summaries.joined(separator: "\n\n")))
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Summary failed: \(error, privacy: .public)")
            state = .noSummary
        }
    }

    // The app is in front, so the last request streams; each snapshot is the text so far.
    private func stream(_ instructions: String, _ prompt: String) async throws {
        let session = LanguageModelSession(model: Self.model, instructions: instructions)
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt, options: Self.options) {
            try Task.checkCancellation()
            text = snapshot.content
            state = .summarizing(text)
        }
        try Task.checkCancellation()
        state = .done(text)
    }

    private static func prompt(_ title: String, _ body: String) -> String {
        title.isEmpty ? body : "\(title)\n\n\(body)"
    }
}

// A page's text cut into chunks of at most `budget` characters: at line breaks, then at sentence breaks inside a
// paragraph longer than the budget, then at the budget inside a sentence longer than it.
nonisolated enum SummaryChunks {
    static func split(_ text: String, budget: Int) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var length = 0
        for paragraph in text.split(separator: "\n") {
            for piece in pieces(of: String(paragraph), budget: budget) {
                if length > 0, length + 1 + piece.count > budget {
                    chunks.append(chunk)
                    chunk = ""
                    length = 0
                }
                chunk += length == 0 ? piece : "\n" + piece
                length += (length == 0 ? 0 : 1) + piece.count
            }
        }
        if length > 0 {
            chunks.append(chunk)
        }
        return chunks
    }

    private static func pieces(of paragraph: String, budget: Int) -> [String] {
        guard paragraph.count > budget else { return [paragraph] }
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            sentences.append(sentence!.trimmingCharacters(in: .whitespaces))
        }
        return sentences.flatMap { sentence in
            guard sentence.count > budget else { return [sentence] }
            let characters = Array(sentence)
            return stride(from: 0, to: characters.count, by: budget).map {
                String(characters[$0..<min($0 + budget, characters.count)])
            }
        }
    }
}
