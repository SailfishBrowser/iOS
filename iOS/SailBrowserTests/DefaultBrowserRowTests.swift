import Testing
import UIKit
@testable import SailBrowser

struct DefaultBrowserRowTests {
    @Test func theRowShowsOnlyOnABuildWithTheBrowserEntitlement() {
        #expect(DefaultBrowserSection.isAvailable("YES"))
        #expect(!DefaultBrowserSection.isAvailable("NO"))
        #expect(!DefaultBrowserSection.isAvailable(""))
        #expect(!DefaultBrowserSection.isAvailable(nil))
    }

    @Test func theBuildWritesTheFlagFromItsSetting() {
        let flag = Bundle.main.object(forInfoDictionaryKey: "SailfishDefaultBrowser") as? String
        #expect(flag == "YES" || flag == "NO")
        #expect(URL(string: UIApplication.openDefaultApplicationsSettingsURLString) != nil)
    }
}
