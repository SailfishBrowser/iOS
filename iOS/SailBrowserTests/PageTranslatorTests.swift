import Foundation
import Testing
@testable import SailBrowser

struct PageTranslatorTests {
    @Test func sameLanguageComparesLanguageAndScript() {
        #expect(PageTranslator.isSame(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en-GB")))
        #expect(!PageTranslator.isSame(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
        #expect(!PageTranslator.isSame(Locale.Language(identifier: "fr"), Locale.Language(identifier: "en")))
    }
}
