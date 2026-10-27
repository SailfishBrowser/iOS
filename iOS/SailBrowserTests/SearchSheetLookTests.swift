import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

struct SearchSheetLookTests {
    // The sheet's material and the bar drawn under it share one class, so they share the corner that the hand-off squares.
    @Test func sheetMaterialIsABlurWithRoundedTopCornersAndTheUnderLayerStartsWithNone() {
        let material = SearchSheetMaterial(Theme.Frost.sheet)
        #expect(material.style == Theme.Frost.sheet)
        #expect(material.effect is UIBlurEffect)
        #expect(material.layer.cornerRadius == Theme.Metrics.searchSheetCorner)
        #expect(material.layer.cornerCurve == .continuous)
        #expect(material.layer.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        #expect(material.clipsToBounds)
        material.shape(barProgress: 1)
        #expect(material.layer.cornerRadius == 0)
        let under = SearchSheetMaterial(nil)
        #expect(under.effect == nil && under.style == nil)
        #expect(under.layer.cornerRadius == Theme.Metrics.searchSheetCorner)
        #expect(under.layer.maskedCorners == material.layer.maskedCorners && under.clipsToBounds)
    }

    private func alpha(_ color: UIColor?) -> CGFloat {
        var white: CGFloat = 0, alpha: CGFloat = 0
        color!.getWhite(&white, alpha: &alpha)
        return alpha
    }

    // An empty-field row (B4): favicon at 19 pt, 20 pt wide, title from about 48 pt, 56 pt tall, no host line.
    @MainActor @Test func aRecentRowLaysOutOnTheThemeMetrics() throws {
        let env = makeEnvironment()
        let side = Int(Theme.Metrics.suggestionFavicon)
        env.favicons.favicon(for: "news.ycombinator.com").image = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side)
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        let row = SuggestionRow(suggestion: .site(url: URL(string: "https://news.ycombinator.com/")!, title: "Hacker News"))
            .environment(env)
            .frame(width: 402)
            .background(Color.black)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(CGFloat(image.height) == Theme.Metrics.suggestionRowHeight)

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rgb = { (x: Int, y: Int) -> (Int, Int, Int) in
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let mid = height / 2
        let red = (0..<width).filter { let p = rgb($0, mid); return p.0 > 200 && p.1 < 60 && p.2 < 60 }
        #expect(red.first == Int(Theme.Metrics.suggestionRowLeading))
        #expect(red.count == side)
        let titleStart = Theme.Metrics.suggestionRowLeading + Theme.Metrics.suggestionFavicon + Theme.Metrics.suggestionIconGap
        #expect(titleStart == 48)
        let lit = (0..<height).flatMap { y in (0..<width).map { (x: $0, y: y) } }.filter { point in
            let p = rgb(point.x, point.y)
            return p.0 > 128 && p.1 > 128 && p.2 > 128
        }
        let firstLit = try #require(lit.map(\.x).min())
        #expect(firstLit >= Int(titleStart) && firstLit <= Int(titleStart) + 2)
        // One line of 17 pt text: no host line under the title.
        let rows = lit.map(\.y)
        #expect(rows.max()! - rows.min()! < 17)
    }

    @Test func fieldUsesTheMeasuredTypeCaretAndInset() {
        let field = SearchField(onPress: {}, onClear: {})
        #expect(field.font == Theme.Typography.searchFieldUIFont)
        #expect(field.tintColor == UIColor(Theme.Palette.searchCaret))
        let placeholder = field.attributedPlaceholder!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(abs(alpha(placeholder) - Theme.Opacity.searchFieldPlaceholder) < 0.001)
        let bounds = CGRect(x: 0, y: 0, width: 408, height: Theme.Metrics.searchFieldHeight)
        #expect(field.textRect(forBounds: bounds).minX >= Theme.Metrics.searchFieldTextInset)
        #expect(field.editingRect(forBounds: bounds).minX >= Theme.Metrics.searchFieldTextInset)
    }

    @Test func fieldCapsuleIsTranslucentWithALightRim() {
        let capsule = SearchFieldCapsule()
        #expect(abs(alpha(capsule.backgroundColor) - Theme.Opacity.searchFieldFill) < 0.001)
        #expect(capsule.layer.borderWidth == Theme.Metrics.hairlineWidth)
        #expect(abs(alpha(capsule.layer.borderColor.map(UIColor.init(cgColor:))) - Theme.Opacity.searchFieldRim) < 0.001)
    }
}

struct SearchClearButtonTests {
    // The eyes sit where the clear button does; with text the clear button takes their place. "Incognito" sits left of
    // whichever shows while the mode is on, and the text ends before it.
    @Test func theToggleAndTheClearButtonShareTheFieldsEnd() {
        let field = SearchField(onPress: {}, onClear: {})
        let bounds = CGRect(x: 0, y: 0, width: 408, height: Theme.Metrics.searchFieldHeight)
        field.frame = bounds
        field.layoutIfNeeded()
        let toggle = field.privateToggleRect(forBounds: bounds)
        #expect(toggle.midX == bounds.maxX - Theme.Metrics.searchClearCenterInset)
        #expect(field.rightViewRect(forBounds: bounds).midX == bounds.maxX - Theme.Metrics.searchClearCenterInset)
        #expect(abs(toggle.width - (field.privateToggle.intrinsicContentSize.width + 2 * Theme.Metrics.privateToggleGap)) < 0.001)
        #expect(!field.privateToggle.isHidden)
        #expect(abs(field.textRect(forBounds: bounds).maxX - toggle.minX) < 0.001)
        #expect(field.privateToggle.accessibilityLabel == "Turn On Incognito")

        field.showPrivate(true)
        field.layoutIfNeeded()
        #expect(field.privateToggle.accessibilityLabel == "Turn Off Incognito")
        #expect(abs(field.privateLabel.frame.maxX - toggle.minX) < 0.001)
        #expect(abs(field.textRect(forBounds: bounds).maxX - field.privateLabel.frame.minX) < 0.001)

        field.text = "hello"
        field.sendActions(for: .editingChanged)
        field.layoutIfNeeded()
        #expect(field.privateToggle.isHidden)
        #expect(!field.rightView!.isHidden)
        #expect(abs(field.privateLabel.frame.maxX - field.rightViewRect(forBounds: bounds).minX) < 0.001)
    }

    @Test func theClearButtonsTouchesEndWhereTheTextDoes() {
        let field = SearchField(onPress: {}, onClear: {})
        field.text = "hello"
        field.sendActions(for: .editingChanged)
        let bounds = CGRect(x: 0, y: 0, width: 408, height: Theme.Metrics.searchFieldHeight)
        let button = field.rightViewRect(forBounds: bounds)
        #expect(abs(field.textRect(forBounds: bounds).maxX - button.minX) < 0.001)
        #expect(abs(button.width - (field.rightView!.intrinsicContentSize.width + 2 * Theme.Metrics.searchClearGap)) < 0.001)
    }

    @Test func tappingClearEmptiesTheFieldReportsTheEditAndPlaysTheHaptic() {
        var presses = 0
        var clears = 0
        var edits = 0
        let field = SearchField(onPress: { presses += 1 }, onClear: { clears += 1 })
        field.addAction(UIAction { _ in edits += 1 }, for: .editingChanged)
        field.text = "hello"
        let button = field.rightView as! UIButton
        button.sendActions(for: .touchDown)
        #expect(presses == 1)
        #expect(clears == 0)
        button.sendActions(for: .primaryActionTriggered)
        #expect(field.text == "")
        #expect(edits == 1)
        #expect(clears == 1)
    }
}
