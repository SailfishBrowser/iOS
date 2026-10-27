import Foundation

nonisolated enum TrackingParams {
    private static let names: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_eid", "igsh", "igshid"]
    private static let youTubeHosts = ["youtube.com", "youtu.be"]

    static func strip(_ url: URL) -> URL {
        // A "?" in a data URL is data, not a query.
        guard url.isWebPage, var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = components.percentEncodedQueryItems else { return url }
        let stripsSi = components.host.map(isYouTube) == true
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !(name.hasPrefix("utm_") || names.contains(name) || (stripsSi && name == "si"))
        }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private static func isYouTube(_ host: String) -> Bool {
        let host = host.lowercased()
        return youTubeHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
