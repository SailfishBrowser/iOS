import SwiftUI

// One tap from the page to the translation the menu row offers. It shows only while the page offers one and the
// reader is closed (BottomBar). No pressed state, as the chevron: the touch is read as the tab stack reads its tap, and
// a bar swipe that starts here pages the tab and translates nothing. The button never caches the offer; it reads the
// translator as it is.
struct TranslateButton: View {
    struct Look: Equatable {
        let showsSpinner: Bool
        let isTranslated: Bool
        let label: String
    }

    @Environment(AppEnvironment.self) private var env
    @GestureState private var isTracking = false
    @State private var pressedAt = Date.distantPast
    let controller: WebTabController
    let fill: Color

    var body: some View {
        let look = Self.look(controller.translator.state, target: controller.translator.target)
        ZStack {
            if look.showsSpinner {
                ProgressView().tint(ForegroundStyle())
            } else {
                Image(systemName: "translate").font(Theme.Typography.barChevronGlyph)
            }
        }
        .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
        .background(
            look.isTranslated ? AnyShapeStyle(.foreground.opacity(Theme.Translate.translatedFill)) : AnyShapeStyle(fill),
            in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(Theme.Opacity.barEdge), lineWidth: Theme.Metrics.hairlineWidth))
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isTracking) { value, isTracking, _ in
                    guard !isTracking else { return }
                    isTracking = true
                    began(DragSample(value))
                }
                .onEnded { ended(DragSample($0)) })
        #if DEBUG
        .debugSurface(.translate) { phase, sample in
            switch phase {
            case .began: began(sample)
            case .ended: ended(sample)
            case .changed, .cancelled: break
            }
        }
        #endif
        .accessibilityLabel(look.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
    }

    static func look(_ state: PageTranslator.State, target: Locale.Language) -> Look {
        switch state {
        case .idle, .failed:
            Look(showsSpinner: false, isTranslated: false, label: "Translate to \(TranslateRow.name(of: target))")
        case .translating: Look(showsSpinner: true, isTranslated: false, label: "Translating")
        case .translated: Look(showsSpinner: false, isTranslated: true, label: "Show Original")
        }
    }

    // The tab stack's tap rule: a release within tapMaxTravel and tapMaxDuration, not during a bar swipe.
    static func isTap(_ sample: DragSample, duration: TimeInterval, isSwiping: Bool) -> Bool {
        !isSwiping && hypot(sample.translation.width, sample.translation.height) < Theme.Gesture.tapMaxTravel
            && duration < Theme.Gesture.tapMaxDuration
    }

    private func began(_ sample: DragSample) {
        pressedAt = sample.time
        env.haptics.prepare(.barTranslate)
    }

    private func ended(_ sample: DragSample) {
        if Self.isTap(
            sample, duration: sample.time.timeIntervalSince(pressedAt), isSwiping: env.pager?.isSwiping == true)
        {
            tap()
        }
    }

    // The spinner takes no tap: its run is already queued.
    private func tap() {
        guard controller.translator.state != .translating else { return }
        TranslateRow.tap(controller.translator, firing: .barTranslate, closingMenu: false, env: env)
    }
}
