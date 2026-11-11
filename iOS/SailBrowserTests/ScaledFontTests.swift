import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// The chrome's text is its measured points at the default text size, grows and shrinks with the user's text size in
// step with the system's text of its style, and holds at the largest size before the accessibility sizes.
struct ScaledFontTests {
    private let font = ScaledFont(size: 15, weight: .semibold, style: .subheadline)

    private static func system(_ style: UIFont.TextStyle, at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
    }

    @Test func theDefaultSizeIsTheMeasuredSize() {
        #expect(font.pointSize(at: .large) == 15)
        #expect(ScaledFont(size: 11.5, style: .subheadline).pointSize(at: .large) == 11.5)
        #expect(font.uiFont(at: .large).pointSize == 15)
        #expect(font.uiFont(at: .large).fontName == UIFont.systemFont(ofSize: 15, weight: .semibold).fontName)
    }

    // Text at its style's default size is the system's text at every size, and other sizes keep their ratio to it.
    @Test func itStepsWithItsStylesText() {
        let body = ScaledFont(size: 17, weight: .medium, style: .body)
        var previous: CGFloat = 0
        for size in DynamicTypeSize.allCases where size <= ScaledFont.largest {
            #expect(body.pointSize(at: size) == Self.system(.body, at: size), "\(size)")
            let expected = 15 * Self.system(.subheadline, at: size) / Self.system(.subheadline, at: .large)
            #expect(abs(font.pointSize(at: size) - expected) < 0.001, "\(size)")
            #expect(font.pointSize(at: size) >= previous, "\(size)")
            previous = font.pointSize(at: size)
        }
        #expect(font.pointSize(at: .xSmall) < 15)
        #expect(font.pointSize(at: .xxxLarge) > 15)
    }

    @Test func itHoldsThroughTheAccessibilitySizes() {
        let largest = font.pointSize(at: ScaledFont.largest)
        for size in DynamicTypeSize.allCases where size > ScaledFont.largest {
            #expect(font.pointSize(at: size) == largest, "\(size)")
        }
    }

    @Test func uiKitTextTakesTheSizeFromItsTraits() {
        let traits = UITraitCollection(preferredContentSizeCategory: .extraExtraLarge)
        #expect(font.uiFont(compatibleWith: traits).pointSize == font.pointSize(at: .xxLarge))
        let unspecified = UITraitCollection(preferredContentSizeCategory: .unspecified)
        #expect(font.uiFont(compatibleWith: unspecified).pointSize == 15)
    }
}
