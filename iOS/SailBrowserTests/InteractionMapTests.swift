import Testing
import UIKit
@testable import SailBrowser

struct InteractionMapTests {
    private static let medium = Theme.Haptic.medium

    private static let feedback: [Interaction: HapticFeedback?] = [
        .launch: nil, .foregroundRaise: nil,
        .tabStackTap: medium, .tabStackFlick: medium, .pinchSwitcher: medium,
        .deckCardTap: nil, .deckBackgroundTap: nil, .deckScroll: nil, .deckSettle: medium,
        .cardLift: nil, .cardArchiveArm: nil, .cardThrow: nil, .cardReturn: nil,
        .deckEmptied: nil,
        .plusTap: medium, .searchTyping: nil, .searchClear: medium, .suggestionTap: medium, .searchSubmit: nil,
        .searchDragDismiss: nil, .searchDragReturn: nil, .searchDimTap: nil, .searchGrabDuringOpen: nil,
        .menuGrabDuringOpen: nil,
        .pullTick: Theme.Haptic.refreshTicks[0], .pullArm: Theme.Haptic.refreshArm,
        .pullRelease: nil, .refreshLand: Theme.Haptic.refreshLand,
        .barHide: nil, .barShow: nil, .barIntro: nil, .barSwipe: nil, .barSwipeTick: .selection, .barSwipeSettle: nil,
        .chevronTap: medium, .chevronLongPress: Theme.Haptic.rigid,
        .barTranslate: medium,
        .menuDragDismiss: nil, .menuDragReturn: nil, .menuDimTap: nil,
        .menuNav: medium, .menuCopyLink: .notification(.success), .menuAddressEdit: nil, .menuAddressSubmit: nil,
        .pin: .selection, .unpin: .selection, .displayOptionsToggle: medium, .menuFind: medium, .menuShare: medium, .zoomStep: .selection,
        .desktopToggle: medium, .menuTranslate: medium, .restorePage: medium,
        .readerOpen: medium, .readerClose: medium, .readerDragDismiss: nil, .readerDragReturn: nil,
        .archiveOpen: medium, .settingsOpen: medium, .archiveRestore: medium, .archiveDelete: nil,
        .settingsChange: nil, .clearData: .notification(.success), .sheetDone: nil,
        .webEdgeSwipe: nil,
        .recentArm: medium, .recentRemove: nil, .recentReturn: nil,
        .permissionAnswer: medium,
        .privateToggle: medium,
    ]

    private static let budgets: [Interaction: LatencyBudget] = [
        .launch: .timed, .foregroundRaise: .system,
        .tabStackTap: .frames(2), .tabStackFlick: .frames(2), .pinchSwitcher: .frames(2),
        .deckCardTap: .frames(2), .deckBackgroundTap: .frames(2), .deckScroll: .frames(2), .deckSettle: .frames(2),
        .cardLift: .frames(2), .cardArchiveArm: .frames(0), .cardThrow: .frames(2), .cardReturn: .frames(2),
        .deckEmptied: .frames(2),
        .plusTap: .frames(2), .searchTyping: .frames(2), .searchClear: .frames(2), .suggestionTap: .frames(2),
        .searchSubmit: .frames(2),
        .searchDragDismiss: .frames(2), .searchDragReturn: .frames(2), .searchDimTap: .frames(2),
        .searchGrabDuringOpen: .frames(2), .menuGrabDuringOpen: .frames(2),
        .pullTick: .frames(0), .pullArm: .frames(0), .pullRelease: .frames(2), .refreshLand: .timed,
        .barHide: .frames(2), .barShow: .frames(2), .barIntro: .timed,
        .barSwipe: .frames(2), .barSwipeTick: .frames(0), .barSwipeSettle: .frames(2),
        .chevronTap: .frames(2), .chevronLongPress: .system,
        .barTranslate: .frames(2),
        .menuDragDismiss: .frames(2), .menuDragReturn: .frames(2), .menuDimTap: .frames(2),
        .menuNav: .frames(2), .menuCopyLink: .frames(2), .menuAddressEdit: .frames(2), .menuAddressSubmit: .frames(2),
        .pin: .frames(2), .unpin: .frames(2), .displayOptionsToggle: .frames(2), .menuFind: .frames(2), .menuShare: .frames(2), .zoomStep: .frames(2),
        .desktopToggle: .frames(2), .menuTranslate: .frames(2), .restorePage: .frames(2),
        .readerOpen: .frames(2), .readerClose: .frames(2), .readerDragDismiss: .frames(2), .readerDragReturn: .frames(2),
        .archiveOpen: .system, .settingsOpen: .system, .archiveRestore: .frames(2), .archiveDelete: .system,
        .settingsChange: .system, .clearData: .timed, .sheetDone: .system,
        .webEdgeSwipe: .system,
        .recentArm: .frames(0), .recentRemove: .frames(2), .recentReturn: .frames(2),
        .permissionAnswer: .frames(2),
        .privateToggle: .frames(2),
    ]

    @Test func everyInteractionMapsToTheInventory() {
        #expect(Interaction.allCases.count == 70)
        #expect(Self.feedback.count == 70)
        #expect(Self.budgets.count == 70)
        for interaction in Interaction.allCases {
            let played = Theme.Feedback.event(for: interaction).map { Theme.Feedback.feedback(for: $0) }
            #expect(played == Self.feedback[interaction]!, "\(interaction)")
            #expect(Theme.Latency.budget(for: interaction) == Self.budgets[interaction], "\(interaction)")
        }
        #expect(Theme.Feedback.event(for: .pin) == .pinToggled)
        #expect(Theme.Feedback.event(for: .deckBackgroundTap) == nil)
        #expect(Theme.Feedback.event(for: .permissionAnswer) == .buttonTap)
    }

    @Test func seventeenEvents() {
        #expect(HapticEvent.allCases.count == 17)
    }

    // A pull's tick plays the step it reached; every other event ignores the step.
    @Test func aPullTickPlaysItsStep() {
        let ticks = Theme.Haptic.refreshTicks.indices.map { Theme.Feedback.feedback(for: .refreshNearing, step: $0) }
        #expect(ticks == Theme.Haptic.refreshTicks)
        #expect(Theme.Feedback.feedback(for: .buttonTap, step: 2) == Theme.Haptic.medium)
    }

    @Test func everyInteractionWithMotionUsesItsToken() {
        let m = Theme.Motion.self
        let expected: [Interaction: MotionToken] = [
            .launch: .keyboard, .foregroundRaise: m.searchOpen, .plusTap: m.searchOpen, .menuAddressEdit: .keyboard,
            .tabStackTap: m.deckZoom, .pinchSwitcher: m.deckZoom, .deckCardTap: m.deckZoom, .deckBackgroundTap: m.deckZoom,
            .archiveRestore: m.deckZoom,
            .tabStackFlick: m.deckZoom, .deckSettle: m.deckSnap, .cardReturn: m.deckSnap,
            .cardThrow: m.archiveGapClose, .deckEmptied: m.emptyDeckAppear,
            .suggestionTap: m.submitFadeOut, .searchSubmit: m.submitFadeOut,
            .searchDragReturn: m.searchReturn, .searchDragDismiss: m.searchReleaseClose, .searchDimTap: m.searchTapClose,
            .pullRelease: m.refreshRelease,
            .barHide: m.bar, .barShow: m.bar, .barIntro: m.bar, .barSwipeSettle: m.deckZoom,
            .chevronTap: m.menuOpen, .menuDragDismiss: m.menuClose, .menuDragReturn: m.menuReturn,
            .menuDimTap: m.menuClose, .menuAddressSubmit: m.menuClose, .displayOptionsToggle: m.menuFold, .menuFind: m.menuClose, .menuShare: m.menuClose,
            .menuTranslate: m.menuClose,
            .restorePage: m.menuClose,
            .menuNav: m.press, .menuCopyLink: m.press, .pin: m.press, .unpin: m.press,
            .recentRemove: m.recentCollapse, .recentReturn: m.recentReturn,
            .readerOpen: m.readerOpen, .readerClose: m.readerClose, .readerDragDismiss: m.readerClose,
            .readerDragReturn: m.readerReturn,
            .permissionAnswer: m.permissionSheet,
            .privateToggle: m.privateToggle,
        ]
        for interaction in Interaction.allCases {
            #expect(Theme.Motion.token(for: interaction) == expected[interaction], "\(interaction)")
        }
    }
}
