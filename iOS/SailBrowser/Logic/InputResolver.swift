import Foundation

nonisolated enum InputResolver {
    private static let passthroughSchemes: Set<String> = ["http", "https", "about", "data"]

    // Nil only for blank text. Stray characters in an address are percent-encoded and an IDN host goes to punycode;
    // an address that still does not parse (a space in the host) is searched for as typed, so Return always acts.
    static func resolve(_ text: String, engine: SearchEngine) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let url = address(input).flatMap { URL(string: $0) }
        return url ?? engine.resultsURL(for: input)
    }

    // The typed text as an address, or nil when it reads as a search.
    private static func address(_ input: String) -> String? {
        if let colon = input.firstIndex(of: ":"), passthroughSchemes.contains(input[..<colon].lowercased()) {
            return input
        }
        guard !input.contains(where: \.isWhitespace) else { return nil }

        let authority = input.prefix { !"/?#".contains($0) }
        let hostAndPort = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = hostAndPort[0]
        guard hostAndPort.count == 1 || isPort(hostAndPort[1]) else { return nil }

        if host.lowercased() == "localhost" || isIPv4(host) {
            return "http://" + input
        }
        return isDomain(host) ? "https://" + input : nil
    }

    private static func isPort(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isASCIIDigit)
    }

    private static func isIPv4(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy(\.isASCIIDigit) && Int(part).map { $0 <= 255 } == true
        }
    }

    // Labels are letters, digits and inner hyphens, as DNS has them: "-a.com" and "a-.com" are searches.
    private static func isDomain(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
