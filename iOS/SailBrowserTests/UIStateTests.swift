import CoreGraphics
import QuartzCore
import Testing
@testable import SailBrowser

struct UIStateTests {
    @Test func everyDeckChangeSaysWhetherItAnimates() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1)
        #expect(ui.deck.isAnimating)
        ui.setDeck(0, animated: false)
        #expect(!ui.deck.isAnimating && ui.deck.progress == 0 && ui.deck.barProgress == 0)
        ui.close(animated: true, deckTo: 1)
        #expect(ui.deck.isAnimating)
        ui.close(animated: false, deckTo: 0)
        #expect(!ui.deck.isAnimating && ui.deck.progress == 0)
    }

    // The loading ring's fade with the zoom still runs on SwiftUI's clock, so it holds the 120 Hz vote while it runs.
    @Test func theLoadingRingHoldsTheVoteThroughTheZoomSpring() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1)
        #expect(FrameRateVote.heldUntil >= CACurrentMediaTime() + Theme.Motion.zoom.settlingDuration - 0.05)
    }

    // The behind card and its dim follow the shrink on Core Animation, so the state says which motion each change runs.
    @Test func everySearchShrinkSaysHowTheBehindFollowsIt() {
        let ui = UIState(haptics: recordingHaptics())
        #expect(ui.open(.search))
        #expect(ui.searchShrinkMotion == UIState.ShrinkMotion(token: .keyboard, velocity: 0))
        ui.close()
        #expect(ui.searchShrink == 0)
        #expect(
            ui.searchShrinkMotion
                == UIState.ShrinkMotion(
                    token: Theme.Motion.searchBehindClose, velocity: Theme.Motion.searchBehindCloseVelocity))
        #expect(ui.open(.search, animated: false))
        #expect(ui.searchShrinkMotion == nil)
        ui.close(animated: false)
        #expect(ui.searchShrinkMotion == nil)
        #expect(ui.open(.search))
        ui.submitSearch(onHidden: {}, onCancel: {})
        ui.submitHidden()
        #expect(ui.searchShrink == 0)
        #expect(ui.searchShrinkMotion == nil)
    }

    @Test func presentWhileOverlayUpIsRejected() {
        let ui = UIState(haptics: recordingHaptics())
        #expect(ui.open(.search))
        #expect(!ui.open(.menu))
        #expect(ui.overlay == .search)
        #expect(!ui.open(.search))
        #expect(ui.overlay == .search)
    }

    @Test func nonAnimatedOpenAndCloseWithDeckAreImmediate() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1, animated: false)
        #expect(ui.open(.search, animated: false))
        #expect(ui.searchShrink == 1)

        ui.close(deckTo: 0)
        #expect(ui.overlay == .none)
        #expect(ui.searchShrink == 0)
        #expect(ui.deckProgress == 0)
    }

    // A tap on the drawn page menu early in a zoom-out opens it and turns the zoom back to browsing.
    @Test func theDrawnMenuEarlyInAZoomOutOpensAndTurnsTheZoomBack() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1)
        #expect(!ui.deck.barsShowDeck)
        #expect(ui.open(.menu))
        #expect(ui.overlay == .menu)
        #expect(ui.deckProgress == 0)
        #expect(ui.deck.isAnimating)
    }

    @Test func siteSettingsReplaceTheMenuAsASheetAndCloseBackToThePage() {
        let ui = UIState(haptics: recordingHaptics())
        #expect(ui.open(.menu))
        ui.close()
        #expect(ui.openSiteSettings(for: "kept.test"))
        #expect(ui.presentedSheet.wrappedValue == .siteSettings)
        #expect(ui.siteSettingsHost == "kept.test")

        ui.presentedSheet.wrappedValue = nil
        #expect(ui.overlay == .none)
        #expect(ui.deckProgress == 0)
    }

    // At rest each bar's controls open only where that bar is drawn.
    @Test func placementFollowsDeckProgress() {
        let ui = UIState(haptics: recordingHaptics())
        #expect(!ui.open(.archive))
        #expect(!ui.open(.settings))
        #expect(ui.open(.menu))
        ui.close()

        ui.setDeck(1, animated: false)
        #expect(!ui.open(.menu))
        #expect(ui.open(.settings))
        #expect(ui.overlay == .settings)
        ui.close()
        #expect(ui.open(.search))
    }

    @Test func presentedSheetMapsOverlayAndNilCloses() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1, animated: false)
        #expect(ui.presentedSheet.wrappedValue == nil)
        ui.open(.archive)
        #expect(ui.presentedSheet.wrappedValue == .archive)

        ui.presentedSheet.wrappedValue = nil
        #expect(ui.overlay == .none)

        ui.open(.search)
        ui.presentedSheet.wrappedValue = nil
        #expect(ui.overlay == .search)
    }

    @Test func submitFadesOutAndWaitsForTheHiddenStep() {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1, animated: false)
        ui.open(.search, animated: false)
        var calls = 0
        ui.submitSearch(onHidden: { calls += 1 }, onCancel: {})
        #expect(ui.overlay == .none)
        #expect(ui.isSubmitting)
        #expect(ui.isBarIntroPending)
        #expect(ui.behindOpacity == 0)
        #expect(calls == 0)
    }

    @Test func hiddenStepOpensTheTabAndRevealsInTheSameCall() async {
        let ui = UIState(haptics: recordingHaptics())
        ui.setDeck(1, animated: false)
        ui.open(.search, animated: false)
        var opacities: [CGFloat] = []
        ui.submitSearch(onHidden: { opacities.append(ui.behindOpacity) }, onCancel: {})
        ui.submitHidden()
        #expect(opacities == [0])
        #expect(ui.behindOpacity == 1)
        #expect(ui.searchShrink == 0)
        #expect(ui.deckProgress == 0)
        #expect(!ui.isSubmitting)
        #expect(ui.isBarIntroPending)
        ui.submitHidden()
        #expect(opacities == [0])
        #expect(ui.barIntroTask == nil)
    }

    @Test func barIntroIsScheduledOnlyWhenAskedAndEndsAfterTheDelay() async {
        let haptics = recordingHaptics()
        let ui = UIState(haptics: haptics)
        ui.open(.search, animated: false)
        ui.submitSearch(onHidden: {}, onCancel: {})
        ui.submitHidden()
        #expect(ui.barIntroTask == nil)
        #expect(ui.isBarIntroPending)

        ui.scheduleBarIntro()
        let task = ui.barIntroTask
        #expect(task != nil)
        #expect(ui.isBarIntroPending)
        #expect(haptics.records.isEmpty)
        await task?.value
        #expect(!ui.isBarIntroPending)
        #expect(haptics.records.map(\.interaction) == [.barIntro])
        #expect(haptics.records.map(\.played) == [false])
    }

    @Test func barIntroIsNotScheduledOnceTheUserEndedIt() {
        let ui = UIState(haptics: recordingHaptics())
        ui.open(.search, animated: false)
        ui.submitSearch(onHidden: {}, onCancel: {})
        ui.submitHidden()
        ui.endBarIntro()
        ui.scheduleBarIntro()
        #expect(ui.barIntroTask == nil)
    }

    @Test func barIntroEndsAfterDelayOrOnUserScroll() {
        let haptics = recordingHaptics()
        let ui = UIState(haptics: haptics)
        ui.open(.search, animated: false)
        #expect(!ui.isBarIntroPending)
        ui.submitSearch(onHidden: {}, onCancel: {})
        #expect(ui.isBarIntroPending)
        ui.endBarIntro()
        #expect(!ui.isBarIntroPending)
        #expect(haptics.records.isEmpty)
    }

    @Test func aScrollDuringTheIntroDelayLeavesNoBarIntroRecord() async {
        let haptics = recordingHaptics()
        let ui = UIState(haptics: haptics)
        ui.open(.search, animated: false)
        ui.submitSearch(onHidden: {}, onCancel: {})
        ui.submitHidden()
        ui.scheduleBarIntro()
        let task = ui.barIntroTask
        ui.endBarIntro()
        await task?.value
        #expect(!ui.isBarIntroPending)
        #expect(haptics.records.isEmpty)
    }

    @Test func canOpenIsTheGuardHalfOfOpen() {
        let ui = UIState(haptics: recordingHaptics())
        for overlay: UIState.Overlay in [.none, .search, .menu, .archive, .settings, .siteSettings] {
            #expect(ui.canOpen(overlay) == (overlay == .search || overlay == .menu || overlay == .siteSettings))
        }
        ui.setDeck(1, animated: false)
        #expect(ui.canOpen(.archive) && ui.canOpen(.settings) && !ui.canOpen(.menu) && !ui.canOpen(.siteSettings))
        #expect(ui.open(.archive))
        for overlay: UIState.Overlay in [.none, .search, .menu, .archive, .settings, .siteSettings] {
            #expect(!ui.canOpen(overlay))
        }
    }

    @Test func openingSearchDuringSubmitRestoresBehind() async throws {
        let ui = UIState(haptics: recordingHaptics())
        ui.open(.search, animated: false)
        var calls = 0
        ui.submitSearch(onHidden: { calls += 1 }, onCancel: {})
        #expect(ui.behindOpacity == 0)
        #expect(ui.open(.search))
        #expect(ui.behindOpacity == 1)
        #expect(!ui.isSubmitting)
        #expect(!ui.isBarIntroPending)
        #expect(ui.overlay == .search)
        ui.submitHidden()
        #expect(calls == 0)
        #expect(ui.behindOpacity == 1)
        #expect(ui.overlay == .search)
    }

    @Test func reopeningSearchMidSubmitCancelsOnceAndTheHiddenStepNeverRuns() {
        let ui = UIState(haptics: recordingHaptics())
        ui.open(.search, animated: false)
        var hidden = 0
        var cancelled = 0
        ui.submitSearch(onHidden: { hidden += 1 }, onCancel: { cancelled += 1 })
        #expect(cancelled == 0)
        #expect(ui.open(.search))
        #expect(cancelled == 1)
        ui.submitHidden()
        ui.close(animated: false)
        #expect(ui.open(.search))
        #expect(hidden == 0)
        #expect(cancelled == 1)
    }

    @Test func theHiddenStepNeverCancels() {
        let ui = UIState(haptics: recordingHaptics())
        ui.open(.search, animated: false)
        var cancelled = 0
        ui.submitSearch(onHidden: {}, onCancel: { cancelled += 1 })
        ui.submitHidden()
        #expect(ui.open(.search))
        #expect(cancelled == 0)
    }

    @Test func barIntroEndedAtTheHiddenStepStillRevealsThePage() {
        let ui = UIState(haptics: recordingHaptics())
        ui.open(.search, animated: false)
        var switched = 0
        ui.submitSearch(
            onHidden: {
                switched += 1
                ui.endBarIntro()
            },
            onCancel: {})
        ui.submitHidden()
        #expect(switched == 1)
        #expect(ui.behindOpacity == 1)
        #expect(!ui.isSubmitting)
        #expect(!ui.isBarIntroPending)
    }
}
