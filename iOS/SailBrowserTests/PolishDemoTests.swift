import Testing
@testable import SailBrowser

#if DEBUG
@MainActor
struct PolishDemoTests {
    @Test func setsCoverEveryInteractionOnce() {
        let scripted = Set(PolishDemo.script)
        #expect(scripted.isDisjoint(with: PolishDemo.covered))
        #expect(scripted.isDisjoint(with: PolishDemo.manual))
        #expect(PolishDemo.covered.isDisjoint(with: PolishDemo.manual))
        #expect(scripted.union(PolishDemo.covered).union(PolishDemo.manual) == Set(Interaction.allCases))
    }

    @Test func everyScriptedInteractionHasADriver() {
        let tables = [DeckDrivers.table, BarDrivers.table, SearchDrivers.table, MenuDrivers.table, WebDrivers.table]
            .map { Set($0.keys) }
        for (index, keys) in tables.enumerated() {
            for later in tables[(index + 1)...] {
                #expect(keys.isDisjoint(with: later))
            }
        }
        #expect(Set(PolishDemo.script).isSubset(of: Set(PolishDemo.drivers.keys)))
    }

    @Test func everyFollowUpLeadInAndFirstStepHasADriver() {
        let played = FollowUps.pairs.flatMap { $0.leadIn + [$0.first] }
        #expect(Set(played).isSubset(of: Set(PolishDemo.drivers.keys)))
    }
}
#endif
