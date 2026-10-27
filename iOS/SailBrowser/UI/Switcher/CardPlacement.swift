import SwiftUI

struct CardGeometry: Equatable {
    static func identity(height: CGFloat) -> CardGeometry {
        CardGeometry(scale: 1, offset: .zero, corner: 0, opacity: 1, clipHeight: height)
    }

    var scale: CGFloat
    var offset: CGSize
    var corner: CGFloat
    var opacity: CGFloat
    var clipHeight: CGFloat
    var clipTop: CGFloat = 0

    var clip: CardClip {
        CardClip(corner: corner / scale, top: clipTop / scale, height: clipHeight / scale)
    }
}

struct CardClip: Shape {
    let corner: CGFloat
    let top: CGFloat
    let height: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: corner)
            .path(in: CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: min(height, rect.height) - top))
    }
}

extension View {
    func placed(_ geometry: CardGeometry) -> some View {
        scaleEffect(geometry.scale)
            .offset(geometry.offset)
            .opacity(geometry.opacity)
    }

    func placedAndClipped(_ geometry: CardGeometry) -> some View {
        clipShape(geometry.clip)
            .placed(geometry)
    }
}

struct CardPlacement<Header: View>: ViewModifier {
    @Environment(\.screenInsets) private var screenInsets
    let progress: CGFloat
    let olderProgress: CGFloat
    // The cards a swipe on the bar or the tab stack's flick moves, while the deck is closed.
    let pair: DeckDriver.PagePair?
    // The flick to the previous tab, while the deck is closed.
    let flick: DeckDriver.Flick?
    let position: CGFloat
    let lift: CGFloat
    let slot: CGFloat
    let index: Int
    let activeIndex: Int
    let layout: CardLayout
    let header: Header
    let coverImage: UIImage?
    let coverFill: Color
    let isUnrevealed: Bool
    let cover: CardCover
    let tabID: UUID
    let isPrivate: Bool

    init(
        progress: CGFloat, olderProgress: CGFloat, pair: DeckDriver.PagePair?, flick: DeckDriver.Flick?,
        position: CGFloat,
        lift: CGFloat, slot: CGFloat,
        index: Int, activeIndex: Int,
        layout: CardLayout, header: Header, coverImage: UIImage?, coverFill: Color, isUnrevealed: Bool,
        cover: CardCover, tabID: UUID, isPrivate: Bool = false
    ) {
        self.progress = progress
        self.olderProgress = olderProgress
        self.pair = pair
        self.flick = flick
        self.position = position
        self.lift = lift
        self.slot = slot
        self.index = index
        self.activeIndex = activeIndex
        self.layout = layout
        self.header = header
        self.coverImage = coverImage
        self.coverFill = coverFill
        self.isUnrevealed = isUnrevealed
        self.cover = cover
        self.tabID = tabID
        self.isPrivate = isPrivate
    }

    var transform: CardTransform {
        if let flick {
            if tabID == flick.from {
                return layout.flickLive(arm: flick.arm, drop: flick.drop)
            }
            var t = layout.flickIncoming(
                offset: flick.offset, grab: flick.grab, grow: flick.grow, land: flick.land, safeTop: flick.safeTop)
            if tabID != flick.to {
                t.opacity = 0
            }
            return t
        }
        if let pair {
            return pairTransform(pair)
        }
        return layout.transform(
            slot: slot, isActive: index == activeIndex, activeIndex: activeIndex, position: position,
            progress: progress, olderProgress: olderProgress)
    }

    // A card's place is its side of the page the swipe started on. The older card is out of the tab stack as far as it has
    // emerged; the page left dives into it on a newer-tab landing; the newer card shows once the pair arms or it is
    // mostly in. Every other card is hidden.
    private func pairTransform(_ pair: DeckDriver.PagePair) -> CardTransform {
        let side: CGFloat? =
            tabID == pair.originID ? 0 : tabID == pair.older ? -1 : tabID == pair.newer ? 1 : nil
        let offset = (side ?? 0) - (position - CGFloat(pair.origin))
        let fromStack = side == -1 ? 1 - pair.emerge : side == 0 ? pair.dive : 0
        var t = layout.pairTransform(offset: offset, fromStack: fromStack, arm: pair.arm, safeTop: pair.safeTop)
        if side == nil || side == 1 && pair.arm == 0 && offset >= 0.5 {
            t.opacity = 0
        }
        return t
    }

    var geometry: CardGeometry {
        let t = transform
        return CardGeometry(
            scale: t.scale, offset: CGSize(width: t.offset.width, height: t.offset.height + lift), corner: t.corner,
            opacity: t.opacity, clipHeight: t.clipHeight, clipTop: t.clipTop)
    }

    var contentGeometry: CardGeometry {
        index == activeIndex ? geometry : CardGeometry.identity(height: layout.screen.height)
    }

    var showsCover: Bool {
        isUnrevealed || cover.tabID == tabID && (coverImage != nil || [.waiting, .waitingToCut, .fading].contains(cover.phase))
    }

    var coverOpacity: CGFloat {
        isUnrevealed ? 1 : cover.opacity(for: tabID, progress: progress)
    }

    // The active card's page shows through as the deck zooms in, so the zoom shows no step. A swipe on the bar shows
    // its pages; every other private card stays covered, the flick's rising card too.
    var privateCoverOpacity: CGFloat {
        index == activeIndex || pair != nil ? progress : 1
    }

    // What lies over the dimmed content inside the card's clip: the snapshot or fill cover, the private band under
    // it and the private cover.
    var covers: some View {
        ZStack {
            if showsCover {
                Group {
                    if let coverImage {
                        Image(uiImage: coverImage).resizable()
                    } else {
                        coverFill
                    }
                }
                .opacity(coverOpacity)
                .transition(.identity)
            }
            // A private page waiting for its first paint keeps the band the submit cover showed.
            if isPrivate && showsCover {
                PrivateBand(safeTop: screenInsets.top)
                    .frame(height: screenInsets.top + Theme.Metrics.privateBandExtra)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(coverOpacity)
            }
            if isPrivate {
                PrivateCardCover()
                    .opacity(privateCoverOpacity)
            }
        }
    }

    func body(content: Content) -> some View {
        let t = transform
        let g = geometry
        let isActive = index == activeIndex
        let screen = layout.screen
        let unplaced = CardGeometry.identity(height: screen.height)
        let inner = contentGeometry
        let outer = isActive ? unplaced : g
        let clip = g.clip
        let inverse = 1 / layout.restScale
        #if DEBUG
        if isActive {
            DebugProfiler.markUpdate(progress: progress)
        }
        #endif
        return ZStack {
            content
                .overlay(clip.fill(Color.black.opacity(t.dim)).placed(inner).allowsHitTesting(false))
                .clipShape(isActive ? unplaced.clip : clip)
            covers
                .frame(width: screen.width, height: screen.height)
                .clipShape(clip)
                .placed(inner)
                .allowsHitTesting(false)
            Color.clear
                .frame(width: screen.width, height: screen.height)
                .overlay(alignment: .topLeading) {
                    header
                        .environment(\.cardTitleOpacity, t.titleOpacity)
                        .frame(
                            width: layout.cardSize.width, height: Theme.Metrics.cardHeaderHeight, alignment: .leading)
                        .scaleEffect(inverse, anchor: .bottomLeading)
                        .offset(y: -(Theme.Metrics.cardHeaderHeight + Theme.Metrics.cardHeaderGap * inverse))
                        .opacity(t.headerOpacity)
                }
                .placed(inner)
                .allowsHitTesting(false)
        }
        .frame(width: screen.width, height: screen.height)
        .rotationEffect(
            isActive ? .zero : t.rotation, anchor: UnitPoint(x: 0.5, y: g.clipHeight / g.scale / 2 / screen.height))
        .placed(outer)
        .zIndex(t.zIndex)
    }
}
