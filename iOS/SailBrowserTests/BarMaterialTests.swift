import SwiftUI
import Testing
import UIKit
import WebKit
@testable import SailBrowser

// The browsing bar over a page: one regular material by the page tint's luminance, translucent fills for its controls
// and a floor of the same material while the bar is out. The page is a colour view in the window under the bar, and
// every reading is of the whole window (PixelSupport), so the backdrop is in the picture.
@MainActor @Suite(.serialized)
struct BarMaterialTests {
    private static let floorHeight: CGFloat = 34
    private static let white = "<body>a</body>"
    private static let dark = "<meta name='theme-color' content='#101010'><body>d</body>"
    private static let darker = "<meta name='theme-color' content='#202020'><body>e</body>"
    private static let french = "<html lang=\"fr\"><body><p>Le chat dort.</p></body></html>"
    // The pill's interior clear of the "+", and the bar beside the tab stack button.
    private static let pillInset: CGFloat = 19
    private static let barBesideX: CGFloat = 120

    private struct Staged {
        let window: UIWindow
        let page: UIView
        let env: AppEnvironment
        let controller: WebTabController
        let bar: BarSlideView

        var controlsY: CGFloat { bar.frame.minY + Theme.Metrics.barTotalHeight - Theme.Metrics.barControlCenterFromBottom }
        var pillX: CGFloat { bar.frame.midX }
        var chevronX: CGFloat { bar.frame.maxX - Theme.Metrics.barSideInset - Theme.Metrics.controlSize / 2 }
        var material: ChromeMaterial? { bar.host.view.descendants(ChromeMaterial.self).first }
    }

    private func staged(page: UIView = UIView(), translates: Bool = false) -> Staged {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        page.frame = window.bounds
        window.addSubview(page)
        let env = makeEnvironment()
        let controller = WebTabController(
            tabID: UUID(), webView: WKWebView(), haptics: env.haptics, isTranslationSupported: { _, _ in translates })
        let bar = BarSlideView(BarContent(env: env, controller: controller), hidden: false)
        bar.floorHeight = Self.floorHeight
        bar.frame = CGRect(
            x: 0, y: window.bounds.height - Theme.Metrics.barTotalHeight, width: window.bounds.width,
            height: Theme.Metrics.barTotalHeight)
        window.addSubview(bar)
        window.makeKeyAndVisible()
        bar.layoutIfNeeded()
        return Staged(window: window, page: page, env: env, controller: controller, bar: bar)
    }

    private func requireTransparency() throws {
        try #require(
            !UIAccessibility.isReduceTransparencyEnabled,
            "Reduce Transparency is on: materials draw opaque, so no pixel test can read the blur")
    }

    private func components(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue]
    }

    // Loads a page, waits for its tint to reach the bar and for the bar's material to take the look it gives.
    private func load(_ staged: Staged, _ html: String, tint: Int, light: Bool) async throws {
        await loadAndFinish(staged.controller, html: html, base: "https://example.test/\(tint)")
        let want = components(Theme.Palette.uiHex(tint))
        try await waitUntil {
            zip(components(staged.controller.barTint), want).allSatisfy { abs($0 - $1) < 0.002 }
        }
        try await waitUntil { staged.material?.style == Theme.Frost.bar(light: light) }
        await nextDisplayFrame()
    }

    private func settled(_ staged: Staged, over color: UIColor) async -> Bitmap {
        staged.page.backgroundColor = color
        await nextDisplayFrame()
        return Bitmap(staged.window)
    }

    // The bar's and the pill's readings over a white page and over a black one.
    private func contrast(_ staged: Staged) async -> (bar: Int, pill: Int) {
        let overWhite = await settled(staged, over: .white)
        let overBlack = await settled(staged, over: .black)
        let bar = overWhite.luma(x: Self.barBesideX, y: staged.controlsY) - overBlack.luma(x: Self.barBesideX, y: staged.controlsY)
        let pill = overWhite.luma(x: staged.pillX - Self.pillInset, y: staged.controlsY)
            - overBlack.luma(x: staged.pillX - Self.pillInset, y: staged.controlsY)
        return (bar, pill)
    }

    // (1) The regular material carries the page through: the bar and the pill's interior both read differently over
    // white and over black. The farm's simulator read 44 to 48 for the light material and 47 to 52 for the dark.
    @Test func theBarAndItsPillAreTranslucentOverThePage() async throws {
        try requireTransparency()
        let staged = staged()
        defer { staged.window.isHidden = true }
        try await load(staged, Self.white, tint: 0xFFFFFF, light: true)
        let light = await contrast(staged)
        try await load(staged, Self.dark, tint: 0x101010, light: false)
        let dark = await contrast(staged)
        #expect(light.bar >= 25 && light.pill >= 25, "light \(light)")
        #expect(dark.bar >= 40 && dark.pill >= 40, "dark \(dark)")
    }

    // (2a) Frosted: 1 pt stripes under the bar flatten while the page above keeps them.
    @Test func theBarFrostsThePageUnderIt() async throws {
        try requireTransparency()
        let staged = staged(page: StripesView())
        defer { staged.window.isHidden = true }
        try await load(staged, Self.white, tint: 0xFFFFFF, light: true)
        let bitmap = Bitmap(staged.window)
        let bar = staged.bar.frame
        let band = CGRect(x: Self.barBesideX - 30, y: bar.minY + 6, width: 60, height: bar.height - 12)
        let above = CGRect(x: Self.barBesideX - 30, y: bar.minY - 120, width: 60, height: 100)
        #expect(bitmap.range(in: band) < 8, "range under the bar \(bitmap.range(in: band))")
        #expect(bitmap.range(in: above) > 100, "range of the bare stripes \(bitmap.range(in: above))")
    }

    // (2b) The floor while the bar is out: the same frost over the home indicator's strip.
    @Test func theFloorFrostsThePageUnderItWhileTheBarIsOut() async throws {
        try requireTransparency()
        let staged = staged(page: StripesView())
        defer { staged.window.isHidden = true }
        try await load(staged, Self.white, tint: 0xFFFFFF, light: true)
        staged.bar.floor.view.isHidden = false
        staged.bar.slide(hidden: true)
        try await waitUntil { HeldClock.hasEnded(staged.bar.host.view.layer) }
        await nextDisplayFrame()
        #expect(staged.bar.host.view.layer.presentation()?.transform.m42 == Theme.Metrics.barHideOffset)
        let bitmap = Bitmap(staged.window)
        let bottom = staged.window.bounds.height
        let strip = CGRect(x: Self.barBesideX - 30, y: bottom - Self.floorHeight + 4, width: 60, height: Self.floorHeight - 8)
        let above = CGRect(x: Self.barBesideX - 30, y: bottom - Self.floorHeight - 120, width: 60, height: 100)
        #expect(bitmap.range(in: strip) < 8, "range under the floor \(bitmap.range(in: strip))")
        #expect(bitmap.range(in: above) > 100, "range of the bare stripes \(bitmap.range(in: above))")
    }

    // (3) One backdrop per surface: the bar's tree holds one material and the floor's one, with the translate button
    // shown beside the chevron, so no control carries a blur of its own.
    @Test func theBarAndTheFloorCarryOneMaterialEachWithEveryControlShown() async throws {
        let staged = staged(translates: true)
        defer { staged.window.isHidden = true }
        await loadAndFinish(staged.controller, html: Self.french, base: "https://example.test/fr")
        try await waitUntil { staged.controller.translator.source != nil }
        try await waitUntil { staged.env.debugSurfaces[.translate] != nil }
        staged.bar.floor.view.isHidden = false
        staged.bar.layoutIfNeeded()
        staged.bar.floor.view.layoutIfNeeded()
        #expect(staged.env.ui.deckProgress == 0)
        let inBar = staged.bar.host.view.descendants(UIVisualEffectView.self)
        #expect(inBar.count == 1 && inBar.first is ChromeMaterial)
        let inFloor = staged.bar.floor.view.descendants(UIVisualEffectView.self)
        #expect(inFloor.count == 1 && inFloor.first is ChromeMaterial)
    }

    private func glyphContrast(_ bitmap: Bitmap, around centre: CGPoint, fill: Int) -> Int {
        var best = 0
        for y in stride(from: centre.y - 8, through: centre.y + 8, by: 0.5) {
            for x in stride(from: centre.x - 8, through: centre.x + 8, by: 0.5) {
                best = max(best, abs(bitmap.luma(x: x, y: y) - fill))
            }
        }
        return best
    }

    // The "+" and the chevron against their own fills, the fill read beside each glyph.
    private func glyphs(_ staged: Staged, _ bitmap: Bitmap) -> (plus: Int, chevron: Int) {
        let y = staged.controlsY
        let plusFill = bitmap.luma(x: staged.pillX - Self.pillInset, y: y)
        let chevronFill = bitmap.luma(x: staged.chevronX - 13, y: y + 9)
        return (
            glyphContrast(bitmap, around: CGPoint(x: staged.pillX, y: y), fill: plusFill),
            glyphContrast(bitmap, around: CGPoint(x: staged.chevronX, y: y), fill: chevronFill))
    }

    // (4) Glyphs stay legible on their translucent fills: black on the light look over a white page, white on the dark
    // look over a black page. The farm's simulator read 226 light and 202 dark; the bound leaves the runtimes' drift
    // and still fails a glyph on a fill of its own colour, which reads under 60.
    @Test func theGlyphsStandClearOfTheirFillsOverWhiteAndBlackPages() async throws {
        try requireTransparency()
        let staged = staged()
        defer { staged.window.isHidden = true }
        try await load(staged, Self.white, tint: 0xFFFFFF, light: true)
        let light = glyphs(staged, await settled(staged, over: .white))
        try await load(staged, Self.dark, tint: 0x101010, light: false)
        let dark = glyphs(staged, await settled(staged, over: .black))
        #expect(min(light.plus, light.chevron, dark.plus, dark.chevron) >= 150, "light \(light) dark \(dark)")
    }

    // (5) Over moving tints the material is one instance with one effect: two dark colours in turn leave the effect
    // object alone (BottomBar.body re-runs; SwiftUI skips an equal ChromeMaterialView); a light page swaps it through
    // show, on the same view.
    @Test func theMaterialKeepsItsEffectAcrossDarkTintsAndSwapsItForALightOne() async throws {
        let staged = staged()
        defer { staged.window.isHidden = true }
        try await load(staged, Self.dark, tint: 0x101010, light: false)
        let material = try #require(staged.material)
        let effect = material.effect
        let updates = material.updates
        try await load(staged, Self.darker, tint: 0x202020, light: false)
        #expect(staged.bar.host.view.descendants(ChromeMaterial.self) == [material])
        #expect(material.effect === effect)
        try await load(staged, Self.white, tint: 0xFFFFFF, light: true)
        #expect(staged.bar.host.view.descendants(ChromeMaterial.self) == [material])
        #expect(material.effect !== effect)
        #expect(material.effect is UIBlurEffect)
        #expect(material.updates > updates)
    }
}
