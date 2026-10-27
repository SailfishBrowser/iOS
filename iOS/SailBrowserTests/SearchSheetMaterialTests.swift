import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// The sheet's material and the bar drawn under it. Over a dark page the sheet's dark material already is the bar, so
// nothing fades and nothing lies under it. Over a light page, at the deck and on a private tab the destination bar lies
// under the material at full alpha and the material fades over it, so the composite is a blur at every progress and never
// the sharp page. Pixel reads go through the window, where a backdrop is captured, and compare renders and ranges.
@MainActor @Suite(.serialized)
struct SearchSheetMaterialTests {
    private enum Look { case light, dark, deck, privateTab }

    private let transparencyNote: Comment = "Reduce Transparency is on: materials draw opaque, so no pixel test can read the blur"

    // The sheet open at rest over a page of one colour, in the look of a page whose theme colour is light or dark (the
    // deck: no tabs). No keyboard: its stand-in would cover the bar's strip, where the reads go.
    private func opened(_ look: Look, over colour: UIColor) async throws -> (SearchSheetController, UIWindow) {
        let env = makeEnvironment()
        env.browser.settings.autoOpenKeyboard = false
        if look != .deck {
            let light = look != .dark
            let html = "<meta name=theme-color content=\(light ? "#ffffff" : "#203040")><p>look</p>"
            env.open(
                URL(string: "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!,
                isPrivate: look == .privateTab)
            let page = env.activeController!
            let traits = UITraitCollection(userInterfaceStyle: .light)
            try await waitUntil { page.hasSettled && Theme.Palette.isLight(page.barTint, in: traits) == light }
        }
        #expect(env.ui.open(.search, animated: false))
        let (controller, window) = hostedSearchSheet(env)
        controller.view.backgroundColor = colour
        try await waitUntil {
            !controller.container.isHidden && HeldClock.hasEnded(controller.container.layer)
                && HeldClock.hasEnded(controller.material.layer)
        }
        return (controller, window)
    }

    // The drawn progress toward the bar, as holdDrawnParts reads it: from the material's drawn corner alone.
    private func progress(_ controller: SearchSheetController) -> CGFloat {
        1 - controller.material.layer.presentation()!.cornerRadius / Theme.Metrics.searchSheetCorner
    }

    // Taps the sheet closed under a held clock; the caller steps it to the progress it reads.
    private func tappedClose(_ controller: SearchSheetController, in window: UIWindow) -> HeldClock {
        let clock = HeldClock(window.layer)
        controller.setActive(false, submitting: false)
        CATransaction.flush()
        return clock
    }

    private func closeBegin(_ controller: SearchSheetController) throws -> CFTimeInterval {
        try #require(controller.container.layer.animation(forKey: "transform")).beginTime
    }

    // The close's last frame before the hand-off hides the sheet: as near the bar as a read can get.
    private var lastFrame: Int { Theme.Motion.searchTapCloseFrames - 1 }

    // Steps the held close a quarter frame at a time until the sheet is drawn at least `target` of the way to the bar,
    // short of the hand-off frame, so the sheet is still there to read.
    private func step(_ clock: HeldClock, _ controller: SearchSheetController, to target: CGFloat) throws {
        let begin = try closeBegin(controller)
        while progress(controller) < target {
            try #require(clock.now - begin < Double(lastFrame) * Theme.Motion.searchCloseFrame)
            clock.step(by: Theme.Motion.searchCloseFrame / 4)
        }
    }

    private func step(_ clock: HeldClock, _ controller: SearchSheetController, toFrame frame: Int) throws {
        let begin = try closeBegin(controller)
        while clock.now < begin + Double(frame) * Theme.Motion.searchCloseFrame {
            clock.step(by: Theme.Motion.searchCloseFrame / 4)
        }
    }

    // A strip of bare sheet the container covers at every progress: the bar's region at the right margin, between the
    // chevron copy and the sheet's edge, under where the keyboard would be.
    private func band(in window: UIWindow) -> CGRect {
        CGRect(
            x: window.bounds.width - 20, y: window.bounds.height - Theme.Metrics.barTotalHeight + 12, width: 12, height: 18)
    }

    private func rgba(_ color: UIColor?) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    private func matches(_ color: UIColor?, _ expected: UIColor) -> Bool {
        zip(rgba(color), rgba(expected)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    private func sameEffects(
        _ controller: SearchSheetController, _ effect: UIVisualEffect, _ under: UIVisualEffect
    ) -> Bool {
        controller.material.effect === effect && controller.underBar.effect === under
    }

    // The light bar's material lies just under the sheet's, at full alpha and the same shape, and the sheet fades over
    // it as it lands; no solid is drawn on a browsing look.
    @Test(.timeLimit(.minutes(1)))
    func overALightPageTheSheetFadesOverTheLightBarDrawnUnderIt() async throws {
        let (controller, window) = try await opened(.light, over: .white)
        defer { window.isHidden = true }
        let subviews = controller.container.subviews
        let under = try #require(subviews.firstIndex(of: controller.underBar))
        #expect(subviews[under + 1] === controller.material)
        #expect(controller.underBar.style == Theme.Frost.bar(light: true))
        #expect(controller.underBar.effect is UIBlurEffect)
        #expect(controller.underBar.alpha == 1 && controller.material.alpha == 1)
        #expect(rgba(controller.underBar.contentView.backgroundColor)[3] == 0)
        #expect(controller.underBar.frame == controller.material.frame)
        #expect(controller.underBar.layer.cornerRadius == controller.material.layer.cornerRadius)
        #expect(controller.underBar.layer.cornerCurve == .continuous)
        #expect(controller.underBar.layer.maskedCorners == controller.material.layer.maskedCorners)
        #expect(controller.underBar.clipsToBounds)
        #expect(controller.container.descendants(UIVisualEffectView.self) == [controller.underBar, controller.material])

        let clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        let drawn = try #require(controller.material.layer.presentation())
        let drawnUnder = try #require(controller.underBar.layer.presentation())
        #expect(abs(CGFloat(drawn.opacity) - (1 - progress(controller))) < 0.02, "\(drawn.opacity) at \(progress(controller))")
        #expect(drawnUnder.opacity == 1)
        #expect(drawnUnder.cornerRadius == drawn.cornerRadius)
        try step(clock, controller, toFrame: lastFrame)
        #expect(progress(controller) > 0.97)
        #expect(controller.material.alpha == 0)
        #expect(controller.underBar.alpha == 1)
        #expect(rgba(controller.underBar.contentView.backgroundColor)[3] == 0)
        #expect(controller.underBar.style == Theme.Frost.bar(light: true))
    }

    // Over a dark page the sheet's material is the bar's: nothing lies under it and nothing fades, so UIKit is never asked
    // to animate the backdrop's opacity.
    @Test(.timeLimit(.minutes(1)))
    func overADarkPageTheSheetIsTheBarAndNothingFades() async throws {
        let (controller, window) = try await opened(.dark, over: .black)
        defer { window.isHidden = true }
        #expect(controller.underBar.style == nil && controller.underBar.effect == nil)
        #expect(rgba(controller.underBar.contentView.backgroundColor)[3] == 0)
        #expect(controller.material.alpha == 1)
        // The tune knob: the sheet's tint colour at its opacity while open, gone once landed.
        let tint = rgba(controller.material.contentView.backgroundColor)
        #expect(zip(tint[0..<3], rgba(Theme.Frost.sheetTint)[0..<3]).allSatisfy { abs($0 - $1) < 0.002 })
        #expect(abs(tint[3] - Theme.Frost.sheetTintOpacity) < 0.002)
        let clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        let drawn = try #require(controller.material.layer.presentation())
        #expect(drawn.opacity == 1)
        #expect(controller.material.layer.animation(forKey: "opacity") == nil)
        try step(clock, controller, toFrame: lastFrame)
        #expect(progress(controller) > 0.97)
        #expect(controller.material.alpha == 1)
        #expect(controller.underBar.style == nil)
        #expect(rgba(controller.underBar.contentView.backgroundColor)[3] == 0)
        #expect(rgba(controller.material.contentView.backgroundColor)[3] == 0)
    }

    // At the deck the dark bar's material lies under the sheet and tints to the deck strip by the progress, so the
    // composite is a blur at every progress and the solid strip once landed.
    @Test(.timeLimit(.minutes(1)))
    func atTheDeckTheUnderLayerTintsToTheStripAsTheSheetLands() async throws {
        let (controller, window) = try await opened(.deck, over: .black)
        defer { window.isHidden = true }
        #expect(controller.underBar.style == Theme.Frost.bar(light: false))
        #expect(rgba(controller.underBar.contentView.backgroundColor)[3] == 0)
        let clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        let drawnTint = try #require(controller.underBar.contentView.layer.presentation()?.backgroundColor)
        #expect(abs(drawnTint.alpha - progress(controller)) < 0.02, "\(drawnTint.alpha) at \(progress(controller))")
        let drawnUnder = try #require(controller.underBar.layer.presentation())
        #expect(drawnUnder.opacity == 1)
        let drawn = try #require(controller.material.layer.presentation())
        #expect(abs(CGFloat(drawn.opacity) - (1 - progress(controller))) < 0.02)
        try step(clock, controller, toFrame: lastFrame)
        #expect(matches(controller.underBar.contentView.backgroundColor, UIColor(Theme.Palette.deckBarStrip)))
        #expect(controller.material.alpha == 0)
    }

    // The private bar is a dark solid over any page, but the incognito sheet tracks the page, so the page's bar material
    // lies under the sheet and tints to the private bar only as the sheet lands. The shade stays inside the material and
    // goes with it.
    @Test(.timeLimit(.minutes(1)))
    func onAPrivateTabTheUnderLayerEndsOnTheSolidPrivateBar() async throws {
        let (controller, window) = try await opened(.privateTab, over: .white)
        defer { window.isHidden = true }
        #expect(controller.underBar.style == Theme.Frost.bar(light: true))
        #expect(controller.privateShade.superview === controller.material.contentView)
        #expect(abs(controller.privateShade.alpha - Theme.Opacity.privateSheetShade) < 0.001)
        let clock = tappedClose(controller, in: window)
        try step(clock, controller, toFrame: lastFrame)
        #expect(progress(controller) > 0.97)
        #expect(matches(controller.underBar.contentView.backgroundColor, UIColor(Theme.Palette.privateBarBackground)))
        #expect(controller.material.alpha == 0)
        #expect(abs(controller.privateShade.alpha - Theme.Opacity.privateSheetShade) < 0.001)
    }

    // With 1 pt stripes under it, the bar's strip reads flat at rest, half way and landed: the sheet's blur over the bar's,
    // never the page through an alpha-faded backdrop (audit O2; the material faded alone fails this half way).
    @Test(.timeLimit(.minutes(1)))
    func theHandOffNeverShowsTheSharpPage() async throws {
        try #require(!UIAccessibility.isReduceTransparencyEnabled, transparencyNote)
        let (controller, window) = try await opened(.light, over: .white)
        defer { window.isHidden = true }
        let stripes = StripesView(frame: controller.view.bounds)
        stripes.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.insertSubview(stripes, at: 0)
        await nextDisplayFrame()
        let band = band(in: window)
        let bare = CGRect(x: 40, y: 40, width: window.bounds.width - 80, height: 60)
        let open = Bitmap(window)
        #expect(open.range(in: bare) > 100, "bare stripes range \(open.range(in: bare))")
        #expect(open.range(in: band) < 8, "range under the open sheet \(open.range(in: band))")
        let clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        let half = Bitmap(window).range(in: band)
        #expect(half < 8, "range half way, at \(progress(controller)): \(half)")
        try step(clock, controller, toFrame: lastFrame)
        let landed = Bitmap(window).range(in: band)
        #expect(landed < 8, "range landed, at \(progress(controller)): \(landed)")
    }

    // Over a white page under the 20% dim the hand-off runs from the sheet's level to the light bar's with no step past
    // either. The level itself is the phone's to judge: the open sheet read 79 here on the iOS 26.5 simulator against
    // 97 to 111 measured on the phone, its dark material transmitting less, so only the order is pinned.
    @Test(.timeLimit(.minutes(1)))
    func overAWhitePageTheHandOffIsMonotonic() async throws {
        try #require(!UIAccessibility.isReduceTransparencyEnabled, transparencyNote)
        let dimmed = UIColor(white: 1 - Theme.Opacity.searchDim, alpha: 1)
        let (controller, window) = try await opened(.light, over: dimmed)
        defer { window.isHidden = true }
        await nextDisplayFrame()
        let band = band(in: window)
        let open = Bitmap(window).luma(x: band.midX, y: band.midY)
        let clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        let half = Bitmap(window).luma(x: band.midX, y: band.midY)
        try step(clock, controller, toFrame: lastFrame)
        let landed = Bitmap(window).luma(x: band.midX, y: band.midY)
        #expect(landed > open, "landed \(landed) against open \(open)")
        #expect(open <= half && half <= landed, "open \(open), half way \(half), landed \(landed)")
    }

    // The page's light comes through the open sheet (97 to 111 over white, 41 to 45 over dark): over
    // white under the 20% dim it reads at least 20 levels lighter than over black. The regular dark material reads 40
    // apart over white and black (FrostTests); a thick one about half that, so a slab fails here.
    @Test(.timeLimit(.minutes(1)))
    func theSheetLetsThePagesLightThrough() async throws {
        try #require(!UIAccessibility.isReduceTransparencyEnabled, transparencyNote)
        let dimmed = UIColor(white: 1 - Theme.Opacity.searchDim, alpha: 1)
        let (controller, window) = try await opened(.dark, over: dimmed)
        defer { window.isHidden = true }
        await nextDisplayFrame()
        let band = band(in: window)
        let overWhite = Bitmap(window).luma(x: band.midX, y: band.midY)
        controller.view.backgroundColor = .black
        await nextDisplayFrame()
        let overBlack = Bitmap(window).luma(x: band.midX, y: band.midY)
        #expect(overWhite - overBlack >= 20, "\(overWhite) over dimmed white against \(overBlack) over black")
    }

    // The sheet carries the page's hue, keeping the navy and the sky: over a pure blue page its blue exceeds its
    // red by more than it does over a black page.
    @Test(.timeLimit(.minutes(1)))
    func theSheetCarriesThePagesHue() async throws {
        try #require(!UIAccessibility.isReduceTransparencyEnabled, transparencyNote)
        let (controller, window) = try await opened(.dark, over: .blue)
        defer { window.isHidden = true }
        await nextDisplayFrame()
        let band = band(in: window)
        let point = CGPoint(x: band.midX, y: band.midY)
        let overBlue = rgb(of: window, at: point)
        controller.view.backgroundColor = .black
        await nextDisplayFrame()
        let overBlack = rgb(of: window, at: point)
        #expect(
            overBlue.blue - overBlue.red >= overBlack.blue - overBlack.red + 4,
            "\(overBlue) over blue against \(overBlack) over black")
    }

    // A fresh effect resets the backdrop and costs a frame, so the material and the bar under it keep their effect objects
    // through the close, a catch on the return, the return and the hand-off. Only the submit clears both effects, with
    // the tints under them; the hide restores the sheet's, and the next open puts the look's bar back under it.
    @Test(.timeLimit(.minutes(1)))
    func theEffectsSurviveEveryMotionButTheSubmit() async throws {
        let (controller, window) = try await opened(.light, over: .white)
        defer { window.isHidden = true }
        let effect = try #require(controller.material.effect)
        let under = try #require(controller.underBar.effect)
        var clock = tappedClose(controller, in: window)
        try step(clock, controller, to: 0.5)
        #expect(sameEffects(controller, effect, under))
        // A touch on the drawn sheet during its return from the close catches it there, parts and materials included.
        controller.setActive(true, submitting: false)
        CATransaction.flush()
        clock.step(by: 2 * Theme.Motion.searchCloseFrame)
        let drawn = try #require(controller.container.layer.presentation()).frame
        #expect(controller.view.hitTest(CGPoint(x: drawn.midX, y: drawn.minY + 10), with: TouchEvent()) != nil)
        #expect(controller.container.layer.animationKeys() == nil)
        #expect(sameEffects(controller, effect, under))
        controller.riseFromHold()
        clock.resume()
        try await waitUntil { HeldClock.hasEnded(controller.container.layer) }
        #expect(sameEffects(controller, effect, under))
        controller.setActive(false, submitting: false)
        try await waitUntil { controller.container.isHidden }
        #expect(sameEffects(controller, effect, under))

        controller.setActive(true, submitting: false)
        try await waitUntil { !controller.container.isHidden && HeldClock.hasEnded(controller.container.layer) }
        #expect(sameEffects(controller, effect, under))
        clock = HeldClock(window.layer)
        controller.setActive(false, submitting: true)
        // The blur's fade starts on the next main turn and clears both effects at once, with the tints under them.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(controller.blurFade?.isRunning == true)
        #expect(!controller.container.isHidden)
        #expect(controller.material.effect == nil && controller.underBar.effect == nil)
        #expect(controller.material.contentView.alpha == 0 && controller.underBar.contentView.alpha == 0)
        clock.resume()
        try await waitUntil { controller.container.isHidden }
        #expect(controller.material.style == Theme.Frost.sheet && controller.material.effect is UIBlurEffect)
        #expect(controller.material.contentView.alpha == 1 && controller.underBar.contentView.alpha == 1)
        #expect(controller.underBar.effect == nil)
        controller.setActive(true, submitting: false)
        #expect(controller.underBar.style == Theme.Frost.bar(light: true))
        #expect(controller.underBar.effect is UIBlurEffect)
    }
}
