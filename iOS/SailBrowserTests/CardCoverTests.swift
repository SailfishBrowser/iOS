import SwiftUI
import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import SailBrowser

struct CardCoverTests {
    private let a = UUID()
    private let b = UUID()

    @Test func navigationInActiveTabNeverRecovers() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: true)
        #expect(cover.phase == .hold)
        #expect(cover.opacity(for: a, progress: 0) == 1)
        cover.holdElapsed(a)
        #expect(cover.phase == .fading)
        cover.fadeFinished(a)
        #expect(cover.phase == .none)
        #expect(cover.opacity(for: a, progress: 0) == 0)
        cover.becameRevealable(a)
        cover.holdElapsed(a)
        #expect(cover.phase == .none)
        #expect(cover.opacity(for: a, progress: 0) == 0)
    }

    @Test func freshControllerStaysCoveredThroughZoomUntilRevealable() {
        var cover = CardCover()
        cover.activated(a, progress: 1, revealable: false)
        #expect(cover.phase == .waiting)
        #expect(cover.opacity(for: a, progress: 0.02) == 1)
        #expect(cover.opacity(for: a, progress: 0) == 1)
        cover.becameRevealable(a)
        #expect(cover.phase == .fading)
        #expect(cover.opacity(for: a, progress: 0) == 0)
    }

    @Test func warmZoomCoverFadesOverLastEightPercent() {
        var cover = CardCover()
        cover.activated(a, progress: 1, revealable: true)
        #expect(cover.phase == .zoom)
        #expect(cover.opacity(for: a, progress: 0.5) == 1)
        #expect(abs(cover.opacity(for: a, progress: 0.04) - 0.5) < 1e-9)
        #expect(cover.opacity(for: a, progress: 0) == 0)
        #expect(cover.opacity(for: a, progress: -0.01) == 0)
        #expect(cover.opacity(for: b, progress: 0.5) == 0)
        cover.switcherOpened()
        #expect(cover.phase == .none)
        #expect(cover.opacity(for: a, progress: 0.5) == 0)
    }

    @Test func switcherOpeningKeepsWaitingCover() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: false)
        cover.switcherOpened()
        #expect(cover.phase == .waiting)
    }

    @Test func staleCallbacksForPreviousTabAreIgnored() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: true)
        cover.activated(b, progress: 0, revealable: true)
        cover.holdElapsed(a)
        #expect(cover.tabID == b)
        #expect(cover.phase == .hold)
        cover.becameRevealable(a)
        cover.fadeFinished(a)
        #expect(cover.phase == .hold)
        #expect(cover.opacity(for: a, progress: 0) == 0)
        #expect(cover.opacity(for: b, progress: 0) == 1)
    }

    @Test func aSubmittedTabAlreadyPaintedCutsInWithNoCover() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: true, cutsIn: true)
        #expect(cover.phase == .none)
        #expect(cover.opacity(for: a, progress: 0) == 0)
        cover.holdElapsed(a)
        #expect(cover.phase == .none)
    }

    @Test func aSubmittedTabNotYetPaintedHoldsItsCoverThenCutsWithNoFade() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: false, cutsIn: true)
        #expect(cover.phase == .waitingToCut)
        #expect(cover.opacity(for: a, progress: 0) == 1)
        cover.switcherOpened()
        #expect(cover.phase == .waitingToCut)
        cover.becameRevealable(b)
        #expect(cover.phase == .waitingToCut)
        cover.becameRevealable(a)
        #expect(cover.phase == .none)
        #expect(cover.tabID == nil)
        #expect(cover.opacity(for: a, progress: 0) == 0)
    }

    @MainActor @Test func aSubmittedTabWaitingToCutShowsTheBackdropAndOtherTabsKeepBlack() {
        var cover = CardCover()
        cover.activated(a, progress: 0, revealable: false, cutsIn: true)
        #expect(cover.waitsToCut)
        let tint = CodableColor(red: 0.2, green: 0.3, blue: 0.4)
        for maybeTint in [nil, tint] {
            #expect(DeckView.coverFill(tint: maybeTint, waitsToCut: cover.waitsToCut) == Theme.Palette.submitBackdrop)
        }
        cover.activated(b, progress: 0, revealable: false)
        #expect(!cover.waitsToCut)
        #expect(DeckView.coverFill(tint: nil, waitsToCut: cover.waitsToCut) == Theme.Palette.newTabPlaceholder)
        #expect(DeckView.coverFill(tint: tint, waitsToCut: false) == Color(red: 0.2, green: 0.3, blue: 0.4))
    }
}

// A cover change re-renders only the card it covers: the other cards read the covered tab's id and nothing else.
@MainActor
struct CardCoversTests {
    private let a = UUID()
    private let b = UUID()

    private final class Changed: Sendable {
        let value = Mutex(false)
    }

    private func changes(_ covers: CardCovers, readingFor card: UUID) -> Changed {
        let changed = Changed()
        withObservationTracking {
            _ = covers.cover(for: card)
        } onChange: {
            changed.value.withLock { $0 = true }
        }
        return changed
    }

    @Test func aCoverIsReadOnlyByTheCardItCovers() {
        let covers = CardCovers()
        covers.update { $0.activated(a, progress: 0, revealable: true) }
        #expect(covers.tabID == a)
        #expect(covers.cover(for: a).phase == .hold)
        #expect(covers.cover(for: b) == CardCover())
        covers.update { $0.holdElapsed(a) }
        covers.update { $0.fadeFinished(a) }
        #expect(covers.tabID == nil)
        #expect(covers.cover(for: a) == CardCover())
    }

    @Test func aFadeInvalidatesOnlyTheCoveredCard() {
        let covers = CardCovers()
        covers.update { $0.activated(a, progress: 0, revealable: true) }
        let covered = changes(covers, readingFor: a)
        let other = changes(covers, readingFor: b)
        covers.update { $0.holdElapsed(a) }
        #expect(covered.value.withLock { $0 })
        #expect(!other.value.withLock { $0 })
    }
}
