import Testing
import UIKit
@testable import SailBrowser

struct LoadErrorViewTests {
    private final class Calls {
        var actions = 0
        var dismissals = 0
    }

    private let offline = LoadError(URLError(.notConnectedToInternet), fallbackURL: URL(string: "https://example.test/a")!)!
    private let timedOut = LoadError(URLError(.timedOut), fallbackURL: URL(string: "https://slow.test/b")!)!

    private func makeView(
        backdrop: UIImage? = nil, background: UIColor = Theme.Network.errorBackground, dismissable: Bool = true,
        calls: Calls = Calls()
    ) -> LoadErrorView {
        LoadErrorView(
            error: offline, backdrop: backdrop, background: background, onAction: { calls.actions += 1 },
            onDismiss: dismissable ? { calls.dismissals += 1 } : nil)
    }

    private func laidOut(_ view: LoadErrorView, top: CGFloat = 62) -> LoadErrorView {
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        view.apply(insets: UIEdgeInsets(top: top, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0))
        view.layoutIfNeeded()
        return view
    }

    private static let column = UIEdgeInsets(top: 62, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0)

    // The dismissable column filling a phone window whose traits carry the text size.
    private func laidOut(_ view: LoadErrorView, at category: UIContentSizeCategory) -> UIWindow {
        let window = makeWindow(at: category)
        view.update(error: offline, canDismiss: true)
        window.addSubview(view)
        view.frame = window.bounds
        view.apply(insets: Self.column)
        view.layoutIfNeeded()
        return window
    }

    private func controls(_ view: LoadErrorView) -> [UIView] {
        [view.glyphView, view.titleLabel, view.detailLabel, view.button, view.dismissButton]
    }

    private func pixel(of view: UIView, at point: CGPoint) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -point.x, y: -point.y)
        view.layer.render(in: context)
        return data[0..<3].map(Int.init)
    }

    @Test func retryFiresOnce() {
        let calls = Calls()
        let view = makeView(calls: calls)
        view.button.sendActions(for: .touchUpInside)
        #expect(calls.actions == 1)
        #expect(calls.dismissals == 0)
    }

    @Test func dismissFiresOnDismissOnly() {
        let calls = Calls()
        let view = makeView(calls: calls)
        view.update(error: offline, canDismiss: true)
        view.dismissButton.sendActions(for: .touchUpInside)
        #expect(calls.dismissals == 1)
        #expect(calls.actions == 0)
    }

    @Test func theSecondaryActionShowsOnlyWhenItCanDismiss() {
        let none = makeView(dismissable: false)
        none.update(error: offline, canDismiss: true)
        #expect(none.dismissButton.isHidden)

        let view = makeView()
        #expect(view.dismissButton.isHidden)
        view.update(error: offline, canDismiss: true)
        #expect(!view.dismissButton.isHidden)
        view.update(error: offline, canDismiss: false)
        #expect(view.dismissButton.isHidden)
    }

    @Test func touchesStopAtTheView() {
        let view = laidOut(makeView())
        let hit = view.hitTest(CGPoint(x: 201, y: 437), with: nil)
        #expect(hit != nil && hit!.isDescendant(of: view))
        #expect(view.isUserInteractionEnabled)
    }

    @Test func contentSitsBetweenTheObscuredInsets() {
        let view = laidOut(makeView())
        view.update(error: offline, canDismiss: true)
        view.layoutIfNeeded()
        let controls: [UIView] = [view.glyphView, view.titleLabel, view.detailLabel, view.button, view.dismissButton]
        let union = controls.filter { !$0.isHidden }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let inset = view.bounds.inset(by: UIEdgeInsets(top: 62, left: 0, bottom: Theme.Metrics.barTotalHeight, right: 0))
        #expect(abs(union.midY - inset.midY) < 1)
        #expect(union.minY > 62)
        #expect(union.maxY < 874 - Theme.Metrics.barTotalHeight)
        #expect(abs(union.midX - 201) < 1)
        #expect(view.button.frame.height == Theme.Network.errorButtonHeight)
        #expect(view.button.frame.width >= Theme.Network.errorButtonMinWidth)
        #expect(view.detailLabel.text == "example.test")
    }

    @Test func updateReplacesTheCopy() {
        let image = solidImage(.red, side: 10)
        let view = makeView(backdrop: image)
        #expect(view.titleLabel.text == offline.reason.title)
        view.update(error: timedOut, canDismiss: false)
        #expect(view.titleLabel.text == timedOut.reason.title)
        #expect(view.detailLabel.text == "slow.test")
        #expect(view.button.title(for: .normal) == "Try Again")
        #expect(view.backdropView?.image === image)
        view.update(error: .crashed(url: URL(string: "https://big.test/")!), canDismiss: false)
        #expect(view.button.title(for: .normal) == "Reload")
    }

    @Test func aNilBackdropAddsNoImageView() {
        #expect(makeView().backdropView == nil)
        #expect(makeView(backdrop: solidImage(.red, side: 10)).backdropView != nil)
    }

    @Test func theBandRegionIsTheBackground() {
        let view = laidOut(makeView(backdrop: solidImage(.red, side: 10)))
        let background = components(Theme.Network.errorBackground)
        #expect(pixel(of: view, at: CGPoint(x: 5, y: 30)) == background)
        let dimmed = pixel(of: view, at: CGPoint(x: 5, y: 100))
        #expect(dimmed[0] < 255 && dimmed[0] > dimmed[1] + 40)
        #expect(pixel(of: view, at: CGPoint(x: 5, y: 870)) == background)
    }

    // At the largest text size the fonts grow, the column still sits between the band and the bar, nothing overlaps
    // and the button holds its label.
    @Test func theColumnReadsAtTheLargestTextSize() {
        let view = makeView()
        let window = laidOut(view, at: .accessibilityExtraExtraExtraLarge)
        defer { window.isHidden = true }
        #expect(view.titleLabel.font.pointSize > Theme.Network.errorTitleFont.pointSize)
        #expect(view.detailLabel.font.pointSize > Theme.Network.errorDetailFont.pointSize)
        #expect(view.button.titleLabel!.font.pointSize > Theme.Network.errorButtonFont.pointSize)
        #expect(view.dismissButton.titleLabel!.font.pointSize > Theme.Network.errorDetailFont.pointSize)
        let frames = controls(view).map(\.frame)
        let inset = view.bounds.inset(by: Self.column)
        for frame in frames {
            #expect(inset.contains(frame), "\(frame)")
        }
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other), "\(frame) \(other)")
            }
        }
        let label = view.button.titleLabel!.intrinsicContentSize
        #expect(view.button.frame.width >= label.width + 2 * Theme.Network.errorButtonPadding)
        #expect(view.button.frame.height >= label.height + Theme.Network.errorButtonPadding)
        #expect(view.button.layer.cornerRadius == view.button.frame.height / 2)
        #expect(view.glyphView.frame.height > Self.defaultFrames[0].height)
    }

    // At the default size the column lays out exactly as it did with fixed fonts: the frames recorded before the change.
    @Test func theDefaultSizeLaysOutAsBefore() {
        let view = makeView()
        let window = laidOut(view, at: .large)
        defer { window.isHidden = true }
        let frames = controls(view).map(\.frame)
        #expect(frames.count == Self.defaultFrames.count, "\(frames)")
        for (frame, pin) in zip(frames, Self.defaultFrames) {
            #expect(
                abs(frame.minX - pin.minX) < 0.01 && abs(frame.minY - pin.minY) < 0.01
                    && abs(frame.width - pin.width) < 0.01 && abs(frame.height - pin.height) < 0.01, "\(frame) vs \(pin)")
        }
    }

    // Glyph, title, host, button and the way back at 402 by 874 with the band at 62 and the bar below, before the fonts
    // scaled.
    private static let defaultFrames = [
        CGRect(x: 178.5, y: 321.1667, width: 45, height: 39.6667), CGRect(x: 24, y: 374.8333, width: 354, height: 24),
        CGRect(x: 157.1667, y: 412.8333, width: 87.6667, height: 18), CGRect(x: 121, y: 444.8333, width: 160, height: 50),
        CGRect(x: 172.5, y: 508.8333, width: 57, height: 30),
    ]

    @Test func theViewIsOpaqueOnItsBackgroundWithItsIdentifiers() {
        let view = makeView(background: Theme.Network.errorBackgroundPrivate)
        #expect(view.isOpaque)
        #expect(view.backgroundColor == Theme.Network.errorBackgroundPrivate)
        #expect(view.overrideUserInterfaceStyle == .dark)
        #expect(view.titleLabel.accessibilityIdentifier == "loadError.title")
        #expect(view.button.accessibilityIdentifier == "loadError.action")
        #expect(view.dismissButton.accessibilityIdentifier == "loadError.dismiss")
    }
}
