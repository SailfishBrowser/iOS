import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

@MainActor
struct MenuLookTests {
    private func icon(background: UIColor?, glyph: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            if let background {
                background.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            glyph.setFill()
            context.fill(CGRect(x: 8, y: 4, width: 6, height: 24))
            context.fill(CGRect(x: 8, y: 4, width: 16, height: 6))
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 26, y: 26, width: 4, height: 4))
        }
    }

    private func levels(_ color: UIColor) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }

    private func near(_ color: UIColor, _ expected: [Int], within: Int) -> Bool {
        zip(levels(color), expected).allSatisfy { abs($0 - $1) <= within }
    }

    // fast.com's favicon: a red "F" on white. The greys and the white are not the site's colour.
    @Test func theTintIsTheFaviconsMostCommonColour() throws {
        let red = UIColor(red: 229 / 255, green: 9 / 255, blue: 20 / 255, alpha: 1)
        let onWhite = try #require(FaviconTint.dominant(in: icon(background: .white, glyph: red)))
        #expect(near(onWhite, [229, 9, 20], within: 2))
        let blue = UIColor(red: 30 / 255, green: 90 / 255, blue: 220 / 255, alpha: 1)
        let onClear = try #require(FaviconTint.dominant(in: icon(background: nil, glyph: blue)))
        #expect(near(onClear, [30, 90, 220], within: 2))
    }

    // The tint is worked out once, when the favicon arrives, not on every pass of the menu.
    @Test func theFaviconsTintIsKeptWithItsImage() throws {
        let red = UIColor(red: 229 / 255, green: 9 / 255, blue: 20 / 255, alpha: 1)
        let box = FaviconBox()
        #expect(box.tint == nil)
        box.image = icon(background: .white, glyph: red)
        #expect(near(try #require(box.tint), [229, 9, 20], within: 2))
        box.image = icon(background: .white, glyph: .black)
        #expect(box.tint == nil)
    }

    @Test func aFaviconWithNoColourGivesNoTint() {
        #expect(FaviconTint.dominant(in: icon(background: .white, glyph: .black)) == nil)
    }

    private func alpha(_ color: UIColor) -> CGFloat {
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    // The sheet's gradient as drawn over its material, top and bottom.
    private func gradient(_ background: MenuSheetBackground) -> (top: UIColor, bottom: UIColor) {
        let colors = (background.descendants(GradientView.self).first!.gradient.colors as! [CGColor]).map { UIColor(cgColor: $0) }
        return (colors[0], colors[1])
    }

    // The sheet: #F3F3F4 at the top, #F2D8D9 at the screen's bottom with fast.com's red at 12%, drawn over
    // the thick light material at the light look's gradient opacity; the dark look starts from #1C1C1E at its own.
    @Test func theSheetRunsFromItsTopToTheTopMixedWithTheTint() {
        let red = UIColor(red: 229 / 255, green: 9 / 255, blue: 20 / 255, alpha: 1)
        let background = MenuSheetBackground()
        background.apply(MenuLook(isLight: true, tint: red))
        let tinted = gradient(background)
        #expect(near(tinted.top, [243, 243, 244], within: 0))
        #expect(near(tinted.bottom, [242, 216, 217], within: 6))
        #expect(abs(alpha(tinted.top) - Theme.Frost.menuGradient(light: true)) < 0.001)
        #expect(abs(alpha(tinted.bottom) - Theme.Frost.menuGradient(light: true)) < 0.001)
        #expect(background.style == Theme.Frost.menu(light: true))
        background.apply(MenuLook(isLight: true, tint: nil))
        let plain = gradient(background)
        #expect(levels(plain.bottom) == levels(plain.top))
        background.apply(MenuLook(isLight: false, tint: nil))
        let dark = gradient(background)
        #expect(levels(dark.top) == levels(Theme.Palette.menuSheetDark))
        #expect(abs(alpha(dark.top) - Theme.Frost.menuGradient(light: false)) < 0.001)
        #expect(background.style == Theme.Frost.menu(light: false))
    }

    // Every element against its measured place, in points from the sheet's top or its sides, within 2 pt. The menu is
    // drawn 440 pt wide over white and measured from its pixels: a fill is darker than the white, a glyph much darker,
    // the stepper's box darker than its row.
    @Test func theMenuMatchesItsMeasurementsWithinTwoPoints() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "https://example.test/a")!)
        let controller = try #require(env.activeController)
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/a")!), responseHTML: "<p>a</p>")
        try await waitUntil(timeout: .seconds(3)) { controller.url?.host() == "example.test" }
        let tab = try #require(env.browser.activeTab)
        let width: CGFloat = 440
        let host = UIHostingController(
            rootView: MenuSheet(controller: controller, tab: tab, onLook: { _ in }, onFold: { $0() }).environment(env))
        host.safeAreaRegions = []
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.backgroundColor = .white
        host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: width, height: 900)))
        host.view.layoutIfNeeded()
        await nextDisplayFrame()
        let menu = Bitmap(host.view)
        // A fill over white reads about 230; the hairline between rows lighter, as it shows the white.
        let filled = { (value: UInt8) in value < 236 }
        let ink = { (value: UInt8) in value < 150 }
        let boxed = { (value: UInt8) in value < 223 }
        func check(_ actual: CGFloat?, _ expected: CGFloat, _ what: String) {
            #expect(actual.map { abs($0 - expected) <= 2 } == true, "\(what): \(String(describing: actual)) vs the expected \(expected)")
        }
        let inset = Theme.Metrics.menuPadding

        // Down a column inside the last tile, clear of the corners' curves, the glyphs, the labels and the rows' text and
        // stepper: the pill, the tile, then the Display Options header and each row under it, then Site Settings.
        let column = menu.runs(column: width - inset - 106, where: filled)
        try #require(column.count == 7, "\(column)")
        let (pill, tile, header, readerRow, zoomRow, desktopRow) =
            (column[0], column[1], column[2], column[3], column[4], column[5])
        let siteRow = column[6]
        check(pill.lowerBound, 16.2, "pill top")
        check(pill.upperBound - pill.lowerBound, 47.5, "pill height")
        check(tile.lowerBound, 81.4, "tiles top")
        check(tile.upperBound - tile.lowerBound, 87.4, "tile height")
        check(header.lowerBound - tile.upperBound, 208.0 - 168.8, "tile bottom to list")
        check(header.upperBound - header.lowerBound, 48.7, "header height")
        check(readerRow.lowerBound - header.upperBound, 0.5, "row gap")
        check(readerRow.upperBound - readerRow.lowerBound, 48.7, "row height")
        check(zoomRow.lowerBound - readerRow.upperBound, 0.5, "row gap")
        let chevron = try #require(menu.runs(across: header, where: ink).last)
        check(width - inset - chevron.mid, 26.5, "chevron centre")
        check(chevron.upperBound - chevron.lowerBound, 13.4, "chevron width")
        check(zoomRow.upperBound - zoomRow.lowerBound, 48.7, "row height")
        check(desktopRow.upperBound - desktopRow.lowerBound, 48.7, "row height")
        check(desktopRow.lowerBound - zoomRow.upperBound, 0.5, "row gap")
        check(siteRow.lowerBound - desktopRow.upperBound, 17.2, "list to Site Settings")
        check(siteRow.upperBound - siteRow.lowerBound, 48.7, "Site Settings height")
        check(menu.height - siteRow.upperBound, 0, "last card to the content's bottom")

        // The glyphs' extents across the pill: back and forward from its left, then the URL, then copy link and reload.
        let glyphs = menu.runs(across: pill, where: ink).merged(within: 12)
        try #require(glyphs.count >= 4, "\(glyphs)")
        check(glyphs[0].mid - inset, 25.3, "back centre")
        check(glyphs[1].mid - inset, 65.5, "forward centre")
        check(width - inset - glyphs[glyphs.count - 1].mid, 26.5, "reload centre")
        check(width - inset - glyphs[glyphs.count - 2].mid, 65.2, "copy link centre")

        // The labels under the tiles: each word group's drawn width, its glyphs' top under the tile and their height.
        let labelBand = (tile.upperBound + 1)...(header.lowerBound - 1)
        let labels = menu.runs(across: labelBand, where: ink).merged(within: 10)
        try #require(labels.count == 3, "\(labels)")
        let expectedLabels: [(name: String, width: CGFloat)] = [("Find on Page", 67.3), ("Pin", 14.7), ("Share", 29.7)]
        for (label, expected) in zip(labels, expectedLabels) {
            check(label.upperBound - label.lowerBound, expected.width, "\(expected.name) label width")
        }
        let findGlyphs = try #require(menu.runs(down: labels[0], within: labelBand, where: ink).merged(within: 2).first)
        check(findGlyphs.lowerBound - tile.upperBound, 11.2, "label glyph top under the tile")
        check(findGlyphs.upperBound - findGlyphs.lowerBound, 10.0, "label glyph height")

        // Across the tiles below their glyphs, where their sides are straight.
        let tiles = menu.runs(row: tile.mid + 20, where: filled)
        try #require(tiles.count == 3, "\(tiles)")
        check(tiles[1].lowerBound - tiles[0].upperBound, 16.2, "tile gap")
        check(tiles[0].lowerBound, inset, "tile leading")
        check(width - tiles[2].upperBound, inset, "tile trailing")

        // The zoom row: its text after the icon, and the stepper's box at the trailing end.
        let zoomMiddle = zoomRow.mid
        let zoomInk = menu.runs(across: (zoomRow.lowerBound + 2)...(zoomRow.upperBound - 2), where: ink).merged(within: 3)
        check(zoomInk.first.map { $0.mid - inset }, 29.5, "row icon centre")
        let text = menu.runs(row: zoomMiddle, where: ink).first { $0.lowerBound > inset + 45 }
        check(text.map { $0.lowerBound - inset }, 53.3, "row text inset")
        let box = try #require(menu.runs(row: zoomMiddle + 8, where: boxed).last)
        check(box.upperBound - box.lowerBound, 88.9, "stepper width")
        check(width - inset - box.upperBound, 10.2, "stepper inset")
        let boxHeight = try #require(menu.runs(column: box.lowerBound + 6, where: boxed).first { $0.contains(zoomMiddle) })
        check(boxHeight.upperBound - boxHeight.lowerBound, 31, "stepper height")
        window.isHidden = true
    }

    // Folded, Display Options hides every row under it: the menu is shorter by those rows and their gaps.
    @Test func foldingDisplayOptionsHidesItsRows() async throws {
        let env = makeEnvironment()
        env.open(URL(string: "https://example.test/a")!)
        let controller = try #require(env.activeController)
        controller.webView.loadSimulatedRequest(
            URLRequest(url: URL(string: "https://example.test/a")!), responseHTML: "<p>a</p>")
        try await waitUntil(timeout: .seconds(3)) { controller.url?.host() == "example.test" }
        let tab = try #require(env.browser.activeTab)
        let host = UIHostingController(
            rootView: MenuSheet(controller: controller, tab: tab, onLook: { _ in }, onFold: { $0() }).environment(env))
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let fits = CGSize(width: 440, height: 900)
        let expanded = host.sizeThatFits(in: fits).height
        // SwiftUI applies the change on its next update, as the host's own layout pass does.
        env.browser.settings.displayOptionsExpanded = false
        try await waitUntil { host.sizeThatFits(in: fits).height < expanded }
        let folded = host.sizeThatFits(in: fits).height
        let rows: CGFloat = 3
        #expect(abs(expanded - folded - rows * (Theme.Metrics.menuListRowHeight + Theme.Metrics.menuRowGap)) < 0.5)
        window.isHidden = true
    }
}

private extension ClosedRange<CGFloat> {
    var mid: CGFloat { (lowerBound + upperBound) / 2 }
}

private extension [ClosedRange<CGFloat>] {
    // One glyph's strokes are one shape: runs closer than `gap` join.
    func merged(within gap: CGFloat) -> [ClosedRange<CGFloat>] {
        reduce(into: []) { shapes, run in
            if let last = shapes.last, run.lowerBound - last.upperBound < gap {
                shapes[shapes.count - 1] = last.lowerBound...run.upperBound
            } else {
                shapes.append(run)
            }
        }
    }
}
