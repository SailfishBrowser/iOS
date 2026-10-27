import SwiftUI
import UIKit

struct LoadingRing: View {
    let controller: WebTabController

    var body: some View {
        RingArc(
            progress: controller.pullProgress, isSpinning: controller.isPullRefreshing,
            isArmed: controller.isPullArmed)
            .frame(width: Theme.Metrics.loadingRingSize, height: Theme.Metrics.loadingRingSize)
            .padding(.top, Theme.Metrics.loadingRingTopInset)
            .offset(y: controller.refreshGap - Theme.Metrics.refreshHold)
            .frame(height: Theme.Metrics.refreshHold, alignment: .top)
            .clipped()
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

private struct RingArc: UIViewRepresentable {
    #if DEBUG
    @Environment(AppEnvironment.self) private var env
    #endif
    let progress: CGFloat
    let isSpinning: Bool
    let isArmed: Bool

    func makeUIView(context: Context) -> RingView {
        let view = RingView()
        #if DEBUG
        env.publishDebugWatch(.webScroll, owner: context.coordinator.owner) { [unowned view] in view.presentedScale }
        #endif
        return view
    }

    func updateUIView(_ view: RingView, context: Context) {
        view.update(progress: progress, isSpinning: isSpinning, isArmed: isArmed)
    }

    #if DEBUG
    final class Coordinator {
        let env: AppEnvironment
        let owner = UUID()

        init(env: AppEnvironment) {
            self.env = env
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(env: env)
    }

    static func dismantleUIView(_ view: RingView, coordinator: Coordinator) {
        coordinator.env.withdrawDebugWatch(.webScroll, owner: coordinator.owner)
    }
    #endif
}

final class RingView: UIView {
    private static let spinKey = "spin"
    static let pulseKey = "pulse"

    private let ring = CALayer()
    private let arc = CAShapeLayer()
    private let fill = CAGradientLayer()
    private var isShown = false
    private var isArmed = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        arc.fillColor = nil
        arc.strokeColor = UIColor.white.cgColor
        arc.lineWidth = Theme.Metrics.loadingRingStroke
        arc.lineCap = .round
        arc.strokeEnd = 0
        fill.type = .conic
        fill.startPoint = CGPoint(x: 0.5, y: 0.5)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        fill.colors = [Theme.Opacity.loadingRingTail, Theme.Opacity.loadingRingHead].map { UIColor.white.withAlphaComponent($0).cgColor }
        fill.mask = arc
        ring.addSublayer(fill)
        layer.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    #if DEBUG
    var presentedScale: CGFloat {
        ring.drawn.transform.m11
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        fill.frame = bounds
        arc.frame = bounds
        arc.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: (bounds.width - arc.lineWidth) / 2,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        CATransaction.commit()
    }

    func update(progress: CGFloat, isSpinning: Bool, isArmed: Bool) {
        if isArmed, !self.isArmed {
            pulse()
        }
        self.isArmed = isArmed
        if isSpinning {
            if fill.animation(forKey: Self.spinKey) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = Theme.Motion.loadingRingTurnDuration
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                spin.preferredFrameRateRange = Theme.Latency.frameRateRange
                fill.add(spin, forKey: Self.spinKey)
            }
            setScale(1)
        } else if progress > 0 {
            fill.removeAnimation(forKey: Self.spinKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.strokeEnd = progress
            CATransaction.commit()
            setScale(Theme.Refresh.ringStartScale + (1 - Theme.Refresh.ringStartScale) * progress)
        }
        setShown(isSpinning || progress > 0)
    }

    private func pulse() {
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1, Theme.Refresh.armPulseScale, 1]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        pulse.duration = Theme.Refresh.armPulseDuration
        pulse.preferredFrameRateRange = Theme.Latency.frameRateRange
        ring.add(pulse, forKey: Self.pulseKey)
        FrameRateVote.hold(for: pulse.duration)
    }

    private func setScale(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    private func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        Theme.Motion.fade.animate(initialVelocity: 0) {
            self.alpha = shown ? 1 : 0
        } completion: { _ in
            if !self.isShown {
                self.fill.removeAnimation(forKey: Self.spinKey)
            }
        }
        FrameRateVote.hold(Theme.Motion.fade)
    }
}
