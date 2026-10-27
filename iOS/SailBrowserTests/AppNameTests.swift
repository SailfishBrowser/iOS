import Foundation
import Testing

struct AppNameTests {
    @Test func theHomeScreenNameIsSail() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Sail")
    }

    @Test func theBundleNameIsSailfish() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Sailfish")
    }

    // Every file the app ships, its code included, so a literal left in a view shows up here. The hosted test bundle
    // sits in PlugIns and is skipped.
    @Test func nothingTheAppShipsSaysAnOldName() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL).standardizedFileURL.path
        let files = try #require(FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: [.isRegularFileKey]))
        var hits: [String] = []
        for case let url as URL in files where !url.standardizedFileURL.path.hasPrefix(plugIns) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hits += Self.oldNames(in: try Data(contentsOf: url)).map { "\(url.lastPathComponent): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test func theSweepFindsTheOldNamesInAnyCase() {
        #expect(Self.oldNames(in: Data("built for tau browser".utf8)) == ["tau browser"])
        #expect(Self.oldNames(in: Data("TAU SCRUBBED 3".utf8)) == ["tau scrubbed"])
        #expect(Self.oldNames(in: Data("SailBrowser, Tau".utf8)).isEmpty)
    }

    // The old names in a file's bytes, any ASCII letter's case aside.
    private static func oldNames(in data: Data) -> [String] {
        let lowered = Data(data.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
        return ["tau browser", "tau scrubbed"].filter { lowered.range(of: Data($0.utf8)) != nil }
    }
}
