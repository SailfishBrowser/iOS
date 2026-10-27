import UIKit

// Replaces the plist key at runtime; the plist stays portrait-only for check-release.sh. Scene delegate at iOS 27.
final class AppDelegate: NSObject, UIApplicationDelegate {
    // One app-wide mask, never per window: UIKit evaluates ours while WebKit's fullscreen window is key.
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationPolicy.shared.mask
    }
}
