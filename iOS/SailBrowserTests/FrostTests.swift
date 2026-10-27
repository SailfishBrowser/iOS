import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

@Observable private final class Ticks {
    var count = 0
    var style = UIBlurEffect.Style.systemMaterialDark
}

private final class BodyCount {
    var value = 0
}

// The material under a value it does not read, so the parent re-evaluates while the style stays the same.
private struct Ticking: View {
    let ticks: Ticks
    let bodies: BodyCount

    var body: some View {
        bodies.value += 1
        return ChromeMaterialView(style: ticks.style).environment(\.isEnabled, ticks.count % 2 == 0)
    }
}

@Suite(.serialized)
@MainActor
struct FrostTests {
    private func makeWindow() -> UIWindow {
        UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
    }

    // A fresh effect resets the backdrop, so the same style must leave the effect object alone.
    @Test func showAssignsAnEffectOnlyWhenTheStyleChanges() {
        let material = ChromeMaterial(.systemMaterialDark)
        let before = material.effect
        #expect(before is UIBlurEffect)
        material.show(.systemMaterialDark)
        #expect(material.effect === before)
        #expect(material.style == .systemMaterialDark)
        #expect(material.updates == 1)
        material.show(.systemMaterialLight)
        #expect(material.effect !== before)
        #expect(material.effect is UIBlurEffect)
        #expect(material.style == .systemMaterialLight)
        material.show(nil)
        #expect(material.effect == nil)
        #expect(material.style == nil)
        #expect(material.updates == 3)
        let solid = ChromeMaterial(nil)
        #expect(solid.effect == nil && solid.style == nil)
        solid.show(.systemThickMaterialDark)
        #expect(solid.effect is UIBlurEffect)
    }

    @Test func tintIsALinearOverlayOnTheContentView() {
        let material = ChromeMaterial(.systemMaterialDark)
        material.tint(.white, opacity: 0.1)
        var white: CGFloat = 0, alpha: CGFloat = 0
        material.contentView.backgroundColor!.getWhite(&white, alpha: &alpha)
        #expect(white == 1 && abs(alpha - 0.1) < 0.001)
    }

    // Sixty re-evaluations of the parent with the same style leave the one material and its effect object alone (on
    // iOS 26.5 SwiftUI does not reach updateUIView for an equal value, so show's guard is the unit test above); a
    // changed style reaches updateUIView, which goes through show: the same view, a new effect.
    @Test func theSwiftUIFaceKeepsOneMaterialAndItsEffectAcrossReEvaluations() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let ticks = Ticks()
        let bodies = BodyCount()
        let host = UIHostingController(rootView: Ticking(ticks: ticks, bodies: bodies))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let material = try #require(host.view.descendants(ChromeMaterial.self).first)
        let effect = material.effect
        let updates = material.updates
        #expect(updates >= 1)
        let start = bodies.value
        for n in 1...60 {
            ticks.count = n
            try await waitUntil(every: .milliseconds(5)) { bodies.value >= start + n }
        }
        #expect(host.view.descendants(ChromeMaterial.self) == [material])
        #expect(material.effect === effect)
        #expect(material.style == .systemMaterialDark)

        ticks.style = .systemMaterialLight
        try await waitUntil(every: .milliseconds(5)) { material.style == .systemMaterialLight }
        #expect(host.view.descendants(ChromeMaterial.self) == [material])
        #expect(material.effect !== effect)
        #expect(material.effect is UIBlurEffect)
        #expect(material.updates > updates)
    }

    // The render path every pixel test of the chrome depends on: drawHierarchy of the whole key window captures a
    // material's blur. Frosted: 1 pt stripes flatten under it while the bare stripes keep their contrast; translucent:
    // it reads differently over white and over black. A solid fill flattens the stripes too, and fails the second.
    @Test func drawHierarchyOfTheWindowCapturesTheBlurFrostedAndTranslucent() async throws {
        try #require(
            !UIAccessibility.isReduceTransparencyEnabled,
            "Reduce Transparency is on: materials draw opaque, so no pixel test can read the blur")
        let window = makeWindow()
        defer { window.isHidden = true }
        let page = StripesView(frame: window.bounds)
        window.addSubview(page)
        let band = CGRect(x: 0, y: window.bounds.midY, width: window.bounds.width, height: window.bounds.midY)
        let material = ChromeMaterial(.systemMaterialDark)
        material.frame = band
        window.addSubview(material)
        window.makeKeyAndVisible()
        await nextDisplayFrame()
        let frosted = Bitmap(window)
        let under = band.insetBy(dx: 40, dy: 40)
        let above = CGRect(x: 40, y: 40, width: band.width - 80, height: band.minY - 80)
        #expect(frosted.range(in: under) < 8, "range under the material \(frosted.range(in: under))")
        #expect(frosted.range(in: above) > 100, "range of the bare stripes \(frosted.range(in: above))")

        page.isHidden = true
        window.backgroundColor = .white
        await nextDisplayFrame()
        let overWhite = Bitmap(window).luma(x: under.midX, y: under.midY)
        window.backgroundColor = .black
        await nextDisplayFrame()
        let overBlack = Bitmap(window).luma(x: under.midX, y: under.midY)
        #expect(overWhite - overBlack >= 40, "\(overWhite) over white against \(overBlack) over black")
        let sample = rgb(of: window, at: CGPoint(x: under.midX, y: under.midY))
        #expect(abs((sample.red * 299 + sample.green * 587 + sample.blue * 114) / 1000 - overBlack) <= 4)
    }
}
