import CoreHaptics
import SwiftUI
import Testing
import UIKit
@testable import SailBrowser

struct ThemeTests {
    // The haptics table: a crisp tap, a crisp hold, and the refresh sequence.
    @Test func hapticPatternsMatchTheResearchTable() {
        let h = Theme.Haptic.self
        #expect(h.strength == 1)
        #expect(h.medium == .pattern(HapticPattern(.tap(0.45, 0.6))))
        #expect(h.rigid == .pattern(HapticPattern(.tap(0.55, 0.8))))
        #expect(h.selection == .selection)
        #expect(h.success == .notification(.success))
        #expect(h.pullTickIntensity == 0.3...0.55)
        #expect(h.pullTickSharpness == 0.6)
        #expect(
            h.refreshArm
                == .pattern(HapticPattern(.tap(0.4, 0.9), .tap(0.8, 0.45, at: 0.015), .fade(0.4, 0.15, over: 0.04, at: 0.03))))
        #expect(h.pullTickGap == .milliseconds(60))
        #expect(h.refreshLand == .pattern(HapticPattern(.tap(0.5, 0.5), .tap(0.6, 0.5, at: 0.07))))
        #expect(Theme.Refresh.tickStep == 10)
        #expect(h.refreshTicks.count == 14)
    }

    // One tap per step before the arm, rising through the tick range a step at a time: the first a step above the
    // range's start, the last a step under its end, all at one sharpness, so only the arm's thock is stronger.
    @Test func pullTicksRiseOnePerStepTowardTheArm() {
        let h = Theme.Haptic.self
        let steps = Int(Theme.Refresh.armDistance / Theme.Refresh.tickStep)
        let pulses = h.refreshTicks.compactMap { feedback -> HapticPulse? in
            guard case .pattern(let pattern) = feedback, pattern.pulses.count == 1 else { return nil }
            return pattern.pulses[0]
        }
        #expect(pulses.count == steps - 1)
        let span = h.pullTickIntensity.upperBound - h.pullTickIntensity.lowerBound
        for (index, pulse) in pulses.enumerated() {
            let expected = h.pullTickIntensity.lowerBound + span * Float(index + 1) / Float(steps)
            #expect(abs(pulse.intensity - expected) < 1e-6, "\(index)")
            #expect(pulse.sharpness == h.pullTickSharpness)
            #expect(pulse.fade == 0)
        }
        #expect(pulses.map(\.intensity) == pulses.map(\.intensity).sorted())
        #expect(pulses.last!.intensity < h.pullTickIntensity.upperBound)
    }

    // Each transient and fade is one event, and each fade adds one intensity curve.
    @Test func everyHapticPatternBuildsACoreHapticsPattern() throws {
        for feedback in Theme.Haptic.all {
            guard case .pattern(let pattern) = feedback else { continue }
            let entries = try #require(try pattern.coreHaptics(strength: Theme.Haptic.strength).exportDictionary()[.pattern] as? [Any])
            let fades = pattern.pulses.filter { $0.fade > 0 }.count
            #expect(entries.count == pattern.pulses.count + fades, "\(pattern)")
        }
    }

    // The arm's thock (0.8) is the strongest pulse, and the strength knob scales what is built.
    @Test func hapticIntensitiesStayLightAndFollowTheStrengthKnob() throws {
        let intensities = Theme.Haptic.all.flatMap { feedback -> [Float] in
            guard case .pattern(let pattern) = feedback else { return [] }
            return pattern.pulses.map(\.intensity)
        }
        #expect(intensities.max() == 0.8)
        let built = try #require(
            try HapticPattern(.tap(0.6, 0.6)).coreHaptics(strength: 0.5).exportDictionary()[.pattern] as? [[String: Any]])
        let event = try #require(built.first?["Event"] as? [String: Any])
        let parameters = try #require(event["EventParameters"] as? [[String: Any]])
        let value = parameters.first { $0["ParameterID"] as? String == "HapticIntensity" }?["ParameterValue"] as? Double
        let intensity = try #require(value)
        #expect(abs(intensity - 0.3) < 0.001)
    }

    // The pull's texture is one continuous event at Core Haptics' longest duration, built at the sharpness range's
    // round end and the knob's strength. A level's shares become a multiplying intensity control and an additive
    // sharpness control that spans the range.
    @Test func thePullTextureBuildsOneLongContinuousEvent() throws {
        let h = Theme.Haptic.self
        #expect(h.pullTexture == HapticTexture(intensity: 0.3, sharpness: 0.1...0.4))
        #expect(h.pullTextureSpeed == 1500)
        #expect(h.textures == [h.pullTexture])
        #expect(HapticTexture.longest == 30)
        let built = try #require(try h.pullTexture.coreHaptics(strength: 0.5).exportDictionary()[.pattern] as? [[String: Any]])
        #expect(built.count == 1)
        let event = try #require(built[0][CHHapticPattern.Key.event.rawValue] as? [String: Any])
        #expect(event[CHHapticPattern.Key.eventType.rawValue] as? String == CHHapticEvent.EventType.hapticContinuous.rawValue)
        #expect(event[CHHapticPattern.Key.eventDuration.rawValue] as? Double == HapticTexture.longest)
        let parameters = try #require(event[CHHapticPattern.Key.eventParameters.rawValue] as? [[String: Any]])
        let values = Dictionary(
            uniqueKeysWithValues: parameters.map {
                ($0[CHHapticPattern.Key.parameterID.rawValue] as! String, $0[CHHapticPattern.Key.parameterValue.rawValue] as! Double)
            })
        let intensity = try #require(values[CHHapticEvent.ParameterID.hapticIntensity.rawValue])
        let sharpness = try #require(values[CHHapticEvent.ParameterID.hapticSharpness.rawValue])
        #expect(abs(intensity - 0.15) < 0.001)
        #expect(abs(sharpness - 0.1) < 0.001)
        let controls = h.pullTexture.parameters(at: HapticTexture.Level(intensity: 0.5, sharpness: 1))
        #expect(controls.map(\.parameterID) == [.hapticIntensityControl, .hapticSharpnessControl])
        #expect(controls[0].value == 0.5)
        #expect(abs(controls[1].value - 0.3) < 1e-6)
        #expect(controls.allSatisfy { $0.relativeTime == 0 })
    }

    // Two tokens may hold the same pattern (the middle pull tick matches the tap); they share one player.
    @Test func everyEventPlaysAToken() {
        for event in HapticEvent.allCases {
            for step in Theme.Haptic.refreshTicks.indices {
                #expect(Theme.Haptic.all.contains(Theme.Feedback.feedback(for: event, step: step)), "\(event)")
            }
        }
    }

    @Test func refreshHoldLeavesTheRingItsInsetAboveAndBelow() {
        #expect(Theme.Metrics.refreshHold == 44)
        #expect(Theme.Metrics.refreshHold - Theme.Metrics.loadingRingTopInset - Theme.Metrics.loadingRingSize
            == Theme.Metrics.loadingRingTopInset)
    }

    @Test func isLightResolvesDynamicColors() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        #expect(Theme.Palette.isLight(.systemBackground, in: light))
        #expect(!Theme.Palette.isLight(.systemBackground, in: dark))
        #expect(!Theme.Palette.isLight(UIColor(red: 0x1A / 255, green: 0x18 / 255, blue: 0x26 / 255, alpha: 1), in: light))
    }

    @Test func paletteMatchesSpec() {
        #expect(Theme.Palette.menuSheetTop == UIColor(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF4 / 255, alpha: 1))
        #expect(Theme.Palette.menuSheetDark == UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1))
        #expect(Theme.Palette.menuInk(light: true) == .black)
        #expect(Theme.Palette.menuInk(light: false) == .white)
        #expect(Theme.Palette.menuFooterSecondary == UIColor(red: 0x6B / 255, green: 0x62 / 255, blue: 0x68 / 255, alpha: 1))
        #expect(Theme.Palette.searchBackdrop == Color(red: 0x1E / 255, green: 0x1C / 255, blue: 0x2D / 255))
        #expect(Theme.Palette.submitBackdrop == Color(red: 0x21 / 255, green: 0x22 / 255, blue: 0x24 / 255))
        #expect(Theme.Palette.submittedPagePlaceholder == Theme.Palette.submitBackdrop)
    }

    @Test func thePermissionPromptTokens() {
        let metrics = Theme.Metrics.self
        #expect(metrics.permissionSheetHeight == 260)
        #expect(metrics.permissionButtonHeight == 50)
        #expect(metrics.permissionButtonGap == 12)
        #expect(metrics.permissionGlyphGap == 14)
        #expect(metrics.permissionSidePadding == 24)
        #expect(metrics.permissionGrabberSize == CGSize(width: 36, height: 5))
        #expect(metrics.permissionGrabberTop == 5)
        #expect(Theme.Typography.permissionGlyph == Font.system(size: 34, weight: .regular))
        #expect(Theme.Typography.permissionTitle == Font.system(size: 20, weight: .semibold))
        #expect(Theme.Typography.permissionButton == Font.system(size: 17, weight: .semibold))
        #expect(Theme.Motion.permissionSheet == .spring(duration: 0.3, bounce: 0))
        #expect(Theme.Palette.permissionGrabber == Color(uiColor: .tertiaryLabel))
    }

    @Test func downloadsValuesMatchSpec() {
        #expect(Theme.Palette.settingsButtonFill == Color(red: 0x3B / 255, green: 0x3B / 255, blue: 0x3B / 255))
        #expect(Theme.Metrics.settingsButtonHeight == 40)
        #expect(Theme.Typography.settingsButton == Font.system(.body))
        #expect(Theme.Metrics.downloadIcon == 28)
        #expect(Theme.Typography.downloadTitle == Font.system(.callout))
        #expect(Theme.Typography.downloadDetail == Font.system(.footnote))
    }

    @Test func navPillURLFontsAreFifteenPoint() {
        #expect(Theme.Typography.navPillURL == Font.system(size: 15, weight: .medium))
        #expect(Theme.Typography.navPillURLUIFont == UIFont.systemFont(ofSize: 15, weight: .medium))
    }

    @Test func opacitiesMatchSpec() {
        let values: [(CGFloat, CGFloat)] = [
            (Theme.Opacity.browsingControlFill, 0.08),
            (Theme.Opacity.switcherControlFill, 0.12),
            (Theme.Opacity.cardHeaderPin, 0.7),
            (Theme.Opacity.emptyDeckLabel, 0.5),
            (Theme.Opacity.searchDim, 0.2),
            (Theme.Opacity.suggestionSecondary, 0.45),
            (Theme.Opacity.searchFieldPlaceholder, 0.52),
            (Theme.Opacity.searchFieldFill, 0.1),
            (Theme.Opacity.searchFieldRim, 0.13),
            (Theme.Opacity.menuDim, 0.2),
            (Theme.Opacity.menuSheetTint, 0.12),
            (Theme.Opacity.menuSheetEdge, 0.12),
            (Theme.Opacity.menuFill, 0.1),
            (Theme.Opacity.menuStepperFill, 0.06),
            (Theme.Opacity.navPillStroke, 0.12),
            (Theme.Opacity.menuPrimary, 0.88),
            (Theme.Opacity.menuIcon, 0.84),
            (Theme.Opacity.menuSecondary, 0.6),
            (Theme.Opacity.navPillDisabled, 0.45),
        ]
        for (actual, expected) in values {
            #expect(actual == expected)
        }
    }

    @Test func metricsMatchSpec() {
        let values: [(CGFloat, CGFloat)] = [
            (Theme.Metrics.loadingRingSize, 30),
            (Theme.Metrics.loadingRingStroke, 2),
            (Theme.Metrics.loadingRingTopInset, 7),
            (Theme.Metrics.barHideOffset, 76),
            (Theme.Metrics.tabStackThumbnailCorner, 4),
            (Theme.Metrics.deckLeftDimStep, 0.15),
            (Theme.Metrics.deckLeftMaxDim, 0.3),
            (Theme.Metrics.deckOlderFadeIn, 0.15),
            (Theme.Metrics.cardPlaceholderFavicon, 40),
            (Theme.Metrics.cardHeaderGap, 10),
            (Theme.Metrics.cardHeaderHeight, 24),
            (Theme.Metrics.cardHeaderFavicon, 20),
            (Theme.Metrics.cardHeaderFaviconCorner, 4),
            (Theme.Metrics.browsingShrinkScale, 0.955),
            (Theme.Metrics.switcherShrinkScale, 1),
            (Theme.Metrics.browsingShrinkCorner, 24),
            (Theme.Metrics.searchSheetTopPadding, 16),
            (Theme.Metrics.searchFieldHeight, 48),
            (Theme.Metrics.searchFieldGap, 6),
            (Theme.Metrics.searchFieldInset, 16),
            (Theme.Metrics.searchFieldTextInset, 24),
            (Theme.Metrics.suggestionRowHeight, 56),
            (Theme.Metrics.suggestionFavicon, 20),
            (Theme.Metrics.suggestionIconGap, 9),
            (Theme.Metrics.suggestionRowLeading, 19),
            (Theme.Metrics.suggestionRowTrailing, 32),
            (Theme.Metrics.suggestionFaviconCorner, 6),
            (Theme.Metrics.menuPadding, 16),
            (Theme.Metrics.menuSheetCorner, 38),
            (Theme.Metrics.menuBottomPadding, 0),
            (Theme.Metrics.navPillHeight, 48),
            (Theme.Metrics.navPillCorner, 24),
            (Theme.Metrics.navPillButtonWidth, 40),
            (Theme.Metrics.navPillInset, 5),
            (Theme.Metrics.menuPillToTiles, 18),
            (Theme.Metrics.menuTileGap, 16),
            (Theme.Metrics.menuTileHeight, 88),
            (Theme.Metrics.menuTileCorner, 18),
            (Theme.Metrics.menuTileLabelGap, 11),
            (Theme.Metrics.menuTileLabelTracking, 0.1),
            (Theme.Metrics.menuLabelToList, 19),
            (Theme.Metrics.menuGroupGap, 16),
            (Theme.Metrics.menuListCorner, 14),
            (Theme.Metrics.menuListRowHeight, 48.5),
            (Theme.Metrics.menuRowGap, 0.5),
            (Theme.Metrics.menuRowTextInset, 53),
            (Theme.Metrics.menuRowIconCentre, 29.5),
            (Theme.Metrics.menuStepperCorner, 8),
            (Theme.Metrics.menuStepperInset, 10),
            (Theme.Metrics.menuStepperDivider, 27),
            (Theme.Metrics.menuFooterHeight, 55.4),
            (Theme.Metrics.menuFooterInset, 20.3),
            (Theme.Metrics.archiveFavicon, 20),
        ]
        for (actual, expected) in values {
            #expect(actual == expected)
        }
        #expect(Theme.Metrics.tabStackThumbnailSize == CGSize(width: 26, height: 34))
        #expect(Theme.Metrics.menuStepperSize == CGSize(width: 89, height: 31))
        #expect(Theme.Metrics.suggestionRowCount == 4)
    }

    @Test func fidelityMetricsMatchAmendmentA() {
        let m = Theme.Metrics.self
        let values: [(CGFloat, CGFloat)] = [
            (m.barHeight, 42), (m.controlSize, 35), (m.cardWidthFraction, 0.70), (m.cardCorner, 15),
            (m.searchSheetAboveKeyboard, 304), (m.cardHeightFraction, 0.65), (m.cardTopFraction, 0.188),
            (m.focusedLeftFraction, 0.205), (m.rightStepFraction, 0.80), (m.leftFirstStepFraction, 0.237),
            (m.leftStepFraction, 0.039), (m.tabStackButtonCenterX, 46), (m.barTotalHeight, 76),
            (m.barControlCenterFromBottom, 45), (m.searchSheetRiseOnSubmit, 250),
            (m.loadingLineCore, 1.5), (m.loadingLineLength, 360),
        ]
        for (actual, expected) in values {
            #expect(actual == expected)
        }
        #expect(m.pillSize == CGSize(width: 76, height: 39))
        #expect(m.tabStackButtonSize == CGSize(width: 44, height: 40))
        #expect(m.olderDepthScales == [0.98, 0.93])
        #expect(m.tabStackTilt == 7)
    }

    @Test func searchMotionTokensDriveTheirCurves() {
        let m = Theme.Motion.self
        #expect(
            m.searchBehindClose.animation(initialVelocity: m.searchBehindCloseVelocity)
                == .interpolatingSpring(duration: m.searchBehindCloseDuration, bounce: 0, initialVelocity: 1.5))
        #expect(m.submitFadeOut.animation == .easeOut(duration: m.submitFadeOutDuration))
    }

    @Test func fidelityMotionMatchesAmendmentA() {
        let m = Theme.Motion.self
        let tokens: [(MotionToken, MotionToken)] = [
            (m.zoom, .spring(duration: 0.28, bounce: 0.05)), (m.bar, .spring(duration: 0.28, bounce: 0)),
            (m.archiveGapClose, .spring(duration: 0.26, bounce: 0)), (m.submitFadeIn, .curve(duration: 0.12, .easeOut)),
            (m.submitPageFadeIn, .curve(duration: 0.225, .easeOut)),
            (m.refreshRelease, .spring(duration: 0.34, bounce: 0)),
        ]
        for (actual, expected) in tokens {
            #expect(actual == expected)
        }
        #expect(m.zoom.animation == .spring(duration: 0.28, bounce: 0.05))
        #expect(m.keyboardDuration == 0.3833)
        #expect(MotionToken.keyboard.animation == .spring(duration: 0.3833, bounce: 0))
        #expect(m.archiveFlyOffMinimumCoast == 2)
        #expect(m.submitFadeOutDuration == 0.19)
        #expect(m.barIntroDelay == 0.57)
    }

    @Test func barAndLoadingTokensMatchAmendmentA() {
        #expect(Theme.Metrics.tabStackThumbnailOffsets == [CGSize(width: 7, height: -5), CGSize(width: -7, height: 5)])
        #expect(Theme.Metrics.hairlineWidth == 0.5)
        #expect(Theme.Opacity.barEdge == 0.1)
        #expect(Theme.Opacity.loadingLineGlow == 0.6)
        #expect(Theme.Opacity.loadingRingHead == 0.6)
        #expect(Theme.Opacity.loadingRingTail == 0.1)
        #expect(Theme.Motion.loadingLineHeadStep.animation == .linear(duration: 0.2))
        #expect(Theme.Motion.loadingRingTurnDuration == 1)
    }

    @Test func searchAndDeckTokensMatchAmendmentA() {
        #expect(Theme.Metrics.missingFaviconCorner == 5)
        #expect(Theme.Opacity.searchSheetEdge == 0.12)
        #expect(Theme.Metrics.searchSheetCorner == 38)
        #expect(Theme.Motion.searchCopyHold == 0.05)
        #expect(Theme.Motion.searchCopyFade == 0.05)
        #expect(Theme.Typography.suggestionSubtitle == .system(size: 13))
    }

    // The chrome's one frosted material, measured on 2026-10-27.
    @Test func frostTokensMatchTheMeasuredMaterial() {
        #expect(Theme.Frost.bar(light: true) == .systemMaterialLight)
        #expect(Theme.Frost.bar(light: false) == .systemMaterialDark)
        #expect(Theme.Frost.sheet == .systemMaterialDark)
        #expect(Theme.Frost.sheetTint == Theme.Palette.uiHex(0x2A2A2C))
        #expect(Theme.Frost.sheetTintOpacity == 0)
        #expect(Theme.Frost.menu(light: true) == .systemThickMaterialLight)
        #expect(Theme.Frost.menu(light: false) == .systemThickMaterialDark)
        #expect(Theme.Frost.menuGradient(light: true) == 0.9)
        #expect(Theme.Frost.menuGradient(light: false) == 0.7)
        #expect(Theme.Opacity.darkBarControlFill == 0.1)
        #expect(Theme.Opacity.privateSheetShade == 0.45)
    }

    @Test func deckDrivesItsZoomOnItsOwnSpring() {
        #expect(Theme.Motion.deckZoom == .spring(duration: 0.22, bounce: 0.025))
        #expect(DeckSnap.zoom == Spring(duration: 0.22, bounce: 0.025))
        #expect(Theme.Motion.deckOlderZoom == .spring(duration: 0.34, bounce: 0.1))
        #expect(DeckSnap.olderZoom == Spring(duration: 0.34, bounce: 0.1))
    }

    // The bar swipe's release springs on the deck zoom's spring, landing in 12 to 17 frames.
    @Test func theBarSwipeSpringsOnTheDeckZoomAndPagesOnItsTokens() {
        #expect(Theme.Motion.barSwipeSettle == Theme.Motion.deckZoom)
        #expect(DeckSnap.barSwipe == DeckSnap.zoom)
        #expect(Theme.Gesture.barSwipeCommitFraction == 0.5)
        #expect(Theme.Gesture.barSwipeFlickVelocity == 400)
        #expect(Theme.Gesture.barSwipeMaxTabs == 1)
        #expect(Theme.Feedback.feedback(for: .tabPaged) == Theme.Haptic.selection)
    }

    @Test func theBarSwipeArmsAnEqualPair() {
        #expect(Theme.Metrics.barSwipeCardScale == 0.9)
        #expect(Theme.Metrics.barSwipeGap == 32)
        #expect(Theme.Metrics.barSwipeCardTopInset == 4)
        #expect(Theme.Metrics.barSwipeCardCorner == 24)
        #expect(Theme.Gesture.barSwipeStretch == 0.7)
        #expect(Theme.Motion.barSwipeArm == Theme.Motion.deckZoom)
        #expect(Theme.Motion.barSwipeDrop == .spring(duration: 0.13, bounce: 0))
    }

    @Test func theFlickKeepsTheDeckCardsCorner() {
        let m = Theme.Metrics.self
        #expect([m.tabStackFlickArmScale, m.tabStackFlickPeekScale] == [0.84, 0.63])
        #expect([m.tabStackFlickInset, m.tabStackFlickBottomInset] == [24, 101])
        #expect(Theme.Gesture.tabStackFlickFollow == 1)
        #expect(Theme.Gesture.tabStackFlickCatchUp == 2)
        #expect(Theme.Metrics.tabStackFlickUprightScale == 0.2)
        #expect(Theme.Motion.tabStackFlickSettle == Theme.Motion.deckZoom)
        #expect(Theme.Motion.tabStackFlickDrop == Theme.Motion.barSwipeDrop)
        #expect(Theme.Motion.token(for: .tabStackFlick) == Theme.Motion.deckZoom)
    }

    // The pinch presses the tab stack button: its gate's tokens, and the button's own zoom and tap.
    @Test func thePinchPressesTheTabStackButton() {
        #expect(Theme.Gesture.pinchSwitcherScale == 0.85)
        #expect(Theme.Gesture.pinchZoomSlack == 0.01)
        #expect(Theme.Motion.token(for: .pinchSwitcher) == Theme.Motion.token(for: .tabStackTap))
        #expect(Theme.Feedback.event(for: .pinchSwitcher) == Theme.Feedback.event(for: .tabStackTap))
        #expect(Theme.Latency.budget(for: .pinchSwitcher) == Theme.Latency.budget(for: .tabStackTap))
    }

    @Test func pageDialogsOfferMutingFromTheFourth() {
        #expect(Theme.Gesture.dialogMuteAfter == 3)
    }

    @Test func anEmptySearchOpensOnItsMeasuredSpring() {
        #expect(Theme.Motion.searchOpen == .spring(duration: 0.245, bounce: 0))
    }

    @Test func gapCloseSharesItsSpringWithTheDeckRecord() {
        #expect(Theme.Motion.archiveGapClose.animation == .spring(duration: 0.26, bounce: 0))
        #expect(DeckSnap.gapClose == Spring(duration: 0.26, bounce: 0))
    }

    @Test func deckSnapTokenIsExact() {
        let snap = Theme.Motion.deckSnap.spring
        #expect(abs(snap.mass - 1) < 1e-9 && abs(snap.stiffness - 320) < 1e-9 && abs(snap.damping - 32) < 1e-9)
        #expect(Theme.Motion.deckSnap.animation(initialVelocity: 2) == .interpolatingSpring(snap, initialVelocity: 2))
        #expect(DeckSnap.snap == snap)
    }

    @Test func fadeAnimationIsBuiltFromItsDuration() {
        #expect(Theme.Motion.fade == .curve(duration: Theme.Motion.fadeDuration, .easeOut))
        #expect(Theme.Motion.fade.animation == .easeOut(duration: Theme.Motion.fadeDuration))
    }

    @Test func polishMotionAndMetricsTokens() {
        let m = Theme.Motion.self
        let tokens: [(MotionToken, MotionToken)] = [
            (m.press, .spring(duration: 0.12, bounce: 0)), (m.pressRelease, .spring(duration: 0.3, bounce: 0.15)),
            (m.rowRelease, .curve(duration: 0.2, .easeOut)),
            (m.emptyDeckAppear, .curve(duration: 0.185, .easeOut)),
        ]
        for (actual, expected) in tokens {
            #expect(actual == expected)
        }
        #expect(Theme.Metrics.pressScale == 0.94)
        #expect(Theme.Metrics.pressScaleWide == 0.98)
        #expect(Theme.Metrics.emptyDeckStartScale == 0.5)
    }

    // The swipe to remove a recent.
    @Test func recentSwipeTokens() {
        let m = Theme.Motion.self
        #expect(m.recentReturn == .spring(duration: 0.4, bounce: 0))
        #expect(m.recentCollapse == .spring(duration: 0.25, bounce: 0))
        #expect(Theme.Gesture.recentRemoveFraction == 0.45)
        #expect(Theme.Gesture.flickStill == 0.05)
        #expect(Theme.Metrics.recentRemoveInset == 11)
        #expect(Theme.Metrics.recentRemoveHeight == 48)
        #expect(Theme.Metrics.recentRemoveAspect == 0.58)
        #expect(Theme.Motion.recentLabel == .spring(duration: 0.2, bounce: 0))
        #expect(Theme.Metrics.recentRemoveLabelInset == 16)
        #expect(Theme.Typography.recentRemoveLabel == .system(size: 13, weight: .medium))
        #expect(Theme.Palette.recentRemove == Color(uiColor: .systemRed))
        #expect(Theme.Feedback.feedback(for: .recentArmed) == Theme.Haptic.medium)
    }

    @Test func latencyIsTwoFramesAtOneHundredTwenty() {
        #expect(Theme.Latency.frameRate == 120)
        #expect(Theme.Latency.frame == .seconds(1.0 / 120))
        let range = Theme.Latency.frameRateRange
        #expect(range.minimum == 80 && range.maximum == 120 && range.preferred == 120)
        #expect(Theme.Palette.searchDim == .black)
        #expect(Theme.Latency.systemSheetHold == 0.5)
        #expect(Theme.Latency.appLinkAnswer == .milliseconds(50))
        #expect(Theme.Latency.neighbourWarmDelay == 0.5)
    }

    @Test func fidelityPaletteMatchesAmendmentA() {
        let p = Theme.Palette.self
        let hex = { (value: Int) in
            Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        #expect(p.deckGradientStops.map(\.color) == [0x19192A, 0x1B1928, 0x2D1C1E, 0x251D26].map(hex))
        #expect(p.deckBarStrip == hex(0x24252D))
        #expect(p.missingFavicon == hex(0x3A3A3C))
        #expect(p.searchCaret == hex(0x6D7CDB))
        #expect(p.newTabPlaceholder == .black)
        #expect(p.loadingLineStops.map(\.distance) == [0, 120, 190, 250])
        #expect(p.loadingLineStops.map(\.color) == [0x4787EB, 0x4852CE, 0x493AB4, 0x4C2D6F].map(hex))
    }

    @Test func searchSheetRowsLeaveTenPointsAboveTheKeyboard() {
        let m = Theme.Metrics.self
        let stacked = m.searchSheetTopPadding + m.searchFieldHeight + m.searchFieldGap
            + CGFloat(m.suggestionRowCount) * m.suggestionRowHeight
        #expect(m.searchSheetAboveKeyboard - stacked == 10)
    }

    @Test func typographyMatchesSpec() {
        let values: [(Font, Font)] = [
            (Theme.Typography.barPlusGlyph, .system(size: 20, weight: .semibold)),
            (Theme.Typography.barChevronGlyph, .system(size: 17, weight: .semibold)),
            (Theme.Typography.cardHeaderPin, .system(size: 11)),
            (Theme.Typography.cardHeaderTitle, .system(size: 15, weight: .semibold)),
            (Theme.Typography.emptyDeckLabel, .system(size: 17, weight: .semibold)),
            (Theme.Typography.suggestionTitle, .system(size: 17, weight: .medium)),
            (Theme.Typography.suggestionSymbol, .system(size: 16)),
            (Theme.Typography.navPillURL, .system(size: 15, weight: .medium)),
            (Theme.Typography.navPillGlyph, .system(size: 15, weight: .medium)),
            (Theme.Typography.menuTileIcon, .system(size: 25, weight: .light)),
            (Theme.Typography.menuRow, .system(size: 16, weight: .medium)),
            (Theme.Typography.menuRowIcon, .system(size: 18)),
            (Theme.Typography.menuStepperGlyph, .system(size: 15)),
            (Theme.Typography.menuFooter, .system(size: 15)),
            (Theme.Typography.menuFooterCount, .system(size: 15, weight: .bold)),
            (Theme.Typography.archiveTitle, .system(.callout)),
            (Theme.Typography.archiveDetail, .system(.footnote)),
        ]
        for (actual, expected) in values {
            #expect(actual == expected)
        }
        #expect(Theme.Typography.searchFieldUIFont == UIFont.systemFont(ofSize: 20, weight: .medium))
        #expect(Theme.Typography.menuTileLabelUIFont == UIFont.systemFont(ofSize: 11, weight: .medium))
    }

    @Test func gesturesAndTimingMatchSpec() {
        let values: [(Double, Double)] = [
            (Theme.Gesture.deckAxisLock, 10),
            (Theme.Gesture.tapMaxTravel, 10),
            (Theme.Gesture.tapMaxDuration, 0.3),
            (Theme.Gesture.archiveCommitFraction, 0.6),
            (Theme.Gesture.archivePredictedCommitFraction, 0.5),
            (Theme.Gesture.tabStackFlickDistance, 30),
            (Theme.Gesture.chevronLongPress, 0.35),
            (Theme.Gesture.sheetDragClose, 80),
            (Theme.Gesture.sheetDragPredictedClose, 200),
            (Theme.Gesture.rubberBandCoefficient, 0.55),
            (Theme.Gesture.decelerationNormal, 0.998),
            (Theme.Gesture.decelerationFast, 0.99),
            (Theme.Gesture.deckStretch, 0.5),
            (Theme.Gesture.deckSettledDistance, 0.05),
            (Theme.Gesture.liftStretch, 40),
            (Theme.Gesture.sheetStretch, 60),
            (Theme.Gesture.detentHysteresis, 8),
            (Theme.Gesture.archiveFlickVelocity, 500),
            (Theme.Gesture.recentRemoveFraction, 0.45),
            (Theme.Gesture.zoomBarHandOffProgress, 0.5),
            (Theme.Motion.fadeDuration, 0.15),
            (Theme.Motion.coverHold, 0.1),
            (Theme.Gesture.axisLockDistance, 8),
            (Theme.Gesture.axisLockAngle, 35),
            (Theme.Gesture.landedPoints, 0.5),
            (Theme.Gesture.landedSpeed, 30),
            (Theme.Gesture.barHideDistance, 24),
            (Theme.Gesture.barShowDistance, 12),
            (Theme.Gesture.deckBuiltBehind, 4),
            (Theme.Gesture.deckBuiltAhead, 2),
            (Theme.Motion.coverZoomFade, 0.08),
        ]
        for (actual, expected) in values {
            #expect(actual == expected)
        }
        #expect(Theme.Gesture.deckMaxFlickCards == 2)
    }

    @Test func theTranslateButtonTokens() {
        #expect(Theme.Translate.barGap == 12)
        #expect(Theme.Translate.translatedFill == 0.25)
    }

    // Wave 1 logic types are nonisolated, so these tokens must be readable from a nonisolated context.
    private nonisolated static func wave1Tokens() -> [Double] {
        let g = Theme.Gesture.self
        let m = Theme.Metrics.self
        return [
            g.deckStretch, Double(g.deckMaxFlickCards), g.liftStretch,
            g.archiveFlickVelocity, g.archiveCommitFraction, g.archivePredictedCommitFraction, g.tabStackFlickDistance,
            m.pressScale, m.pressScaleWide, m.emptyDeckStartScale, g.axisLockDistance, g.axisLockAngle,
            g.landedPoints, g.landedSpeed,
        ]
    }

    @Test func wave1TokensAreNonisolated() {
        #expect(Self.wave1Tokens() == [0.5, 2, 40, 500, 0.6, 0.5, 30, 0.94, 0.98, 0.5, 8, 35, 0.5, 30])
    }

    @Test func aDelayedTokenAnimationStartsAfterItsDelay() throws {
        let scene = UIApplication.shared.connectedScenes.first as! UIWindowScene
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let view = UIView()
        window.addSubview(view)
        window.isHidden = false
        Theme.Motion.fieldGrow.animate(after: 0.2, initialVelocity: 0) { view.alpha = 0 } completion: { _ in }
        let key = try #require(view.layer.animationKeys()?.first)
        let animation = try #require(view.layer.animation(forKey: key))
        #expect(abs(animation.beginTime - 0.2) < 1e-9)
        #expect(abs(animation.duration - 0.15) < 1e-9)
    }
}

struct SearchCloseTableTests {
    @Test func theFadeTablesRiseToTheBarAndTheTextFadesOut() {
        let m = Theme.Motion.self
        for table in [m.searchCollapsePlus, m.searchTapCopies, m.searchReleaseCopies] {
            #expect(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(table.last == 1)
        }
        #expect(zip(m.searchCollapseText, m.searchCollapseText.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(m.searchCollapseText.first == 1 && m.searchCollapseText.last == 0)
    }

    // The fitted close: a bouncy top, a release that starts fast, a collapse a little less bouncy.
    @Test func theCloseRunsOnTheFittedSprings() {
        let m = Theme.Motion.self
        #expect(m.searchTapClose == .spring(duration: 0.40, bounce: 0.12))
        #expect(m.searchTapCloseVelocity == 1)
        #expect(m.searchReleaseClose == .spring(duration: 0.365, bounce: 0.13))
        #expect(m.searchReleaseCloseVelocity == 5.5)
        #expect(m.searchCollapse == .spring(duration: 0.355, bounce: 0.12))
        #expect(m.searchTapCollapseLag == 4)
        #expect(m.searchTapKeyboardVanishFrame == 5)
        #expect(m.searchTapCloseFrames == 23 && m.searchReleaseCloseFrames == 19)
        // The fades end by the hand-off.
        #expect(m.searchTapCollapseLag + m.searchCollapseText.count <= m.searchTapCloseFrames)
        #expect(m.searchTapCollapseLag + m.searchTapCopies.count <= m.searchTapCloseFrames)
        #expect(m.searchReleaseCopies.count <= m.searchReleaseCloseFrames)
    }

    // Display Options' chevron (measured: 13.4 x 7.6 glyph, #4D4A4A on its row, centred 26.5 from the card's right).
    @Test func theFoldsChevronTokens() {
        #expect(Theme.Typography.menuChevronUIFont == UIFont.systemFont(ofSize: 15, weight: .medium))
        #expect(Theme.Opacity.menuChevron == 0.65)
        #expect(Theme.Metrics.menuChevronCentre == 26.5)
        #expect(Theme.Motion.menuFold == Theme.Motion.menuReturn)
        #expect(Theme.Motion.angleSettled == 0.001)
        #expect(Theme.Motion.token(for: .displayOptionsToggle) == Theme.Motion.menuFold)
    }

    // The menu has no fitted motion of its own, so it moves on the search sheet's fitted springs, shared, not copied.
    @Test func theMenuMovesOnTheSearchSheetsSprings() {
        let m = Theme.Motion.self
        #expect(m.menuOpen == m.searchOpen)
        #expect(m.menuReturn == m.searchReturn)
        #expect(m.menuClose == m.searchReleaseClose)
        #expect(Theme.Motion.token(for: .menuGrabDuringOpen) == Theme.Motion.token(for: .searchGrabDuringOpen))
        #expect(Theme.Motion.token(for: .chevronTap) == m.menuOpen)
        #expect(Theme.Motion.token(for: .menuDragReturn) == m.menuReturn)
        for close in [Interaction.menuDragDismiss, .menuDimTap, .menuAddressSubmit, .menuFind, .menuShare, .menuTranslate] {
            #expect(Theme.Motion.token(for: close) == m.menuClose)
        }
    }

    // The reader draws on the system background until its page paints, as reader.css's Canvas does.
    @Test func theReaderBackgroundIsTheSystemBackground() {
        #expect(Theme.Palette.readerBackground == .systemBackground)
        #expect(Theme.Opacity.menuRowDisabled == 0.45)
    }

    // The reader has no fitted motion of its own, so it rises and leaves on the menu's springs, shared, not copied.
    @Test func theReaderMovesOnTheMenusSprings() {
        let m = Theme.Motion.self
        #expect(m.readerOpen == m.menuOpen)
        #expect(m.readerReturn == m.menuReturn)
        #expect(m.readerClose == m.menuClose)
    }

    @Test func theCloseLandsThePlusOnThePillsCentre() {
        let m = Theme.Metrics.self
        #expect(abs(m.searchClosePlusLead - m.searchClosePlusLeadPerWidth * m.pillSize.width - m.pillSize.width / 2) < 0.001)
    }

    @Test func blockingRechecksAfterHalfASecondAndWatchesCookieWallsForThreeSeconds() {
        #expect(Theme.Blocking.cosmeticRecheck == .milliseconds(500))
        #expect(Theme.Blocking.cookieWallWatch == .seconds(3))
    }

    // The error page draws on the submit cover's neutrals and the permission prompt's metrics; the fonts are UIFont
    // literals pinned to the prompt's point sizes, the only drift guard a SwiftUI Font allows.
    @Test func networkTokensKeepTheirValues() {
        let n = Theme.Network.self
        #expect(n.terminationWindow == .seconds(120))
        #expect(n.suggestTimeout == 2)
        #expect(n.suggestResourceTimeout == 5)
        #expect(n.suggestDebounce == .zero)
        #expect(n.faviconTimeout == 10)
        #expect(n.faviconResourceTimeout == 20)
        #expect(n.faviconFresh == 604_800)
        #expect(n.errorSnapshotDim == 0.5)
        #expect(n.errorClear == Theme.Motion.submitPageFadeIn)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        #expect(n.errorBackground.resolvedColor(with: dark).cgColor.components
            == UIColor(Theme.Palette.submitBackdrop).resolvedColor(with: dark).cgColor.components)
        #expect(n.errorBackgroundPrivate.resolvedColor(with: dark).cgColor.components
            == Theme.Palette.privateSubmitCover.resolvedColor(with: dark).cgColor.components)
        #expect(n.errorInk == .white)
        #expect(n.errorGlyphStyle == .largeTitle)
        #expect(n.errorTitleFont.pointSize == 20)
        #expect(n.errorDetailFont.pointSize == 15)
        #expect(n.errorButtonFont.pointSize == 17)
        #expect(n.errorButtonHeight == Theme.Metrics.permissionButtonHeight)
        #expect(n.errorSidePadding == Theme.Metrics.permissionSidePadding)
        #expect(n.errorGap == Theme.Metrics.permissionGlyphGap)
        #expect(n.errorDetailOpacity == Theme.Opacity.menuSecondary)
        #expect(n.errorButtonMinWidth == 160)
        #expect(n.errorButtonPadding == 28)
        #expect(n.errorButtonFill == 0.12)
    }

    // Incognito.
    @Test func privateTabsDrawOnTheirTokens() {
        let hex = { (value: Int) in
            Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        let uiHex = { (value: Int) in
            UIColor(
                red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        let p = Theme.Palette.self
        #expect(p.privateFieldFill == uiHex(0x2D2D2D))
        #expect(p.privateSheetShade == .black)
        #expect(Theme.Opacity.privateSheetShade == 0.45)
        #expect(p.privateFieldLabel == uiHex(0x959595))
        #expect(p.privateNotice == hex(0x9C999A))
        #expect(p.privateBand == .black)
        #expect(p.privateBandLabel == .white)
        #expect(p.privateIslandRing == uiHex(0x6A1E20))
        #expect(p.privateCard == hex(0x464646))
        #expect(p.privateCardSubtitle == hex(0x8E8F99))
        #expect(p.privateBarBackground == hex(0x242328))
        #expect(p.privateBarControlFill == hex(0x3A3A41))
        #expect(p.privateSubmitCover == uiHex(0x101114))
        #expect(p.submitCover == uiHex(0x212224))
        let m = Theme.Motion.self
        #expect(m.privateToggle == .curve(duration: 0.19, .linear))
        #expect(m.token(for: .privateToggle) == m.privateToggle)
        #expect(m.privateRowsFade == .curve(duration: 8.0 / 60, .linear))
        #expect(m.privateNoticeFade == .curve(duration: 5.0 / 60, .linear))
        #expect(m.privateNoticeDelay == 10.0 / 60)
        #expect(m.privateRowsReturnDelay == 9.0 / 60)
        let metrics = Theme.Metrics.self
        #expect(metrics.searchClearCenterInset == 30)
        #expect(metrics.privateToggleGap == 8)
        #expect(metrics.privateBandExtra == 6)
        #expect(metrics.privateBandLabelCenterFromBottom == 8.5)
        #expect(metrics.islandSize == CGSize(width: 126, height: 37.33))
        #expect(metrics.islandTop == 11.33)
        #expect(metrics.islandMinimumSafeTop == 59)
        #expect(metrics.islandRingWidth == 1)
        let t = Theme.Typography.self
        #expect(t.privateToggleUIFont == UIFont.systemFont(ofSize: 17, weight: .medium))
        #expect(t.privateFieldLabelUIFont == UIFont.systemFont(ofSize: 13))
        #expect(t.privateBandLabelUIFont == UIFont.systemFont(ofSize: 12.5, weight: .semibold))
        #expect(t.privateNotice == Font.system(size: 17, weight: .medium))
        #expect(t.cardHeaderSubtitle == Font.system(size: 11.5))
        #expect(Theme.Feedback.event(for: .privateToggle) == .buttonTap)
    }
}
