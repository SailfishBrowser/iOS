import Foundation
import Testing
import WebKit
@testable import SailBrowser

@Suite(.serialized)
struct ContentBlockerTests {
    @Test func bundledManifestListsExistingFilesUnderRuleLimit() throws {
        let manifest = BlocklistManifest.bundled(in: .main)
        #expect(manifest.lists == [
            .init(name: "easylist", category: .ads), .init(name: "annoyances", category: .ads),
            .init(name: "easyprivacy", category: .trackers), .init(name: "easylist-cookie", category: .cookieBanners),
        ])
        for list in manifest.lists {
            let url = try #require(Bundle.main.url(forResource: list.name, withExtension: "json"))
            let rules = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
            #expect((1_000..<150_000).contains(rules.count), "\(list.name) has \(rules.count) rules")
        }
    }

    @Test func prepareCompilesThenReusesCacheAndRemovesStale() async throws {
        let store: WKContentRuleListStore = WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)"))
        let stale = "easylist-2000.01.01"
        let rule = ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#ad"}}]"##
        _ = try await store.compileContentRuleList(forIdentifier: stale, encodedContentRuleList: rule)
        let blocker = ContentBlocker(categories: Set(BlockingCategory.allCases), store: store)
        let current = Set(blocker.manifest.lists.map(blocker.manifest.identifier(for:)))

        await blocker.prepare()
        #expect(blocker.isReady)
        #expect(Set(await store.availableIdentifiers() ?? []) == current)

        await blocker.prepare()
        #expect(Set(await store.availableIdentifiers() ?? []) == current)
    }
}
