import SwiftUI

// The zoom control: minus and plus in one box, a hairline between them, and no percentage.
struct ZoomStepper: View {
    @Environment(AppEnvironment.self) private var env
    let host: String
    let ink: Color

    var body: some View {
        let zoom = env.zoom(forHost: host)
        HStack(spacing: 0) {
            stepButton("minus", label: "Zoom Out", enabled: ZoomSteps.previous(before: zoom) != nil) {
                step(to: ZoomSteps.previous(before:))
            }
            Rectangle()
                .fill(ink.opacity(Theme.Opacity.navPillStroke))
                .frame(width: Theme.Metrics.hairlineWidth, height: Theme.Metrics.menuStepperDivider)
            stepButton("plus", label: "Zoom In", enabled: ZoomSteps.next(after: zoom) != nil) {
                step(to: ZoomSteps.next(after:))
            }
            #if DEBUG
            .debugAction(.zoomStep) { step(to: ZoomSteps.next(after:)) }
            #endif
        }
        .frame(width: Theme.Metrics.menuStepperSize.width, height: Theme.Metrics.menuStepperSize.height)
        .background(
            ink.opacity(Theme.Opacity.menuStepperFill),
            in: RoundedRectangle(cornerRadius: Theme.Metrics.menuStepperCorner, style: .continuous))
    }

    private func step(to target: (Double) -> Double?) {
        env.haptics.fire(.zoomStep)
        env.setZoom(target(env.zoom(forHost: host))!, forHost: host)
    }

    private func stepButton(
        _ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.Typography.menuStepperGlyph)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.navPillDisabled)
        .accessibilityLabel(label)
    }
}
