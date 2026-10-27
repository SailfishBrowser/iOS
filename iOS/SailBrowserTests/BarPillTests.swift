import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

@MainActor
struct BarPillTests {
    private func render(_ bar: some View, in window: UIWindow) -> UIImage {
        let size = CGSize(width: window.bounds.width, height: Theme.Metrics.barTotalHeight)
        let host = UIHostingController(rootView: bar.frame(width: size.width, height: size.height))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    // The "+" glyph's box: pixels in the bar's middle third that stand far from the pill's own fill.
    private func plusBox(_ image: UIImage) -> CGRect {
        let cg = image.cgImage!
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luma(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
        }
        let centre = width / 2
        let fillY = height - Int(Double(height) * Double(Theme.Metrics.barControlCenterFromBottom) / Double(Theme.Metrics.barTotalHeight))
        let fill = luma(centre - width / 12, fillY)
        var box = CGRect.null
        for y in 0..<height {
            for x in (width / 3)..<(2 * width / 3) where abs(luma(x, y) - fill) > 100 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let scale = image.scale
        return CGRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    @Test func plusSitsOnTheSamePointsInTheBrowsingAndSwitcherBars() {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        let env = makeEnvironment()
        env.open(page("a"))
        let browsing = plusBox(render(BottomBar(controller: env.activeController!).environment(env), in: window))
        let switcher = plusBox(render(SwitcherBar().environment(env), in: window))
        #expect(!browsing.isNull && !switcher.isNull)
        #expect(abs(browsing.midX - switcher.midX) < 0.5)
        #expect(abs(browsing.midY - switcher.midY) < 0.5)
        #expect(abs(browsing.midX - window.bounds.midX) < 0.5)
        window.isHidden = true
    }
}
