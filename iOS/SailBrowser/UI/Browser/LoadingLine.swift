import SwiftUI

struct LoadingLine: View {
    private static let length = Theme.Metrics.loadingLineLength
    private static let core = Theme.Metrics.loadingLineCore
    private static let tail = Theme.Palette.loadingLineStops.last!.color
    private static let gradient = Gradient(
        stops: Theme.Palette.loadingLineStops.reversed().map { .init(color: $0.color, location: 1 - $0.distance / length) })

    let controller: WebTabController
    @State private var progress = 0.0

    var body: some View {
        let isVisible = controller.isLoading
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                Self.tail.frame(width: width)
                LinearGradient(gradient: Self.gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.length)
            }
            .offset(x: progress * width - width - Self.length)
            .frame(width: width, alignment: .leading)
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: progress, anchor: .leading)
            }
            .shadow(color: Theme.Palette.loadingLineStops[0].color.opacity(Theme.Opacity.loadingLineGlow), radius: Self.core)
        }
        .frame(height: Self.core)
        .opacity(isVisible ? 1 : 0)
        .animation(Theme.Motion.fade.animation, value: isVisible)
        .allowsHitTesting(false)
        // The head's step runs on SwiftUI's clock, which the vote does not move, so a step holds none.
        .onChange(of: controller.progress, initial: true) { old, new in
            withAnimation(new > old ? Theme.Motion.loadingLineHeadStep.animation : nil) { progress = new }
        }
        .onChange(of: isVisible) { FrameRateVote.hold(Theme.Motion.fade) }
    }
}
