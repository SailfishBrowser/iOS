import SwiftUI
import Testing
@testable import SailBrowser

struct CardPlacementTests {
    private let layout = CardLayout(screen: CGSize(width: 440, height: 956))

    private func placement(
        slot: CGFloat? = nil, lift: CGFloat = 0, index: Int, position: CGFloat, progress: CGFloat = 1, isUnrevealed: Bool = false, cover: CardCover = CardCover(),
        tabID: UUID = UUID()
    ) -> CardPlacement<EmptyView> {
        CardPlacement(
            progress: progress, olderProgress: progress, pair: nil, flick: nil, position: position, lift: lift, slot: slot ?? CGFloat(index), index: index, activeIndex: 1,
            layout: layout, header: EmptyView(), coverImage: nil, coverFill: .black, isUnrevealed: isUnrevealed,
            cover: cover, tabID: tabID)
    }

    private func frame(_ t: CardTransform) -> CGRect {
        let screen = layout.screen
        let width = screen.width * t.scale
        return CGRect(
            x: screen.width / 2 + t.offset.width - width / 2,
            y: screen.height / 2 + t.offset.height - screen.height * t.scale / 2, width: width, height: t.clipHeight)
    }

    private func rendered(_ placement: CardPlacement<EmptyView>) throws -> UIImage {
        let renderer = ImageRenderer(content: Color.white.modifier(placement))
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private func grey(_ image: UIImage, at point: CGPoint) -> Int? {
        let rgb = pixel(image, at: CGPoint(x: point.x / image.size.width, y: point.y / image.size.height))
        return rgb.allSatisfy { $0 == rgb[0] } ? rgb[0] : nil
    }

    // The cover group holds the snapshot cover, the private band and the private cover; the dim rides on the content
    // inside its own clip, not in a second clipped group per card.
    @Test func theCoverGroupCarriesNoDim() throws {
        let covers = placement(index: 0, position: 1).covers
        let tree = try #require(Mirror(reflecting: covers).children.first?.value)
        let layers = try #require(Mirror(reflecting: tree).descendant("content", "value"))
        #expect(Mirror(reflecting: layers).children.count == 3)
    }

    // The dim darkens the card and nothing else: a left card's content inside its clip, and the active card's where its
    // content is placed.
    @Test func theDimDarkensTheCardAlone() throws {
        let left = placement(index: 0, position: 1)
        let card = frame(left.transform)
        let inside = CGPoint(x: card.midX, y: card.midY)
        let outside = CGPoint(x: card.maxX + 60, y: card.midY)
        #expect(abs(left.transform.dim - 0.15) < 1e-9)
        let leftImage = try rendered(left)
        let leftInside = try #require(grey(leftImage, at: inside))
        #expect(abs(leftInside - 217) <= 2)
        #expect(grey(leftImage, at: outside) == 0)

        let active = placement(index: 1, position: 2)
        #expect(frame(active.transform) == card)
        let activeImage = try rendered(active)
        let activeInside = try #require(grey(activeImage, at: inside))
        #expect(abs(activeInside - 217) <= 2)
        #expect(grey(activeImage, at: outside) == 255)
    }

    @Test func archivedGapClosesThroughThePresentedSlot() {
        let start = placement(index: 3, position: 1).transform.offset.width
        let end = placement(index: 2, position: 1).transform.offset.width
        let halfway = placement(slot: 2.5, index: 3, position: 1).transform.offset.width
        #expect(halfway < start)
        #expect(halfway > end)
    }

    @Test func onlyTheActiveCardHandsItsGeometryToItsContent() {
        let active = placement(index: 1, position: 1, progress: 0.4)
        #expect(active.contentGeometry == active.geometry)
        let neighbor = placement(index: 2, position: 1, progress: 0.4)
        #expect(neighbor.contentGeometry == CardGeometry.identity(height: layout.screen.height))
    }

    @Test func liftKeepsFullOpacity() {
        let lifted = placement(lift: -600, index: 1, position: 1)
        let t = lifted.transform
        let geometry = lifted.geometry
        #expect(geometry.scale == t.scale)
        #expect(geometry.corner == t.corner)
        #expect(geometry.clipHeight == t.clipHeight)
        #expect(geometry.offset == CGSize(width: t.offset.width, height: t.offset.height - 600))
        #expect(geometry.opacity == 1)
    }

    @Test func unrevealedActiveTabIsCoveredBeforeItsCoverActivates() {
        let fresh = placement(index: 1, position: 1, progress: 0, isUnrevealed: true)
        #expect(fresh.showsCover)
        #expect(fresh.coverOpacity == 1)
        let painted = placement(index: 1, position: 1, progress: 0)
        #expect(!painted.showsCover)
    }

    @Test func fillCoverStaysThroughItsFadeOnceThePageIsRevealable() {
        let id = UUID()
        var cover = CardCover()
        cover.activated(id, progress: 0, revealable: false)
        let waiting = placement(index: 1, position: 1, progress: 0, cover: cover, tabID: id)
        #expect(waiting.showsCover)
        #expect(waiting.coverOpacity == 1)
        cover.becameRevealable(id)
        let fading = placement(index: 1, position: 1, progress: 0, cover: cover, tabID: id)
        #expect(fading.showsCover)
        #expect(fading.coverOpacity == 0)
        cover.fadeFinished(id)
        #expect(!placement(index: 1, position: 1, progress: 0, cover: cover, tabID: id).showsCover)
    }

    @Test func warmTabWithoutSnapshotNeverShowsItsFill() {
        let id = UUID()
        var cover = CardCover()
        cover.activated(id, progress: 0, revealable: true)
        #expect(!placement(index: 1, position: 1, progress: 0, cover: cover, tabID: id).showsCover)
    }
}
