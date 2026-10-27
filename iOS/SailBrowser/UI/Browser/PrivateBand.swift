import SwiftUI
import UIKit

// A private page sits under a black band a little taller than the safe top, "Incognito" under the island and a dark
// red ring round the island. It rides inside the page's card, and over the submit cover while a private page loads.
class PrivateBandView: UIView {
    let label = UILabel()
    let ring = CAShapeLayer()
    private var safeTop: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Palette.privateBand
        isUserInteractionEnabled = false
        label.text = "Incognito"
        label.font = Theme.Typography.privateBandLabelUIFont
        label.textColor = Theme.Palette.privateBandLabel
        addSubview(label)
        ring.fillColor = nil
        ring.strokeColor = Theme.Palette.privateIslandRing.cgColor
        ring.lineWidth = Theme.Metrics.islandRingWidth
        layer.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func picture(width: CGFloat, safeTop: CGFloat) -> UIImage {
        let band = PrivateBandView(
            frame: CGRect(x: 0, y: 0, width: width, height: safeTop + Theme.Metrics.privateBandExtra))
        band.layout(safeTop: safeTop)
        return UIGraphicsImageRenderer(bounds: band.bounds).image { band.layer.render(in: $0.cgContext) }
    }

    // The page's host hands the safe top over on every frame the card moves; only a new one lays out.
    func layout(safeTop: CGFloat) {
        guard safeTop != self.safeTop else { return }
        self.safeTop = safeTop
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.sizeToFit()
        label.center = CGPoint(x: bounds.midX, y: bounds.height - Theme.Metrics.privateBandLabelCenterFromBottom)
        guard let safeTop else { return }
        let size = Theme.Metrics.islandSize
        let island = CGRect(x: bounds.midX - size.width / 2, y: Theme.Metrics.islandTop, width: size.width, height: size.height)
        let outline = island.insetBy(dx: -Theme.Metrics.islandRingWidth / 2, dy: -Theme.Metrics.islandRingWidth / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = safeTop < Theme.Metrics.islandMinimumSafeTop
        ring.path = UIBezierPath(roundedRect: outline, cornerRadius: outline.height / 2).cgPath
        CATransaction.commit()
    }
}

struct PrivateBand: UIViewRepresentable {
    let safeTop: CGFloat

    func makeUIView(context: Context) -> PrivateBandView {
        PrivateBandView()
    }

    func updateUIView(_ band: PrivateBandView, context: Context) {
        band.layout(safeTop: safeTop)
    }
}
