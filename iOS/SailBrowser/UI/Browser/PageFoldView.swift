import UIKit

// The page as two halves of paper over its summary card and the glow of its tint. The fold sits over the band, so the
// band rides on the top half and the glow reaches the status bar once the paper has gone. The halves are snapshot
// views, which return at once and are filled by the render server at the next commit, so the first frame never waits
// on an image. Per frame only layer transforms and opacities change: no layout, no SwiftUI state, no image work. The
// halves are cut at one size, so a rotation or a window resize, which changes the stage's size, ends the fold.
final class PageFoldView: UIView {
    // Its backing layer keeps the halves in one 3D space under one perspective.
    private final class Paper: UIView {
        override class var layerClass: AnyClass {
            CATransformLayer.self
        }
    }

    private let glow: Glow
    private let card: UIView
    // A plain layer flattens the paper into its own plane, so the card stays behind it: in one 3D context the render
    // server would sort the card in front of every crease that turns away from the eye.
    private let sheet = UIView()
    private let paper = Paper()
    private let top: UIView
    private let bottom: UIView
    private let shades: [CAGradientLayer]
    // The display stays at the full rate from the pinch's begin until the fold is removed.
    private let presence = FrameRateVote.Presence()
    private let resized: () -> Void
    // The size at the first layout, once the fold has its place in the stage.
    private var placedSize: CGSize?
    var cardInsets = UIEdgeInsets.zero {
        didSet { setNeedsLayout() }
    }

    init(page: UIView, band: UIView, card: UIView, tint: UIColor, resized: @escaping () -> Void) {
        glow = Glow(tint: tint)
        self.resized = resized
        self.card = card
        let size = page.bounds.size
        let frames = [
            CGRect(x: 0, y: 0, width: size.width, height: size.height / 2),
            CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2),
        ]
        let halves = frames.map { frame in
            let half = UIView(frame: frame)
            let snapshot = page.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)!
            snapshot.frame = half.bounds
            half.addSubview(snapshot)
            return half
        }
        top = halves[0]
        bottom = halves[1]
        // The crease is the top half's lower edge and the bottom half's upper edge.
        let crease = UIColor.black.withAlphaComponent(Theme.Fold.creaseShade).cgColor
        let clear = UIColor.black.withAlphaComponent(0).cgColor
        shades = [[clear, crease], [crease, clear]].map { colors in
            let shade = CAGradientLayer()
            shade.colors = colors
            shade.frame = CGRect(origin: .zero, size: frames[0].size)
            shade.opacity = 0
            return shade
        }
        top.addSubview(band)
        super.init(frame: CGRect(origin: .zero, size: size))
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glow)
        addSubview(card)
        sheet.isUserInteractionEnabled = false
        sheet.frame = bounds
        addSubview(sheet)
        paper.frame = sheet.bounds
        paper.layer.sublayerTransform.m34 = -1 / Theme.Fold.perspective
        sheet.addSubview(paper)
        for (half, shade) in zip(halves, shades) {
            half.layer.addSublayer(shade)
            paper.addSubview(half)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let placedSize, placedSize != bounds.size {
            resized()
            return
        }
        placedSize = bounds.size
        glow.frame = bounds
        card.frame = bounds.inset(by: cardInsets)
    }

    func set(progress: CGFloat, anchor: CGFloat) {
        let halves = PageFold.halves(progress: progress, height: bounds.height, anchor: anchor)
        let shade = Float(PageFold.shade(progress: progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.layer.transform = halves.top
        bottom.layer.transform = halves.bottom
        for layer in shades {
            layer.opacity = shade
        }
        paper.layer.opacity = Float(PageFold.opacity(progress: progress))
        CATransaction.commit()
    }
}

// A dark ground under soft radial pools of the page's tint, at a fixed brightness so a dark page's tint still glows.
// A grey tint glows grey.
private final class Glow: UIView {
    private let pools: [CAGradientLayer]

    init(tint: UIColor) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        pools = Theme.Fold.glowPools.map { pool in
            let color = UIColor(
                hue: (hue + pool.hueTurn).truncatingRemainder(dividingBy: 1), saturation: saturation,
                brightness: Theme.Fold.glowBrightness, alpha: 1)
            let layer = CAGradientLayer()
            layer.type = .radial
            layer.colors = [color.withAlphaComponent(Theme.Fold.glowOpacity).cgColor, color.withAlphaComponent(0).cgColor]
            layer.startPoint = pool.center
            layer.endPoint = CGPoint(x: pool.center.x + pool.radii.width, y: pool.center.y + pool.radii.height)
            return layer
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Theme.Fold.ground
        for pool in pools {
            layer.addSublayer(pool)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pool in pools {
            pool.frame = bounds
        }
        CATransaction.commit()
    }
}
