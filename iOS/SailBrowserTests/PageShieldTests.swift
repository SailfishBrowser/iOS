import Foundation
import Testing
@testable import SailBrowser

struct PageShieldTests {
    @Test func aHostMatchesItsParentsAndCountryWildcards() {
        #expect(PageShield.keys(for: "www.deliveroo.co.uk")
            == ["", "www.deliveroo.co.uk", "deliveroo.co.uk", "deliveroo.*", "co.uk", "co.*", "uk"])
        #expect(PageShield.keys(for: "localhost") == ["", "localhost"])
    }

    @Test func theBundledDataCarriesTheYouTubeAdPruneAndCallsOnlyTheEightScriptlets() throws {
        #expect(Set(PageShieldScriptlets.functions.keys) == [
            "set-constant", "abort-on-property-read", "abort-current-inline-script", "json-prune", "remove-attr",
            "remove-class", "prevent-addEventListener", "prevent-setTimeout",
        ])
        var called: Set<String> = []
        for category in BlockingCategory.allCases {
            let rules = try JSONDecoder().decode(
                [String: PageShield.Rules].self,
                from: Data(contentsOf: try #require(Bundle.main.url(forResource: category.rawValue, withExtension: "json"))))
            called.formUnion(rules.values.flatMap { $0.scriptlets ?? [] }.map { $0[0] })
            if category == .ads {
                let youtube = try #require(rules["youtube.com"]?.scriptlets)
                #expect(youtube.contains { $0.first == "json-prune" && $0[1].contains("playerResponse.adPlacements") })
            }
        }
        #expect(called == Set(PageShieldScriptlets.functions.keys))
    }
}
