import Foundation
import FoundationModels
import os

// A page's summary from the on-device model behind Apple Intelligence: a lead paragraph and two to four sections, each
// with a kind, a heading and a body, streamed as the model writes them. Where the model is unavailable the feature does
// not exist, so availability is read at the moment of use and never cached. A page longer than one request is
// summarized a chunk at a time in plain text, each chunk's request carrying the previous chunk's summary, and the
// structured summary is generated from the chunk summaries. The window is 4,096 tokens and tokenCount(for:) needs
// iOS 26.4, so the budget is an estimate. Permissive guardrails relax only String answers, so the chunk summaries never
// throw a guardrail violation while the structured summary can, and a page it refuses reads "No summary".
@Observable final class PageSummarizer {
    enum State: Equatable { case idle, summarizing(PageSummary), done(PageSummary), noSummary }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "summary")
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private static let chunkTokens = 300
    // A structured answer cut at its cap fails to decode, so the cap holds fifteen sentences in a character-per-token
    // language with room over.
    private static let summaryTokens = 900
    // The summary's schema rides in the prompt; this is its size with its guides, estimated.
    private static let schemaTokens = 250
    private static let maximumChunks = 8
    // Past this a title is no help to the summary, and it keeps a pathological one inside the window.
    private static let titleLength = 200
    private static let chunkOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: chunkTokens)
    private static let summaryOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: summaryTokens)
    private static let pageInstructions = """
        Summarize the page in its own language: a lead paragraph on what the page is, then two to four sections on \
        its main parts. Do not open with a line about the page.
        """
    private static let chunkInstructions = """
        Summarize this part of a page in three to five short sentences of plain prose, in its own language. \
        Text after "Earlier:" summarizes the part before it and is there only for context.
        """
    private static let combineInstructions = """
        These are summaries of consecutive parts of one page. Summarize the whole page from them in its own \
        language: a lead paragraph on what the page is, then two to four sections on its main parts. Do not open \
        with a line about the page.
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
        state = .summarizing(PageSummary(lead: "", sections: []))
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

    // The thrown error is the model's boundary: whatever it is, the page has no summary. A chunk's request holds the
    // chunk, the previous chunk's summary and its own; the page's holds the chunk, the schema and the summary.
    private func run(_ content: PageContent, in language: Locale.Language) async {
        let title = String(content.title.prefix(Self.titleLength))
        let perToken = Self.characterTokenLanguages.contains(language.languageCode?.identifier ?? "") ? 1 : 3
        let instructions = max(Self.pageInstructions.count, Self.chunkInstructions.count)
        let overhead = (instructions + title.count) / perToken + 1
        let budget = (Self.model.contextSize - overhead - Self.schemaTokens - Self.summaryTokens) * perToken
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
                summaries.append(
                    try await session.respond(to: Self.prompt(title, body), options: Self.chunkOptions).content)
                try Task.checkCancellation()
            }
            try await stream(Self.combineInstructions, Self.prompt(title, summaries.joined(separator: "\n\n")))
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Summary failed: \(error, privacy: .public)")
            state = .noSummary
        }
    }

    // The app is in front, so the last request streams; each snapshot is the summary so far, and a section shows once
    // its kind is written, which the model writes first.
    private func stream(_ instructions: String, _ prompt: String) async throws {
        let session = LanguageModelSession(model: Self.model, instructions: instructions)
        var summary = PageSummary(lead: "", sections: [])
        let responses = session.streamResponse(to: prompt, generating: PageSummary.self, options: Self.summaryOptions)
        for try await snapshot in responses {
            try Task.checkCancellation()
            let partial = snapshot.content
            summary = PageSummary(
                lead: partial.lead ?? "",
                sections: (partial.sections ?? []).compactMap { section in
                    section.kind.map {
                        PageSummary.Section(kind: $0, heading: section.heading ?? "", body: section.body ?? "")
                    }
                })
            state = .summarizing(summary)
        }
        try Task.checkCancellation()
        state = .done(summary)
    }

    private static func prompt(_ title: String, _ body: String) -> String {
        title.isEmpty ? body : "\(title)\n\n\(body)"
    }
}

@Generable struct PageSummary: Equatable {
    @Guide(description: "Two or three sentences on what the page is and its main point, in the page's own language")
    var lead: String
    @Guide(description: "The page's main parts", .minimumCount(2), .maximumCount(4))
    var sections: [Section]

    @Generable struct Section: Equatable {
        @Guide(description: "What this part is about")
        var kind: Kind
        @Guide(description: "A noun phrase of two or three words naming this part, in the page's own language")
        var heading: String
        @Guide(description: "One to three sentences on this part, in the page's own language")
        var body: String
    }

    @Generable enum Kind {
        case topics, people, dates, how, `where`, money, other
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
