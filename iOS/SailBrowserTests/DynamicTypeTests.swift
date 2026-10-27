import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

// Settings, Archive, Downloads, Site Settings and the error page follow the user's text size; the bar, deck, search
// sheet, menu, prompt and reader keep their measured points.
struct DynamicTypeTests {
    private static let large = UITraitCollection(preferredContentSizeCategory: .large)
    private static let accessibility3 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
    private static let accessibility5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

    // The sheet labels are the text styles whose default sizes are the measured points, so they read as before at the
    // default size and grow with the system rows beside them.
    @Test func theSheetTokensAreTextStylesAtTheirMeasuredSizes() {
        let tokens: [(Font, Font.TextStyle, UIFont.TextStyle, CGFloat)] = [
            (Theme.Typography.settingsButton, .body, .body, 17),
            (Theme.Typography.archiveTitle, .callout, .callout, 16),
            (Theme.Typography.archiveDetail, .footnote, .footnote, 13),
            (Theme.Typography.downloadTitle, .callout, .callout, 16),
            (Theme.Typography.downloadDetail, .footnote, .footnote, 13),
        ]
        for (token, style, uiStyle, size) in tokens {
            #expect(token == Font.system(style))
            #expect(UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: Self.large).pointSize == size)
            #expect(UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: Self.accessibility3).pointSize > size)
        }
    }

    // The error page's fonts keep the prompt's point sizes at the default size and carry their text style, so a label
    // that adjusts for the content size category grows them; the glyph's style is the prompt's 34 points.
    @Test func theErrorPageFontsScaleFromTheirMeasuredSizes() {
        #expect(UIFont.preferredFont(forTextStyle: Theme.Network.errorGlyphStyle, compatibleWith: Self.large).pointSize == 34)
        let fonts: [(UIFont, CGFloat, UIFont.Weight)] = [
            (Theme.Network.errorTitleFont, 20, .semibold), (Theme.Network.errorDetailFont, 15, .regular),
            (Theme.Network.errorButtonFont, 17, .semibold),
        ]
        let window = makeWindow(at: .accessibilityExtraLarge)
        defer { window.isHidden = true }
        for (font, size, weight) in fonts {
            #expect(font.pointSize == size)
            #expect(font.fontName == UIFont.systemFont(ofSize: size, weight: weight).fontName)
            let label = UILabel()
            label.font = font
            label.adjustsFontForContentSizeCategory = true
            window.addSubview(label)
            #expect(label.font.pointSize > size, "\(font.fontName) \(size)")
        }
    }

    // The Downloads capsule is the first Settings row: 40 points at the default size, and at least its label's line
    // at the largest size.
    @Test func theSettingsCapsuleGrowsWithItsLabel() async throws {
        let env = makeEnvironment()
        let atLarge = try await firstRowHeight(SettingsView(blocklistVersion: "1").environment(env), size: .large)
        #expect(atLarge >= Theme.Metrics.settingsButtonHeight, "\(atLarge)")
        let atLargest = try await firstRowHeight(
            SettingsView(blocklistVersion: "1").environment(env), size: .accessibility5)
        let line = UIFont.preferredFont(forTextStyle: .body, compatibleWith: Self.accessibility5).lineHeight
        #expect(atLargest >= line, "\(atLargest) under \(line)")
    }

    // A download row holds its title and detail lines at the largest size.
    @Test func aDownloadRowHoldsItsTwoLinesAtTheLargestSize() async throws {
        let env = makeEnvironment()
        env.downloads.insertForTesting([
            DownloadRecord(
                id: UUID(), filename: "a.zip", sourceURL: URL(string: "https://example.test/a.zip")!, bytes: 4096,
                total: 4096, state: .finished, date: .now),
        ])
        let height = try await firstRowHeight(DownloadsView().environment(env), size: .accessibility5)
        let title = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: Self.accessibility5).lineHeight
        let detail = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: Self.accessibility5).lineHeight
        #expect(height >= title + detail, "\(height) under \(title + detail)")
    }

    // Hosts the sheet in a window at the text size and reads the first row's height off the list's first cell.
    private func firstRowHeight(_ sheet: some View, size: DynamicTypeSize) async throws -> CGFloat {
        let host = UIHostingController(rootView: sheet.environment(\.dynamicTypeSize, size))
        let window = makeWindow(at: .large)
        defer { window.isHidden = true }
        window.rootViewController = host
        host.view.layoutIfNeeded()
        try await waitUntil { !descendants(of: host.view, UICollectionView.self).flatMap(\.visibleCells).isEmpty }
        let list = descendants(of: host.view, UICollectionView.self).first!
        let first = try #require(list.cellForItem(at: IndexPath(item: 0, section: 0)))
        return first.bounds.height
    }
}

// A phone-sized window at the text size; what is added to it lays out under that size.
func makeWindow(at category: UIContentSizeCategory) -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    window.traitOverrides.preferredContentSizeCategory = category
    window.makeKeyAndVisible()
    return window
}

func descendants<T: UIView>(of view: UIView, _ type: T.Type) -> [T] {
    view.subviews.flatMap { subview in
        [subview as? T].compactMap { $0 } + descendants(of: subview, type)
    }
}
