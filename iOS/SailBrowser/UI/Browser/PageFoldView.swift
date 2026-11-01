import UIKit

// The page as strips of paper over its summary card. The strips are snapshot views, which return at once and are
// filled by the render server at the next commit, so the first frame never waits on an image. Per frame only layer
// transforms and opacities change: no layout, no SwiftUI state, no image work.
final class PageFoldView: UIView {
    // Its backing layer keeps the strips in one 3D space under one perspective.
    private final class Paper: UIView {
        override class var layerClass: AnyClass {
            CATransformLayer.self
        }
    }

    private let card: UIView
    // A plain layer flattens the paper into its own plane, so the card stays behind it: in one 3D context the render
    // server would sort the card in front of every crease that turns away from the eye.
    private let sheet = UIView()
    private let paper = Paper()
    private let strips: [UIView]
    private let shades: [CAGradientLayer]
    // The display stays at the full rate from the pinch's begin until the fold is removed.
    private let presence = FrameRateVote.Presence()
    var cardInsets = UIEdgeInsets.zero {
        didSet { setNeedsLayout() }
    }

    init(page: UIView, card: UIView) {
        self.card = card
        let size = page.bounds.size
        let height = size.height / CGFloat(Theme.Fold.strips)
        let frames = (0..<Theme.Fold.strips).map {
            CGRect(x: 0, y: CGFloat($0) * height, width: size.width, height: height)
        }
        strips = frames.map { frame in
            let strip = UIView(frame: frame)
            let snapshot = page.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)!
            snapshot.frame = strip.bounds
            strip.addSubview(snapshot)
            return strip
        }
        // An even strip's valley crease is its top edge, an odd strip's its bottom.
        shades = frames.indices.map { index in
            let shade = CAGradientLayer()
            let crease = UIColor.black.withAlphaComponent(Theme.Fold.creaseShade).cgColor
            let clear = UIColor.black.withAlphaComponent(0).cgColor
            shade.colors = index.isMultiple(of: 2) ? [crease, clear] : [clear, crease]
            shade.frame = CGRect(origin: .zero, size: frames[index].size)
            shade.opacity = 0
            return shade
        }
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = Theme.Fold.backdrop
        addSubview(card)
        sheet.isUserInteractionEnabled = false
        sheet.frame = bounds
        addSubview(sheet)
        paper.frame = sheet.bounds
        paper.layer.sublayerTransform.m34 = -1 / Theme.Fold.perspective
        sheet.addSubview(paper)
        for (strip, shade) in zip(strips, shades) {
            strip.layer.addSublayer(shade)
            paper.addSubview(strip)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = bounds.inset(by: cardInsets)
    }

    func set(progress: CGFloat, anchor: CGFloat) {
        let transforms = PageFold.transforms(
            progress: progress, strips: strips.count, height: bounds.height, anchor: anchor)
        let shade = Float(PageFold.shade(progress: progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (strip, transform) in zip(strips, transforms) {
            strip.layer.transform = transform
        }
        for layer in shades {
            layer.opacity = shade
        }
        paper.layer.opacity = Float(PageFold.opacity(progress: progress))
        CATransaction.commit()
    }
}
