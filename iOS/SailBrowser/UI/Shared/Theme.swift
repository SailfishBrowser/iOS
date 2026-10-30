import SwiftUI
import UIKit

enum Theme {
    enum Motion {
        nonisolated static let zoom = MotionToken.spring(duration: 0.28, bounce: 0.05)
        nonisolated static let deckZoom = MotionToken.spring(duration: 0.22, bounce: 0.025)
        nonisolated static let deckOlderZoom = MotionToken.spring(duration: 0.34, bounce: 0.1)
        nonisolated static let deckSnap = MotionToken.physical(mass: 1, stiffness: 320, damping: 32)
        nonisolated static let bar = MotionToken.spring(duration: 0.28, bounce: 0)
        nonisolated static let keyboardDuration: TimeInterval = 0.3833
        static let keyboardCurve = UIView.AnimationOptions(rawValue: 7 << 16)
        nonisolated static let fadeDuration: TimeInterval = 0.15
        nonisolated static let fade = MotionToken.curve(duration: fadeDuration, .easeOut)
        static let coverHold: TimeInterval = 0.1
        // The warm zoom's cover fades out over this last fraction of the zoom in.
        nonisolated static let coverZoomFade: CGFloat = 0.08
        // The thrown card coasts up from the finger's speed (DeckCoast). A slower release starts fast enough to coast
        // this many times its trip off the top, so even the slowest throw leaves at half its start speed.
        nonisolated static let archiveFlyOffMinimumCoast: CGFloat = 2
        nonisolated static let archiveGapClose = MotionToken.spring(duration: 0.26, bounce: 0)
        // The page behind un-shrinks on its own spring while the sheet closes on its own.
        nonisolated static let searchBehindCloseDuration: TimeInterval = 0.26
        static let searchBehindCloseVelocity: CGFloat = 1.5
        nonisolated static let searchBehindClose = MotionToken.spring(duration: searchBehindCloseDuration, bounce: 0)
        nonisolated static let searchReturn = MotionToken.spring(duration: 0.26, bounce: 0)
        // An empty-field open, fitted to the field top from the end of the pill morph to rest (1.7 px RMS).
        nonisolated static let searchOpen = MotionToken.spring(duration: 0.245, bounce: 0)
        nonisolated static let fieldGrow = MotionToken.curve(duration: 0.15, .easeOut)
        static let springArrivalStretch: CFTimeInterval = 1.3
        // The page menu has no fitted motion of its own yet: it borrows the search sheet's fitted springs until one is fitted.
        nonisolated static let menuOpen = searchOpen
        nonisolated static let menuReturn = searchReturn
        nonisolated static let menuClose = searchReleaseClose
        // Display Options folds on the return's spring: the sheet springs to its new top and the chevron turns with it.
        nonisolated static let menuFold = menuReturn
        // Nor does the reader: it rises over the page and leaves on the menu's springs.
        nonisolated static let readerOpen = menuOpen
        nonisolated static let readerReturn = menuReturn
        nonisolated static let readerClose = menuClose
        // Two angles read back from a layer's transform closer than this, in radians, are the same.
        static let angleSettled: CGFloat = 0.001

        // The close as native springs fitted to measured tapped and drag-dismiss closes: the sheet's top from where it
        // starts to the bar, and the field from its size to the pill. A tapped close collapses searchTapCollapseLag
        // frames in; a drag release collapses at once and does not carry the finger's speed. The sheet hands off to the
        // bar on a fixed frame. In a tapped close the keyboard holds still at rest while the sheet slides under it and leaves in
        // one frame at searchTapKeyboardVanishFrame, 3 to 5 frames after the tap.
        nonisolated static let searchTapClose = MotionToken.spring(duration: 0.40, bounce: 0.12)
        static let searchTapCloseVelocity: CGFloat = 1
        nonisolated static let searchReleaseClose = MotionToken.spring(duration: 0.365, bounce: 0.13)
        static let searchReleaseCloseVelocity: CGFloat = 5.5
        nonisolated static let searchCollapse = MotionToken.spring(duration: 0.355, bounce: 0.12)
        static let searchTapCloseFrames = 23
        static let searchReleaseCloseFrames = 19
        static let searchCloseFrame: TimeInterval = 1.0 / 60
        static let searchTapCollapseLag = 4
        static let searchTapKeyboardVanishFrame = 5
        // The parts that fade in a close, per 60 Hz frame from the collapse's start: entry k is the value at frame k + 1.
        static let searchCollapseText: [CGFloat] = [1, 0.93, 0.58, 0.45, 0.31, 0.19, 0.10, 0.04, 0]
        static let searchCollapsePlus: [CGFloat] = [0.42, 0.45, 0.49, 0.63, 0.78, 0.87, 0.96, 1]
        static let searchTapCopies: [CGFloat] = [0, 0.06, 0.15, 0.26, 0.41, 0.53, 0.62, 0.74, 0.82, 0.93, 0.95, 0.98, 1]
        static let searchReleaseCopies: [CGFloat] = [
            0, 0, 0, 0.02, 0.11, 0.22, 0.34, 0.46, 0.60, 0.71, 0.80, 0.87, 0.93, 0.95, 0.99, 1,
        ]
        nonisolated static let submitFadeOutDuration: TimeInterval = 0.19
        nonisolated static let submitFadeOut = MotionToken.curve(duration: submitFadeOutDuration, .easeOut)
        nonisolated static let searchSubmitRise = MotionToken.spring(duration: 0.36, bounce: 0)
        // The fade back when search reopens during a submit.
        nonisolated static let submitFadeIn = MotionToken.curve(duration: 0.12, .easeOut)
        // The submitted page's reveal: what has painted brightens together from the swap on this fade (Go + 12 to
        // about Go + 26).
        nonisolated static let submitPageFadeIn = MotionToken.curve(duration: 0.225, .easeOut)
        // The page's rise after a submit: this spring, starting submitPageRiseDelay after Go while the page is still
        // hidden, from submitPageRise below (fitted to 0.16 to 0.18 pt RMS, within 2 px at Go + 14 to 36). About the
        // last 60 pt show once the page is swapped in.
        nonisolated static let submitPageRise = MotionToken.spring(duration: 0.40, bounce: 0)
        static let submitPageRiseDelay: TimeInterval = 0.095
        // Counted from the swap, about 11 frames after Go: the bar's first pixels come 46 to 50 frames after Go,
        // painted page or not.
        static let barIntroDelay: TimeInterval = 0.57
        nonisolated static let loadingLineHeadStep = MotionToken.curve(duration: 0.2, .linear)
        static let loadingRingTurnDuration: TimeInterval = 1
        nonisolated static let refreshRelease = MotionToken.spring(duration: 0.34, bounce: 0)
        static let refreshBounceHandoff: TimeInterval = 0.05
        nonisolated static let searchCopyHold: TimeInterval = 0.05
        static let searchCopyFade: TimeInterval = 0.05
        // Platform: iOS 26 controls scale on touch-down and spring back on release.
        nonisolated static let press = MotionToken.spring(duration: 0.12, bounce: 0)
        nonisolated static let pressRelease = MotionToken.spring(duration: 0.3, bounce: 0.15)
        // Platform: a UIKit table cell's highlight clears with a short fade on deselect.
        nonisolated static let rowRelease = MotionToken.curve(duration: 0.2, .easeOut)
        nonisolated static let emptyDeckAppear = MotionToken.curve(duration: 0.185, .easeOut)
        // The swipe to remove a recent, neither with an overshoot. A release from a
        // 170 pt capsule leaves no capsule after 16 frames, and the rows close a removed row's gap in 14. Fitted on the
        // farm sim: 0.25 s cleared the capsule in 10 frames, 0.23 s closed the gap in 12.
        nonisolated static let recentReturn = MotionToken.spring(duration: 0.4, bounce: 0)
        nonisolated static let recentCollapse = MotionToken.spring(duration: 0.25, bounce: 0)
        // The "Remove" label's move to the capsule's leading side at the arm, so the arm haptic lands on a visible change.
        nonisolated static let recentLabel = MotionToken.spring(duration: 0.2, bounce: 0)
        // The bar swipe: a release
        // lands in 12 to 17 frames with no overshoot, the deck zoom's spring. The pages arm to
        // cards in 14 to 16 frames, the same spring, and a card left on a newer-tab landing drops into the tab stack
        // in 8 frames.
        nonisolated static let barSwipeSettle = deckZoom
        nonisolated static let barSwipeArm = deckZoom
        nonisolated static let barSwipeDrop = MotionToken.spring(duration: 0.13, bounce: 0)
        // The flick: the live page arms, and the previous tab's card zooms to the screen on landing, on the deck zoom's
        // spring; the page left drops into the tab stack in 6 to 8 frames.
        nonisolated static let tabStackFlickSettle = deckZoom
        nonisolated static let tabStackFlickDrop = barSwipeDrop
        // The camera and microphone prompt's rise, return and close.
        nonisolated static let permissionSheet = MotionToken.spring(duration: 0.3, bounce: 0)
        // The incognito toggle: the field,
        // the sheet and the "Incognito" label run linearly over 11 to 12 frames each way. With the field empty the rows
        // fade out over 8 frames and the notice fades in over 5 from frame 10; turning off, the notice goes over 5 and
        // the rows return over 5 from frame 9.
        nonisolated static let privateToggle = MotionToken.curve(duration: 0.19, .linear)
        nonisolated static let privateRowsFade = MotionToken.curve(duration: 8.0 / 60, .linear)
        nonisolated static let privateNoticeFade = MotionToken.curve(duration: 5.0 / 60, .linear)
        static let privateNoticeDelay: TimeInterval = 10.0 / 60
        static let privateRowsReturnDelay: TimeInterval = 9.0 / 60

        static func token(for interaction: Interaction) -> MotionToken? {
            switch interaction {
            // An empty field leads the keyboard once its rest is known; a prefilled one rides the keyboard.
            case .foregroundRaise, .plusTap: searchOpen
            case .launch, .menuAddressEdit: .keyboard
            case .tabStackTap, .pinchSwitcher, .deckCardTap, .deckBackgroundTap, .archiveRestore, .macTabsPick: deckZoom
            case .barSwipeSettle: barSwipeSettle
            case .permissionAnswer: permissionSheet
            case .tabStackFlick: tabStackFlickSettle
            case .deckSettle, .cardReturn: deckSnap
            // The thrown card coasts from the finger (archiveFlyOffMinimumCoast); the rest close the gap.
            case .cardThrow: archiveGapClose
            case .deckEmptied: emptyDeckAppear
            case .suggestionTap, .searchSubmit: submitFadeOut
            case .searchDragReturn: searchReturn
            case .searchDragDismiss: searchReleaseClose
            case .searchDimTap: searchTapClose
            case .pullRelease: refreshRelease
            case .barHide, .barShow, .barIntro: bar
            case .chevronTap: menuOpen
            case .menuDragReturn: menuReturn
            case .displayOptionsToggle: menuFold
            case .menuDragDismiss, .menuDimTap, .menuAddressSubmit, .menuFind, .menuShare, .menuTranslate, .restorePage: menuClose
            case .menuNav, .menuCopyLink, .pin, .unpin: press
            case .recentRemove: recentCollapse
            case .recentReturn: recentReturn
            case .readerOpen: readerOpen
            case .readerClose, .readerDragDismiss: readerClose
            case .readerDragReturn: readerReturn
            case .privateToggle: privateToggle
            // Driven per frame from the finger or the scroll view.
            case .deckScroll, .cardLift, .pullTick, .pullArm, .searchGrabDuringOpen, .menuGrabDuringOpen, .barSwipe: nil
            // Nothing moves: the card stays opaque, the field clears and the label swaps without animation.
            case .cardArchiveArm, .recentArm, .searchTyping, .searchClear, .desktopToggle, .clearData, .barSwipeTick: nil
            // The glyph swaps to a spinner; nothing moves.
            case .barTranslate: nil
            // The page's own paint is the motion.
            case .refreshLand: nil
            // System UI or WebKit owns the motion.
            case .chevronLongPress, .archiveOpen, .macTabsOpen, .settingsOpen, .archiveDelete, .settingsChange,
                .sheetDone, .webEdgeSwipe, .zoomStep:
                nil
            }
        }
    }

    enum Feedback {
        static func event(for interaction: Interaction) -> HapticEvent? {
            switch interaction {
            // The pinch presses the tab stack button, so it plays the button's tap.
            case .tabStackTap, .pinchSwitcher: .switcherOpened
            case .tabStackFlick, .archiveRestore, .macTabsPick: .tabSwitched
            case .deckSettle: .cardSettled
            case .plusTap: .searchOpened
            case .chevronTap: .menuOpened
            // The eyes tap as their neighbour the clear button and the menu's toggles do; the footage cannot show it.
            case .searchClear, .menuNav, .menuFind, .menuShare, .desktopToggle, .displayOptionsToggle, .menuTranslate,
                .restorePage, .readerOpen, .readerClose, .archiveOpen, .macTabsOpen, .settingsOpen, .permissionAnswer,
                .privateToggle:
                .buttonTap
            case .barTranslate: .buttonTap
            case .suggestionTap: .tabOpened
            case .pullTick: .refreshNearing
            case .pullArm: .refreshArmed
            // The arm already promised the refresh; a release tap 100 to 400 ms later read as a double click.
            case .pullRelease: nil
            case .refreshLand: .refreshLanded
            case .pin, .unpin: .pinToggled
            case .chevronLongPress: .longPress
            case .menuCopyLink: .linkCopied
            case .zoomStep: .zoomStepped
            case .clearData: .dataCleared
            case .barSwipeTick: .tabPaged
            // The ticks per tab are the swipe's feedback; neither the drag nor its landing adds one.
            case .barSwipe, .barSwipeSettle: nil
            case .recentArm: .recentArmed
            // Haptics answer user actions only (platform, HIG).
            case .launch, .foregroundRaise, .barIntro: nil
            // A return to the active tab is a dismissal (review 2 #11). A tap plays when the switcher opens, never
            // when a card zooms in to its page.
            case .deckBackgroundTap, .deckCardTap: nil
            // A swipe up closes a tab and Enter opens a page, neither with a tap; a
            // suggestion tap keeps its tap.
            case .cardArchiveArm, .cardThrow, .searchSubmit: nil
            // As in the iOS app switcher, a drag never ticks.
            case .deckScroll, .cardLift: nil
            // A non-event, or the throw already played.
            case .cardReturn, .deckEmptied: nil
            // The keyboard owns key feedback (platform).
            case .searchTyping, .menuAddressEdit, .menuAddressSubmit: nil
            // Silent dismissals, as on the platform's system sheets.
            case .searchDragDismiss, .searchDragReturn, .searchDimTap, .searchGrabDuringOpen, .menuDragDismiss,
                .menuDragReturn, .menuGrabDuringOpen, .menuDimTap, .readerDragDismiss, .readerDragReturn, .sheetDone:
                nil
            // Chrome follows content (platform).
            case .barHide, .barShow: nil
            // System controls and WebKit own their feedback.
            case .archiveDelete, .settingsChange, .webEdgeSwipe: nil
            // The arm already confirmed the removal; a return is a non-event.
            case .recentRemove, .recentReturn: nil
            }
        }

        // The step is the pull tick's step; every other event has one pattern.
        static func feedback(for event: HapticEvent, step: Int = 0) -> HapticFeedback {
            switch event {
            case .switcherOpened, .tabSwitched, .cardSettled, .buttonTap, .searchOpened, .menuOpened, .tabOpened,
                .recentArmed:
                Haptic.medium
            case .longPress: Haptic.rigid
            case .pinToggled, .zoomStepped, .tabPaged: Haptic.selection
            case .linkCopied, .dataCleared: Haptic.success
            case .refreshNearing: Haptic.refreshTicks[step]
            case .refreshArmed: Haptic.refreshArm
            case .refreshLanded: Haptic.refreshLand
            }
        }
    }

    // UIKit's impact styles read louder, not crisper, as their intensity rose (medium 0.8 felt stronger but not
    // as nice), so every impact is a Core Haptics pattern with its own sharpness. The names keep the weights they
    // replaced. The selection tick and the success notification stay the system's own, as on its pickers and
    // confirmations. Medium 0.8 and firm 0.9 still felt a bit strong, and the refresh set weak. Patterns get their
    // presence from sharpness and short decays: confirms at 0.45 to 0.55, the refresh set at 0.35 to 0.8, the arm's
    // thock the strongest.
    enum Haptic {
        // Scales every Core Haptics intensity when its player is built: the one knob for the whole set.
        static let strength: Float = 1
        // Tuned on the phone (confirms still a bit strong, refresh weak): every confirm one step down, the refresh
        // set one step up.
        // A crisp confirm.
        static let medium = HapticFeedback.pattern(HapticPattern(.tap(0.45, 0.6)))
        // The crispest confirm, for a deliberate hold.
        static let rigid = HapticFeedback.pattern(HapticPattern(.tap(0.55, 0.8)))
        static let selection = HapticFeedback.selection
        static let success = HapticFeedback.notification(.success)
        // The pull's ratchet: one tap per Refresh.tickStep of travel, out and back, rising through this range a step
        // at a time toward the arm. The range's end is the arm's own step, so the last tick sits a step under it.
        static let pullTickIntensity: ClosedRange<Float> = 0.3...0.55
        static let pullTickSharpness: Float = 0.6
        static let refreshTicks = (1..<Int(Refresh.armDistance / Refresh.tickStep)).map { step in
            let share = Float(step) / Float(Refresh.armDistance / Refresh.tickStep)
            let span = pullTickIntensity.upperBound - pullTickIntensity.lowerBound
            return HapticFeedback.pattern(
                HapticPattern(.tap(pullTickIntensity.lowerBound + span * share, pullTickSharpness)))
        }
        // A crisp lead tick primes the skin for the thock 15 ms later (WWDC19 810). The body starts once the thock's
        // cycle ends, so the two never mix above the thock, and fades out in 40 ms.
        static let refreshArm = HapticFeedback.pattern(
            HapticPattern(.tap(0.4, 0.9), .tap(0.8, 0.45, at: 0.015), .fade(0.4, 0.15, over: 0.04, at: 0.03)))
        // A pull tick closer than this to the last pull haptic is skipped: a fast pull crosses the steps about 30 ms
        // apart, and back-to-back taps merge into a buzz.
        static let pullTickGap: Duration = .milliseconds(60)
        // The pull's texture: a continuous event under the finger from the pull's first frame to its release. Its
        // intensity follows the page's speed each frame, full at pullTextureSpeed points per second and nothing while
        // the finger rests; its sharpness rises through its range with the pull. Core Haptics ends a continuous event
        // at 30 s, so a pull held longer than that goes quiet until the release.
        static let pullTexture = HapticTexture(intensity: 0.3, sharpness: 0.1...0.4)
        nonisolated static let pullTextureSpeed: CGFloat = 1500
        static let textures = [pullTexture]
        // A double tap as the fresh page shows, the second a touch firmer.
        static let refreshLand = HapticFeedback.pattern(HapticPattern(.tap(0.5, 0.5), .tap(0.6, 0.5, at: 0.07)))
        static let all = [medium, rigid, selection, success] + refreshTicks + [refreshArm, refreshLand]
        // A prepared generator idles again after a short while, so one prepared longer ago is prepared again.
        static let preparedFor: Duration = .seconds(1)
        // UIKit's haptic engine cooled down 2.9 s after its last start on the phone. After any
        // touch the generators and the Core Haptics engine are prepared again faster than that, until the user has
        // not touched for a while.
        static let keepWarmEvery: TimeInterval = 2
        static let keepWarmAfterTouch: Duration = .seconds(10)
    }

    enum Latency {
        nonisolated static let frameRate: Double = 120
        nonisolated static let frame: Duration = .seconds(1 / frameRate)
        nonisolated static let frameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        // The system sheets' presentation and dismissal, which run on UIKit's own curve.
        static let systemSheetHold: TimeInterval = 0.5
        // How long a tapped link waits for iOS to say whether an app claims it before the page loads anyway. A warm
        // answer takes well under a millisecond; a domain's first lookup can take most of a second.
        static let appLinkAnswer: Duration = .milliseconds(50)

        static func budget(for interaction: Interaction) -> LatencyBudget {
            switch interaction {
            case .cardArchiveArm, .pullTick, .pullArm, .barSwipeTick, .recentArm: .frames(0)
            case .barTranslate: .frames(2)
            case .launch, .barIntro, .clearData, .refreshLand: .timed
            case .foregroundRaise, .chevronLongPress, .archiveOpen, .macTabsOpen, .settingsOpen, .archiveDelete,
                .settingsChange, .sheetDone, .webEdgeSwipe:
                .system
            case .tabStackTap, .tabStackFlick, .pinchSwitcher, .deckCardTap, .deckBackgroundTap, .deckScroll, .deckSettle,
                .cardLift, .cardThrow, .cardReturn, .deckEmptied, .plusTap, .searchTyping, .searchClear, .suggestionTap,
                .searchSubmit, .searchDragDismiss, .searchDragReturn, .searchDimTap, .searchGrabDuringOpen, .pullRelease, .barHide, .barShow,
                .chevronTap, .menuDragDismiss, .menuDragReturn, .menuGrabDuringOpen, .menuDimTap, .menuNav,
                .menuCopyLink, .menuAddressEdit, .menuAddressSubmit, .pin, .unpin, .menuFind, .menuShare, .zoomStep,
                .desktopToggle, .displayOptionsToggle, .menuTranslate, .restorePage, .archiveRestore, .macTabsPick,
                .barSwipe, .barSwipeSettle, .recentRemove, .recentReturn, .readerOpen, .readerClose, .readerDragDismiss,
                .readerDragReturn, .permissionAnswer, .privateToggle:
                .frames(2)
            }
        }

        // How long the deck rests in the browser before the active tab's deck neighbours are made live, so the next
        // swipe after a pause lands on a warm page and a chain of gestures warms nothing.
        static let neighbourWarmDelay: TimeInterval = 0.5
    }

    enum Palette {
        #if DEBUG
        // The demos' submitted page background, as a CSS hex.
        static let demoSubmitPage = "261d33"
        #endif
        static let searchBackdrop = hex(0x1E1C2D)
        // Settings' Downloads capsule.
        static let settingsButtonFill = hex(0x3B3B3B)
        // Drawn at Opacity.searchDim over the page behind the open search sheet.
        static let searchDim = Color.black
        // The page menu's sheet runs from this colour at its top to the same mixed with the site's colour at
        // Opacity.menuSheetTint at the screen's bottom (measured over fast.com).
        static let menuSheetTop = uiHex(0xF3F3F4)
        // The dark sheet keeps its colour and takes the same tint and fills.
        static let menuSheetDark = uiHex(0x1C1C1E)
        // The menu draws its fills, lines and text in black on a light page and in white on a dark one, at the
        // Opacity.menu* levels.
        static func menuInk(light: Bool) -> Color {
            light ? .black : .white
        }
        // The tracker footer's second line on a light sheet.
        static let menuFooterSecondary = uiHex(0x6B6268)
        static let deckGradientStops: [Gradient.Stop] = [
            .init(color: hex(0x19192A), location: 0), .init(color: hex(0x1B1928), location: 0.33),
            .init(color: hex(0x2D1C1E), location: 0.67), .init(color: hex(0x251D26), location: 1),
        ]
        static let deckBarStrip = hex(0x24252D)
        static let missingFavicon = hex(0x3A3A3C)
        static let searchCaret = hex(0x6D7CDB)
        // Platform: a UIKit table cell's default selected background.
        static let suggestionHighlight = Color(uiColor: .systemGray4)
        static let recentRemove = Color(uiColor: .systemRed)
        // Platform: a sheet's grabber.
        static let permissionGrabber = Color(uiColor: .tertiaryLabel)
        static let newTabPlaceholder = Color.black
        // The reader's container, its page's own and under-page background, and so what shows until the article
        // paints and past its ends: the same system background reader.css draws with Canvas.
        static let readerBackground = UIColor.systemBackground
        // Between the fading sheet and a submitted page a neutral dark grey (33, 34, 36) shows from Go + 7 to 11, not
        // the open's navy backdrop. The staging cover and a submitted page not yet painted when
        // the fade ends both show it.
        static let submitBackdrop = hex(0x212224)
        static let submittedPagePlaceholder = submitBackdrop
        // Incognito. The
        // field turns #2D2D2D and the whole sheet darkens: a black shade at Opacity.privateSheetShade takes it from
        // #353437 to about #1F1F1F. A private page sits under a black band with a white label and a dark red ring round
        // the island (measured #3D1213 on a 1 pt line, so the line itself is brighter). A private card is a flat grey,
        // and its bar a dark neutral over any page. The submit cover reads #101114 under the band.
        static let privateFieldFill = uiHex(0x2D2D2D)
        static let privateSheetShade = UIColor.black
        static let privateFieldLabel = uiHex(0x959595)
        static let privateNotice = hex(0x9C999A)
        static let privateBand = UIColor.black
        static let privateBandLabel = UIColor.white
        static let privateIslandRing = uiHex(0x6A1E20)
        static let privateCard = hex(0x464646)
        static let privateCardSubtitle = hex(0x8E8F99)
        static let privateBarBackground = hex(0x242328)
        static let privateBarControlFill = hex(0x3A3A41)
        static let privateSubmitCover = uiHex(0x101114)
        // The staging cover and the submit's veil take submitBackdrop as a UIKit colour.
        static let submitCover = uiHex(0x212224)
        static let loadingLineStops: [(distance: CGFloat, color: Color)] = [
            (0, hex(0x4787EB)), (120, hex(0x4852CE)), (190, hex(0x493AB4)), (250, hex(0x4C2D6F)),
        ]

        static func isLight(_ color: UIColor, in traits: UITraitCollection) -> Bool {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.5
        }

        static func uiHex(_ value: Int) -> UIColor {
            UIColor(
                red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }

        static func hex(_ value: Int) -> Color {
            Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }

        private static func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
    }

    // The chrome is one frosted material: a classic UIKit blur that keeps the page's hue, with translucent fills and
    // hairlines on top (measured 2026-10-27). Not Liquid Glass. Tune on the phone.
    enum Frost {
        // The bar's luma fits 0.38 x blurred page + 29, the regular rung of thin, regular, thick;
        // light or dark by the page tint's luminance, so the bar reads light grey over a white page.
        static func bar(light: Bool) -> UIBlurEffect.Style {
            light ? .systemMaterialLight : .systemMaterialDark
        }
        // The search sheet is the bar's own dark material over the dimmed page: 0.40 x dimmed page + 31, about 100 to
        // 110 over white with white text and 41 to 45 over dark.
        static let sheet = UIBlurEffect.Style.systemMaterialDark
        // The fine knob over the sheet's material; each 0.10 darkens about 8 levels over white and 1 over dark.
        static let sheetTint = Palette.uiHex(0x2A2A2C)
        static let sheetTintOpacity: CGFloat = 0
        // The page menu and the permission prompt: a thick material under the measured gradient.
        static func menu(light: Bool) -> UIBlurEffect.Style {
            light ? .systemThickMaterialLight : .systemThickMaterialDark
        }
        // The gradient's opacity over the material: 0.9 on the light look reads the measured 240 to 244 at the top over
        // fast.com within a few levels; 0.7 on the dark look lets the frost show.
        static func menuGradient(light: Bool) -> CGFloat {
            light ? 0.9 : 0.7
        }
    }

    enum Metrics {
        static let barHeight: CGFloat = 42
        static let cardWidthFraction: CGFloat = 0.70
        static let cardCorner: CGFloat = 15
        static let displayCorner: CGFloat = 55
        static let searchSheetCorner: CGFloat = 38
        static let searchSheetAboveKeyboard: CGFloat = 304
        static let pillSize = CGSize(width: 76, height: 39)
        static let controlSize: CGFloat = 35
        static let barControlGap: CGFloat = 12
        static let barHideOffset: CGFloat = 76
        static let barSideInset: CGFloat = 24
        static let barTotalHeight: CGFloat = 76
        // The armed bar swipe: equal cards at this scale,
        // side by side this gap apart, their top this far above the safe-area line.
        static let barSwipeCardScale: CGFloat = 0.9
        static let barSwipeGap: CGFloat = 32
        static let barSwipeCardTopInset: CGFloat = 4
        static let barSwipeCardCorner: CGFloat = 24
        static let barControlCenterFromBottom: CGFloat = 45
        static let hairlineWidth: CGFloat = 0.5

        static let loadingRingSize: CGFloat = 30
        static let loadingRingStroke: CGFloat = 2
        static let loadingRingTopInset: CGFloat = 7
        static let refreshHold = loadingRingSize + 2 * loadingRingTopInset

        static let tabStackThumbnailSize = CGSize(width: 26, height: 34)
        static let tabStackThumbnailOffsets = [CGSize(width: 7, height: -5), CGSize(width: -7, height: 5)]
        static let tabStackThumbnailCorner: CGFloat = 4
        static let tabStackTilt: Double = 7
        static let tabStackButtonSize = CGSize(width: 44, height: 40)
        static let tabStackButtonCenterX: CGFloat = 46
        // The tab stack flick:
        // the live page shrinks to the arm scale in 12 to 15 frames with its bottom-left pinned this far in from the
        // left and up from the screen's bottom; the previous tab comes out of the tab stack button and grows with its
        // rise, the peek scale as its top meets the safe line (the card's size follows its height), then
        // keeps that size wherever it is dragged (grown over 40 pt of travel instead it was the peek's size in three
        // frames of a flick, off the screen below the finger). Its shape follows the law below. The corner reads 4 pt
        // on the thumbnail, about 12 pt once the card is a card and 17 pt at full size, so the grown card keeps the deck
        // card's corner.
        static let tabStackFlickArmScale: CGFloat = 0.84
        static let tabStackFlickPeekScale: CGFloat = 0.63
        static let tabStackFlickInset: CGFloat = 24
        static let tabStackFlickBottomInset: CGFloat = 101
        // The card is upright by this scale.
        static let tabStackFlickUprightScale: CGFloat = 0.2
        // The rising card's shape: the page at one uniform scale, clipped
        // from its top, whose aspect moves from the thumbnail's to the page's by a two time constant decay, here
        // in units of the width growth, this share of the change by the fast constant and the rest by the slow one,
        // so the card is page-shaped within the first third of its growth. The corner follows the same ease.
        static let tabStackFlickShapeFast: CGFloat = 0.02
        static let tabStackFlickShapeSlow: CGFloat = 0.15
        static let tabStackFlickShapeFastShare: CGFloat = 0.6

        static let cardHeightFraction: CGFloat = 0.65
        static let cardTopFraction: CGFloat = 0.188
        static let focusedLeftFraction: CGFloat = 0.205
        static let rightStepFraction: CGFloat = 0.80
        static let leftFirstStepFraction: CGFloat = 0.237
        static let leftStepFraction: CGFloat = 0.039
        static let olderDepthScales: [CGFloat] = [0.98, 0.93]
        static let cardPlaceholderFavicon: CGFloat = 40
        static let cardHeaderGap: CGFloat = 10
        static let cardHeaderHeight: CGFloat = 24
        static let cardHeaderFavicon: CGFloat = 20
        static let cardHeaderFaviconCorner: CGFloat = 4
        static let missingFaviconCorner: CGFloat = 5

        static let browsingShrinkScale: CGFloat = 0.955
        static let switcherShrinkScale: CGFloat = 1
        static let browsingShrinkCorner: CGFloat = 24

        static let searchSheetTopPadding: CGFloat = 16
        static let searchFieldHeight: CGFloat = 48
        static let searchFieldGap: CGFloat = 6
        static let searchFieldInset: CGFloat = 16
        static let searchFieldTextInset: CGFloat = 24
        static let searchClearGap: CGFloat = 8
        static let searchClearCenterInset: CGFloat = 30
        // The eyes take the clear button's place on an empty field.
        static let privateToggleGap: CGFloat = 8
        // A private page's band ends at 68 where a normal one ends at the safe top (62 on the measured phone), with
        // its label's centre 8.5 above the band's end. The island ring outlines the platform's island, shown only on a
        // phone whose safe top is an island's.
        static let privateBandExtra: CGFloat = 6
        static let privateBandLabelCenterFromBottom: CGFloat = 8.5
        static let islandSize = CGSize(width: 126, height: 37.33)
        static let islandTop: CGFloat = 11.33
        static let islandMinimumSafeTop: CGFloat = 59
        static let islandRingWidth: CGFloat = 1
        static let searchMorphPlusLead: CGFloat = 22
        static let searchMorphTextShift: CGFloat = 16
        // The "+" centre sits searchClosePlusLeadPerWidth x width short of this lead from the capsule's leading edge
        // (44.4 at a 74 pt landing), so it lands on the pill's centre whatever the pill's width.
        static let searchClosePlusLeadPerWidth: CGFloat = 0.1
        static let searchClosePlusLead = pillSize.width / 2 + searchClosePlusLeadPerWidth * pillSize.width
        static let suggestionRowHeight: CGFloat = 56
        static let suggestionRowCount = 4
        // The "Remove" capsule: its right edge 11 pt from the screen's, it grows from a dot at 0.58 of its width tall up
        // to 48 pt. Its label sits centred until the arm, then on the leading side, as on a full swipe.
        nonisolated static let recentRemoveInset: CGFloat = 11
        nonisolated static let recentRemoveHeight: CGFloat = 48
        nonisolated static let recentRemoveAspect: CGFloat = 0.58
        static let recentRemoveLabelInset: CGFloat = 16
        static let suggestionFavicon: CGFloat = 20
        static let suggestionIconGap: CGFloat = 9
        static let suggestionRowLeading: CGFloat = 19
        static let suggestionRowTrailing: CGFloat = 32
        static let suggestionFaviconCorner: CGFloat = 6
        static let searchSheetRiseOnSubmit: CGFloat = 250
        static let submitPageRise: CGFloat = 115

        static let loadingLineCore: CGFloat = 1.5
        static let loadingLineLength: CGFloat = 360

        // The page menu's layout, in
        // points from the sheet's top or the card's edge.
        static let menuSheetCorner: CGFloat = 38
        static let menuPadding: CGFloat = 16
        static let menuBottomPadding: CGFloat = 0
        static let navPillHeight: CGFloat = 48
        static let navPillCorner: CGFloat = 24
        static let navPillButtonWidth: CGFloat = 40
        static let navPillInset: CGFloat = 5
        static let menuPillToTiles: CGFloat = 18
        static let menuTileGap: CGFloat = 16
        static let menuTileHeight: CGFloat = 88
        static let menuTileCorner: CGFloat = 18
        // From the tile's bottom to the label's cap top, and from the label's baseline to the first group.
        static let menuTileLabelGap: CGFloat = 11
        static let menuTileLabelTracking: CGFloat = 0.1
        static let menuLabelToList: CGFloat = 19
        static let menuGroupGap: CGFloat = 16
        static let menuListCorner: CGFloat = 14
        static let menuListRowHeight: CGFloat = 48.5
        // Rows are separate fills 0.5 pt apart, so the sheet shows between them.
        static let menuRowGap: CGFloat = 0.5
        static let menuRowTextInset: CGFloat = 53
        static let menuRowIconCentre: CGFloat = 29.5
        static let menuStepperSize = CGSize(width: 89, height: 31)
        static let menuStepperCorner: CGFloat = 8
        static let menuStepperInset: CGFloat = 10
        static let menuStepperDivider: CGFloat = 27
        static let menuChevronCentre: CGFloat = 26.5
        // The tracker footer: two lines, measured 55.4 tall with its text 20.3 in at 440 pt.
        static let menuFooterHeight: CGFloat = 55.4
        static let menuFooterInset: CGFloat = 20.3

        // Substituted into reader.css at load: the longest line, and the side inset.
        static let readerMeasure: CGFloat = 640
        static let readerInset: CGFloat = 20

        static let archiveFavicon: CGFloat = 20
        // The Mac's spaces sheet: the side inset, the title's and the header's top, and the title's room for the header.
        static let macTabsInset: CGFloat = 20
        static let macTabsTop: CGFloat = 20
        static let macTabsTitleBottom: CGFloat = 8
        static let macTabsHeaderGap: CGFloat = 16
        static let macTabsHeaderClearance: CGFloat = 96
        static let macTabsRowHeight: CGFloat = 48
        static let macTabsIconGap: CGFloat = 12
        static let downloadIcon: CGFloat = 28
        static let settingsButtonHeight: CGFloat = 40
        // The camera and microphone prompt, ours. Its height is above the bottom safe area; its grabber is UIKit's size.
        static let permissionSheetHeight: CGFloat = 260
        static let permissionButtonHeight: CGFloat = 50
        static let permissionButtonGap: CGFloat = 12
        static let permissionGlyphGap: CGFloat = 14
        static let permissionSidePadding: CGFloat = 24
        static let permissionGrabberSize = CGSize(width: 36, height: 5)
        static let permissionGrabberTop: CGFloat = 5

        nonisolated static let pressScale: CGFloat = 0.94
        nonisolated static let pressScaleWide: CGFloat = 0.98
        nonisolated static let emptyDeckStartScale: CGFloat = 0.5
        static let importEditorHeight: CGFloat = 160
        // A left card dims this much a slot, to this most; an older card fades in over this much of the zoom.
        nonisolated static let deckLeftDimStep: CGFloat = 0.15
        nonisolated static let deckLeftMaxDim: CGFloat = 0.3
        nonisolated static let deckOlderFadeIn: CGFloat = 0.15
    }

    enum Opacity {
        static let browsingControlFill: CGFloat = 0.08
        // White over the dark bar's material: the pill interiors read +10 to +22 over the bar beside them (seven
        // frames); 10% fits every one and 15% none. Reads about #40414B over a dark bar.
        static let darkBarControlFill: CGFloat = 0.1
        static let tabStackBorder: CGFloat = 0.2
        static let switcherControlFill: CGFloat = 0.12
        static let cardHeaderPin: CGFloat = 0.7
        static let emptyDeckLabel: CGFloat = 0.5
        static let searchDim: CGFloat = 0.2
        static let suggestionSecondary: CGFloat = 0.45
        static let searchFieldPlaceholder: CGFloat = 0.52
        // The field reads (62, 65, 68) on a (41, 41, 42) sheet. Tune on the phone.
        static let searchFieldFill: CGFloat = 0.1
        static let searchFieldRim: CGFloat = 0.13
        static let searchClear: CGFloat = 0.47
        // The incognito sheet reads 54 to 59 against 97 to 111 over the same white page.
        static let privateSheetShade: CGFloat = 0.45
        static let menuDim: CGFloat = 0.2
        static let menuSheetTint: CGFloat = 0.12
        static let menuSheetEdge: CGFloat = 0.12
        // The pill's, tiles' and rows' fill over the sheet, and the stepper's over its row.
        static let menuFill: CGFloat = 0.1
        static let menuStepperFill: CGFloat = 0.06
        static let navPillStroke: CGFloat = 0.12
        static let menuPrimary: CGFloat = 0.88
        static let menuIcon: CGFloat = 0.84
        static let menuSecondary: CGFloat = 0.6
        static let menuChevron: CGFloat = 0.65
        static let navPillDisabled: CGFloat = 0.45
        // A disabled menu row's text and glyph; its fill stays.
        static let menuRowDisabled: CGFloat = 0.45
        static let barEdge: CGFloat = 0.1
        static let searchSheetEdge: CGFloat = 0.12
        static let loadingLineGlow: CGFloat = 0.6
        static let loadingRingHead: CGFloat = 0.6
        static let loadingRingTail: CGFloat = 0.1
    }

    enum Typography {
        static let barPlusGlyph = Font.system(size: 20, weight: .semibold)
        static let barChevronGlyph = Font.system(size: 17, weight: .semibold)
        static let cardHeaderPin = Font.system(size: 11)
        static let cardHeaderTitle = Font.system(size: 15, weight: .semibold)
        static let emptyDeckLabel = Font.system(size: 17, weight: .semibold)
        static let searchFieldUIFont = UIFont.systemFont(ofSize: 20, weight: .medium)
        static let searchClearUIFont = UIFont.systemFont(ofSize: 18.4, weight: .medium)
        static let privateToggleUIFont = UIFont.systemFont(ofSize: 17, weight: .medium)
        static let privateFieldLabelUIFont = UIFont.systemFont(ofSize: 13)
        static let privateBandLabelUIFont = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        static let privateNotice = Font.system(size: 17, weight: .medium)
        static let cardHeaderSubtitle = Font.system(size: 11.5)
        static let suggestionTitle = Font.system(size: 17, weight: .medium)
        static let suggestionSymbol = Font.system(size: 16)
        static let suggestionSubtitle = Font.system(size: 13)
        static let recentRemoveLabel = Font.system(size: 13, weight: .medium)
        static let navPillURL = Font.system(size: 15, weight: .medium)
        static let navPillURLUIFont = UIFont.systemFont(ofSize: 15, weight: .medium)
        static let navPillGlyph = Font.system(size: 15, weight: .medium)
        static let menuTileIcon = Font.system(size: 25, weight: .light)
        // The label's metrics place it under the tile by its cap top and baseline.
        static let menuTileLabelUIFont = UIFont.systemFont(ofSize: 11, weight: .medium)
        static let menuTileLabel = Font(menuTileLabelUIFont)
        static let menuRow = Font.system(size: 16, weight: .medium)
        static let menuRowIcon = Font.system(size: 18)
        static let menuStepperGlyph = Font.system(size: 15)
        static let menuChevronUIFont = UIFont.systemFont(ofSize: 15, weight: .medium)
        static let menuFooter = Font.system(size: 15)
        static let menuFooterCount = Font.system(size: 15, weight: .bold)
        // The sheets follow Dynamic Type beside their system rows: the text styles whose default sizes are the
        // measured 16, 13 and 17 points (DynamicTypeTests).
        static let archiveTitle = Font.system(.callout)
        static let archiveDetail = Font.system(.footnote)
        static let macTabsSpaceTitle = Font.system(.title2, weight: .bold)
        static let macTabsRow = Font.system(.body)
        static let macTabsHeaderGlyph = Font.system(.title2)
        static let downloadTitle = Font.system(.callout)
        static let downloadDetail = Font.system(.footnote)
        static let settingsButton = Font.system(.body)
        static let permissionGlyph = Font.system(size: 34, weight: .regular)
        static let permissionTitle = Font.system(size: 20, weight: .semibold)
        static let permissionButton = Font.system(size: 17, weight: .semibold)
        // The reader's type in the system serif, substituted into reader.css; the title at the platform's Title 1 size.
        static let readerBody = WebFont(family: "ui-serif", size: 19, weight: 400)
        static let readerTitle = WebFont(family: "ui-serif", size: 28, weight: 700)
    }

    enum Gesture {
        nonisolated static let deckAxisLock: CGFloat = 10
        static let tapMaxTravel: CGFloat = 10
        static let tapMaxDuration: TimeInterval = 0.3
        nonisolated static let archiveCommitFraction: CGFloat = 0.6
        nonisolated static let archivePredictedCommitFraction: CGFloat = 0.5
        nonisolated static let tabStackFlickDistance: CGFloat = 30
        // The flick's card follows the finger's offset from the grab this much in both axes, so it moves
        // freely with the finger.
        nonisolated static let tabStackFlickFollow: CGFloat = 1
        // The flick's card starts where it is at the lock, where the finger has led it by the slop, and makes the slop
        // up over this many times its length of further travel: at 1.5 times the finger's speed, about twice the axis
        // lock on a straight pull, with no jump.
        nonisolated static let tabStackFlickCatchUp: CGFloat = 2
        // A two-finger pinch in presses the tab stack button: it fires mid-gesture at this scale, only from and at the
        // page's minimum zoom, where a pinch in only rubber-bands the page and steals no zoom. The gate allows this much
        // float slack.
        nonisolated static let pinchSwitcherScale: CGFloat = 0.85
        nonisolated static let pinchZoomSlack: CGFloat = 0.01
        static let chevronLongPress: TimeInterval = 0.35
        nonisolated static let sheetDragClose: CGFloat = 80
        nonisolated static let sheetDragPredictedClose: CGFloat = 200
        nonisolated static let rubberBandCoefficient: CGFloat = 0.55
        nonisolated static let decelerationNormal: CGFloat = 0.998
        nonisolated static let decelerationFast: CGFloat = 0.99
        nonisolated static let deckStretch: CGFloat = 0.5
        nonisolated static let deckMaxFlickCards = 2
        nonisolated static let deckSettledDistance: CGFloat = 0.05
        nonisolated static let liftStretch: CGFloat = 40
        nonisolated static let sheetStretch: CGFloat = 60
        // Platform: UIKit's pan starts at about 10 pt; 8 pt sits inside it, so a resting finger cannot chatter.
        nonisolated static let detentHysteresis: CGFloat = 8
        nonisolated static let archiveFlickVelocity: CGFloat = 500
        // No arm shows. A row is kept when let go after about 181 pt of travel (a 170 pt capsule, 0.41 of the phone's
        // 440 pt) and removed after about 381 pt (0.87), so the line sits between them, near the kept end.
        nonisolated static let recentRemoveFraction: CGFloat = 0.45
        // A finger still this long before it lifts lets go at rest, as UIKit's pan then reports almost no velocity.
        nonisolated static let flickStill: TimeInterval = 0.05
        // During a zoom the bar drawn more strongly takes touches: the browsing bar below this cross-fade progress,
        // the switcher bar from it.
        static let zoomBarHandOffProgress: CGFloat = 0.5
        // Measured on screenshot pairs of the bar strip, the swap against one frame of the close's own motion (mean, p99).
        // A tapped close: at 3.5 pt 3.0, 22 against 2.8, 21; at 5.5 pt 3.4, 22 against 3.3, 22; at 8.7 pt a step, p99 43
        // against 31. A release close: at 2.4 pt 1.8, 21 against 2.1, 21; at 5.5 pt a slight step, p99 28 against 21.
        // 4 pt sits under both closes' steps.
        nonisolated static let closeBarHandOff: CGFloat = 4
        // A swipe on the bar: a slow release lands on the tab past this fraction of a page; a faster one commits in its
        // direction. A swipe moves at most barSwipeMaxTabs, so one tick per swipe, as Safari pages (a hard
        // flick across two tabs played two ticks). Past either end it stretches this fraction of a page.
        nonisolated static let barSwipeCommitFraction: CGFloat = 0.5
        nonisolated static let barSwipeFlickVelocity: CGFloat = 400
        nonisolated static let barSwipeMaxTabs = 1
        // A drag goes 250 pt past the newest tab at full size with no visible stiffness.
        nonisolated static let barSwipeStretch: CGFloat = 0.7
        // Safari's count: from the fourth dialog in one navigation, a page is offered a way to silence the rest.
        static let dialogMuteAfter = 3
        // A touch on the bar or the tab stack locks after this much radial travel (inside UIKit's 10 pt pan start, as
        // detentHysteresis sits): to the swipe when its path is within axisLockAngle degrees of horizontal, else
        // upward to the flick or downward to the controls. deckAxisLock stays for the deck's own drag and the recents.
        nonisolated static let axisLockDistance: CGFloat = 8
        nonisolated static let axisLockAngle: CGFloat = 35
        // A springing channel is at rest once it is within this many drawn points of its target and under this speed
        // (pt/s, a quarter point per 120 Hz frame): the switch, the catcher and the page's touches follow that frame,
        // about 0.29 s on deckZoom for a page, not the spring's 0.37 s settling time.
        nonisolated static let landedPoints: CGFloat = 0.5
        nonisolated static let landedSpeed: CGFloat = 30
        // The bar hides after this much user scroll down and shows after this much up.
        nonisolated static let barHideDistance: CGFloat = 24
        nonisolated static let barShowDistance: CGFloat = 12
        // The deck builds this many cards behind the span of a motion and this many ahead of it.
        nonisolated static let deckBuiltBehind: CGFloat = 4
        nonisolated static let deckBuiltAhead: CGFloat = 2
    }

    enum Refresh {
        nonisolated static let armDistance: CGFloat = 150
        // The pull ticks each time it crosses a multiple of this distance, out and back, until it arms; the arm
        // distance is a whole number of steps, the last of them the line.
        nonisolated static let tickStep: CGFloat = 10
        // Arcs at 0.24, 0.38 and 0.46 sit at 0.92, 0.93 and 0.94 of the closed radius.
        nonisolated static let ringStartScale: CGFloat = 0.89
        // On the arm the ring pops to 1.146 at 150 ms and is back at 1.0 by 300 ms.
        static let armPulseScale: CGFloat = 1.15
        static let armPulseDuration: TimeInterval = 0.3
    }

    enum Blocking {
        // How long a page's DOM changes gather before procedural selectors run again. Short enough that a late ad goes
        // within half a second, long enough that a page that keeps changing (a feed, a player) does not run every
        // selector, :has-text scans included, ten times a second for its whole life.
        static let cosmeticRecheck: Duration = .milliseconds(500)
        // How long after load, or after the first unlock if that is later, the cookie wall unlock keeps watching html
        // and body. A consent manager locks the page while it loads; a lock after this is the site's own.
        static let cookieWallWatch: Duration = .seconds(3)
    }

    enum Energy {
        // At this thermal state and above, as in Low Power Mode, prewarming, favicon fetches and the haptic keep-warm
        // stop.
        nonisolated static let reducedThermalState: ProcessInfo.ThermalState = .serious
    }

    enum Snapshot {
        // Full pictures kept decoded beyond the active tab, its neighbours and the previous tab: the deck's rest span
        // (CardLayout.span, five cards) must fit, so a capture landing while the switcher rests blanks no card.
        static let spareDecoded = 5
    }

    enum SearchIdle {
        // How long a keystroke keeps the deck's rate: typing faster than this never leaves 120 Hz; a pause longer does.
        nonisolated static let searchTypingHold: TimeInterval = 1.0
    }

    enum Pool {
        // Live web views, plus one pre-warmed.
        static let capacity = 6
        // What a memory warning shrinks the pool to: the active tab plus one.
        static let capacityUnderPressure = 2
    }

    // The error page's look and the app's own network timeouts, in one enum.
    enum Network {
        // The submit cover's neutral: an error after a submit changes no pixel of the backdrop.
        static let errorBackground = UIColor(Palette.submitBackdrop)
        static let errorBackgroundPrivate = Palette.privateSubmitCover
        static let errorInk = UIColor.white
        // The permission prompt's point sizes at the default text size, scaled with the text styles of those sizes: the
        // one screen a user meets when something is wrong reads at any size (DynamicTypeTests).
        static let errorGlyphStyle = UIFont.TextStyle.largeTitle
        static let errorTitleFont = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
        static let errorDetailFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15))
        static let errorButtonFont = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        static let errorButtonHeight = Metrics.permissionButtonHeight
        static let errorButtonMinWidth: CGFloat = 160
        static let errorButtonPadding: CGFloat = 28
        static let errorSidePadding = Metrics.permissionSidePadding
        static let errorGap = Metrics.permissionGlyphGap
        static let errorDetailOpacity = Opacity.menuSecondary
        static let errorButtonFill: CGFloat = 0.12
        // Black over the last picture under the message; set by feel on the phone.
        static let errorSnapshotDim: CGFloat = 0.5
        // The error page fades out on the app's reveal fade when the next page has painted.
        static let errorClear = Motion.submitPageFadeIn
        // The reveal's ceiling after a commit, and the error page's clear after a commit that never finishes.
        nonisolated static let revealDelay: Duration = .seconds(1)
        // A second content-process termination of the same URL inside this window shows the crash page.
        nonisolated static let terminationWindow: Duration = .seconds(120)
        nonisolated static let suggestTimeout: TimeInterval = 2
        nonisolated static let suggestResourceTimeout: TimeInterval = 5
        // The wait before a remote suggestion request; a keystroke inside it cancels the pending one. Ships off: remote
        // rows refresh per keystroke. Opt in on the phone by feel.
        nonisolated static let suggestDebounce: Duration = .zero
        nonisolated static let faviconTimeout: TimeInterval = 10
        nonisolated static let faviconResourceTimeout: TimeInterval = 20
        // A cached icon younger than this is not fetched again.
        nonisolated static let faviconFresh: TimeInterval = 7 * 24 * 60 * 60
    }

    enum Fullscreen {
        // The turn back to portrait is asked for as a fullscreen video's exit starts, as the system player does, so
        // the page under the shrinking video is upright by the time the exit ends; false waits for the exit to finish.
        static let returnsToPortraitOnExitStart = true
    }

    enum Downloads {
        // A download's progress reaches the list at most this often, whatever the chunk rate.
        nonisolated static let progressInterval: Duration = .milliseconds(100)
    }

    enum Text {
        // A title is stored and scanned to this many characters; a longer <title> is a bug or an attack.
        nonisolated static let titleLimit = 1_024
        // A URL is the page's identity and is stored whole, but scanned for suggestions only to this many characters.
        nonisolated static let urlLimit = 8_192
    }

    enum Translate {
        // The characters of page text gathered for language detection: enough for the recognizer, never the whole page.
        static let sampleLength = 2000
        // The bar button's circle edge to the chevron's.
        static let barGap: CGFloat = 12
        // The glyph colour's opacity as the button's fill while the page is translated.
        static let translatedFill: CGFloat = 0.25
    }

    // The app's own pages on the web, opened as tabs.
    enum Links {
        nonisolated static let privacyPolicy = URL(string: "https://www.sail.fish/privacy")!
    }
}

// A font as a stylesheet names it, for the pages the app writes itself.
nonisolated struct WebFont: Equatable, Sendable {
    let family: String
    let size: CGFloat
    let weight: Int
}
