import Testing
import UIKit
@testable import SailBrowser

@Suite(.serialized)
struct AppDelegateTests {
    @Test func theAppRotatesOnlyWhileAPageIsInElementFullscreen() {
        let policy = OrientationPolicy.shared
        let id = ObjectIdentifier(policy)
        defer { policy.record(.notInFullscreen, of: id) }
        let app = UIApplication.shared
        func mask() -> UIInterfaceOrientationMask? {
            app.delegate?.application?(app, supportedInterfaceOrientationsFor: nil)
        }
        #expect(mask() == .portrait)
        #expect(AppDelegate().application(app, supportedInterfaceOrientationsFor: nil) == .portrait)

        policy.record(.enteringFullscreen, of: id)
        #expect(mask() == .allButUpsideDown)
        #expect(AppDelegate().application(app, supportedInterfaceOrientationsFor: nil) == .allButUpsideDown)
        policy.record(.notInFullscreen, of: id)
        #expect(mask() == .portrait)
    }

    @Test func theBuiltPlistStaysPortraitOnly() {
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String]
                == ["UIInterfaceOrientationPortrait"])
    }
}
