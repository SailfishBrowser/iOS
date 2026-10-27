import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// The page menu's and the permission prompt's sheet: one thick material under the measured
// gradient, riding inside the container the springs move, never faded. Pixel checks render the whole key window
// (PixelSupport.swift) and assert on a difference, except one wide-margin level check.
@Suite(.serialized)
@MainActor
struct SheetMaterialTests {
    private func makeWindow() -> UIWindow {
        UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
    }

    // The one material in a host's tree is the sheet's background, the gradient and the hairline inside its contentView.
    private func theOneMaterial(in view: UIView) throws -> MenuSheetBackground {
        let materials = view.descendants(UIVisualEffectView.self)
        #expect(materials.count == 1, "\(materials)")
        let background = try #require(materials.first as? MenuSheetBackground)
        #expect(background.contentView.subviews.contains { $0 is GradientView })
        #expect(background.contentView.subviews.contains { $0 is SheetEdge })
        #expect(view.descendants(GradientView.self).count == 1)
        #expect(view.descendants(SheetEdge.self).count == 1)
        return background
    }

    private func gradientLayer(_ background: MenuSheetBackground) -> CAGradientLayer {
        background.descendants(GradientView.self).first!.gradient
    }

    // A bare sheet over a flat page, as the app draws it: the page's colour under a dim, the sheet a screen's height from
    // its top at the window's middle. Returns the point to read its top at, clear of the hairline and the corners.
    private func sheet(over page: UIColor, dim: CGFloat, look: MenuLook) async -> (UIWindow, MenuSheetBackground, CGPoint) {
        let window = makeWindow()
        window.backgroundColor = page
        let shade = UIView(frame: window.bounds)
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shade.backgroundColor = UIColor.black.withAlphaComponent(dim)
        window.addSubview(shade)
        let background = MenuSheetBackground()
        let top = window.bounds.midY
        background.frame = CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height)
        window.addSubview(background)
        background.apply(look)
        background.endGradient(below: window.bounds.height - top)
        window.makeKeyAndVisible()
        await nextDisplayFrame()
        return (window, background, CGPoint(x: window.bounds.midX, y: top + 6))
    }

    // The mean grey over a band under the sheet's top, clear of the hairline and the corners: one point's rounding would
    // hide a difference of a level or two.
    private func top(_ window: UIWindow, at point: CGPoint) -> Double {
        let bitmap = Bitmap(window)
        var sum = 0, count = 0
        for y in stride(from: point.y, to: point.y + 12, by: 2) {
            for x in stride(from: point.x - 40, to: point.x + 40, by: 2) {
                sum += bitmap.luma(x: x, y: y)
                count += 1
            }
        }
        return Double(sum) / Double(count)
    }

    private func requireTransparency() throws {
        try #require(
            !UIAccessibility.isReduceTransparencyEnabled,
            "Reduce Transparency is on: materials draw opaque, so no pixel test can read the blur")
    }

    // The menu's one material is its background, in the look the page gives it.
    @Test(.timeLimit(.minutes(1)))
    func theMenuHasOneMaterialInThePagesLook() async throws {
        let env = makeEnvironment()
        env.open(page("a"))
        let controller = try #require(env.activeController)
        let window = makeWindow()
        defer { window.isHidden = true }
        let menu = PageMenuController(env: env)
        window.rootViewController = menu
        window.makeKeyAndVisible()
        #expect(env.ui.open(.menu))
        menu.setOpen(true)
        let background = try theOneMaterial(in: menu.view)
        #expect(background.superview === menu.container)
        try await waitUntil { background.style != nil }
        let isLight = Theme.Palette.isLight(controller.barTint, in: window.traitCollection)
        #expect(background.style == Theme.Frost.menu(light: isLight))
    }

    // The prompt's container has no fill and no corners of its own: the menu's dark sheet, a screen tall from the
    // container's top, carries them, as the menu's does.
    @Test(.timeLimit(.minutes(1)))
    func thePromptHasTheMenusDarkMaterialCarryingItsCorners() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let prompt = PermissionPromptController(
            host: "example.test", kinds: [.camera, .microphone], env: makeEnvironment()) { _ in }
        window.rootViewController = prompt
        window.makeKeyAndVisible()
        try await waitUntil { prompt.container.bounds.height > 0 }
        prompt.view.layoutIfNeeded()
        let background = try theOneMaterial(in: prompt.view)
        #expect(background.superview === prompt.container)
        #expect(background.style == Theme.Frost.menu(light: false))
        #expect(prompt.container.backgroundColor == nil)
        #expect(prompt.container.layer.cornerRadius == 0)
        #expect(background.layer.cornerRadius == Theme.Metrics.menuSheetCorner)
        #expect(background.layer.cornerCurve == .continuous)
        #expect(background.layer.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        #expect(background.clipsToBounds)
        #expect(background.frame.minY == 0 && background.frame.width == prompt.container.bounds.width)
        #expect(background.frame.height == prompt.view.bounds.height)
        #expect(abs(prompt.container.bounds.height - Theme.Metrics.permissionSheetHeight - prompt.view.safeAreaInsets.bottom) < 0.5)
    }

    // Over a white page under the menu's dim (the app never draws the menu over an undimmed page) the light sheet's top
    // reads the measured #F3F3F4 within 8: the one near-absolute pixel check, wide because the simulator's material
    // is not the phone's.
    @Test(.timeLimit(.minutes(1)))
    func theLightSheetReadsItsMeasuredTopOverADimmedWhitePage() async throws {
        try requireTransparency()
        let (window, _, point) = await sheet(
            over: .white, dim: Theme.Opacity.menuDim, look: MenuLook(isLight: true, tint: nil))
        defer { window.isHidden = true }
        let top = top(window, at: point)
        #expect(abs(top - 243) <= 8, "the light sheet's top reads \(top) over a dimmed white page")
    }

    // The dark sheet is a material, not a fill: its top reads differently over a white page and over a black one. The
    // thick dark material under the 70% gradient passes about one percent of the page (2 levels on the farm's iOS 26.5
    // simulator, 2026-10-27; another runtime may read 1), while a fill reads exactly 0.
    @Test(.timeLimit(.minutes(1)))
    func theDarkSheetCarriesThePageThrough() async throws {
        try requireTransparency()
        let (window, _, point) = await sheet(over: .white, dim: 0, look: MenuLook(isLight: false, tint: nil))
        defer { window.isHidden = true }
        let overWhite = top(window, at: point)
        window.backgroundColor = .black
        await nextDisplayFrame()
        let overBlack = top(window, at: point)
        #expect(overWhite - overBlack > 0, "\(overWhite) over white against \(overBlack) over black")
    }

    // A look change and a fold's new height set the gradient directly, with no implicit ease on its colours or its end
    // (a bare CAGradientLayer would run one of 0.25 s on every set, and endGradient runs on every layout).
    @Test(.timeLimit(.minutes(1)))
    func settingTheGradientRunsNoImplicitAnimation() async throws {
        let (window, background, _) = await sheet(over: .white, dim: 0, look: MenuLook(isLight: true, tint: nil))
        defer { window.isHidden = true }
        background.apply(MenuLook(isLight: false, tint: .red))
        background.endGradient(below: 300)
        let layer = gradientLayer(background)
        #expect(layer.animationKeys() == nil, "\(layer.animationKeys() ?? [])")
        #expect(abs(layer.endPoint.y - 300 / background.bounds.height) < 0.0001)
        #expect(layer.frame == background.bounds)
    }
}
