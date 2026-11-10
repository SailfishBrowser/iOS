import SwiftUI
import WebKit

struct WebPageView: UIViewRepresentable {
    let controller: WebTabController
    let geometry: CardGeometry
    let isInteractive: Bool
    let isPrivate: Bool
    @Environment(\.screenInsets) private var screenInsets

    final class Container: UIView {
        private(set) weak var hosted: WKWebView?
        private(set) weak var hostedReader: UIView?
        var onWindow: (() -> Void)?
        var orientation: OrientationPolicy = .shared
        private var fullscreenObservation: NSKeyValueObservation?
        // The page's safe space at the top: the page tint over the status bar, above the page so
        // nothing scrolls under the status bar, and inside the stage so it scales and clips with the card.
        let band = UIView()
        let privateBand = PrivateBandView()
        private let stage = UIView()
        private let crop = CropLayer()
        private var cropHeight = CGFloat.infinity
        private var cropTop: CGFloat = 0
        private var geometry: CardGeometry?
        // The edge swipe's slide: the page moves right with the finger over a picture of the tab it lands on.
        private var edgeShift: CGFloat = 0
        private var underlay: EdgeUnderlay?

        override init(frame: CGRect) {
            super.init(frame: frame)
            stage.backgroundColor = UIColor(Theme.Palette.newTabPlaceholder)
            stage.layer.masksToBounds = true
            stage.layer.cornerCurve = .continuous
            crop.backgroundColor = UIColor.black.cgColor
            crop.cornerCurve = .continuous
            band.isUserInteractionEnabled = false
            stage.addSubview(band)
            privateBand.isHidden = true
            band.addSubview(privateBand)
            addSubview(stage)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var safeAreaInsets: UIEdgeInsets {
            .zero
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            stage.bounds = bounds
            stage.center = CGPoint(x: bounds.midX, y: bounds.midY)
            band.frame.size.width = bounds.width
            privateBand.frame = band.bounds
            applyCrop()
            if let underlay {
                underlay.frame = bounds
                underlay.layout(shift: edgeShift)
            }
        }

        func paintBand(height: CGFloat, color: UIColor) {
            band.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            band.backgroundColor = color
        }

        func showPrivateBand(_ shown: Bool, safeTop: CGFloat) {
            privateBand.isHidden = !shown
            privateBand.frame = band.bounds
            privateBand.layout(safeTop: safeTop)
        }

        func apply(_ geometry: CardGeometry) {
            self.geometry = geometry
            applyTransform()
            stage.layer.cornerRadius = geometry.corner / geometry.scale
            stage.alpha = geometry.opacity
            cropHeight = geometry.clipHeight / geometry.scale
            cropTop = geometry.clipTop / geometry.scale
            applyCrop()
        }

        private func applyTransform() {
            guard let geometry else { return }
            stage.transform = CGAffineTransform(
                translationX: geometry.offset.width + edgeShift, y: geometry.offset.height
            ).scaledBy(x: geometry.scale, y: geometry.scale)
        }

        // The picture of the tab the swipe lands on goes under the page, at the page's own size.
        func beginEdgeSwipe(picture: UIImage?, fill: UIColor) {
            underlay?.removeFromSuperview()
            let underlay = EdgeUnderlay(picture: picture, fill: fill)
            underlay.frame = bounds
            insertSubview(underlay, belowSubview: stage)
            self.underlay = underlay
            setEdgeShift(0)
        }

        // Animatable: a block animation moves the page, the picture's parallax, its dim and the page's shadow together.
        func setEdgeShift(_ shift: CGFloat) {
            edgeShift = shift
            applyTransform()
            underlay?.layout(shift: shift)
        }

        func endEdgeSwipe() {
            underlay?.removeFromSuperview()
            underlay = nil
            edgeShift = 0
            applyTransform()
        }

        private func applyCrop() {
            guard cropHeight < stage.bounds.height || cropTop > 0 else {
                if stage.layer.mask != nil {
                    stage.layer.mask = nil
                }
                return
            }
            let frame = CGRect(
                x: 0, y: cropTop, width: stage.bounds.width, height: min(cropHeight, stage.bounds.height) - cropTop)
            if crop.frame != frame || crop.cornerRadius != stage.layer.cornerRadius {
                crop.update(frame: frame, corner: stage.layer.cornerRadius)
            }
            if stage.layer.mask !== crop {
                stage.layer.mask = crop
            }
        }

        // True while WebKit holds the page in its own window for element fullscreen; nothing here touches it then.
        var isHoldingFullscreen: Bool {
            guard let hosted else { return false }
            return hosted.fullscreenState != .notInFullscreen
        }

        // A page in fullscreen is never moved: it is adopted, so its exit is heard, and hosted once it is back.
        func hostIfNeeded(_ webView: WKWebView, reader: UIView) {
            if webView.fullscreenState != .notInFullscreen {
                if hosted !== webView {
                    adopt(webView, reader: reader)
                }
            } else if webView.superview?.superview !== self {
                host(webView, reader: reader)
            }
        }

        // The reader sits over the page in the card, so it takes the card's place, corner and crop; the band stays over
        // both.
        func host(_ webView: WKWebView, reader: UIView) {
            endEdgeSwipe()
            for subview in stage.subviews where subview !== band {
                subview.removeFromSuperview()
            }
            for view in [webView, reader] {
                stage.insertSubview(view, belowSubview: band)
                pin(view)
            }
            adopt(webView, reader: reader)
        }

        // WebKit hands the page back under its placeholder with a fixed frame and no constraints, then removes the
        // placeholder itself, so the page is pinned where it is; a page handed back elsewhere is hosted afresh.
        private func fullscreenChanged(_ webView: WKWebView) {
            guard webView.fullscreenState == .notInFullscreen, let reader = hostedReader else { return }
            if webView.superview === stage {
                // An episode WebKit abandons before moving the page leaves its constraints in place.
                if !stage.constraints.contains(where: { $0.firstItem === webView }) {
                    pin(webView)
                }
            } else {
                host(webView, reader: reader)
            }
        }

        // A dismantled card stops answering the page's exit; the policy still hears it.
        func dismantle() {
            endEdgeSwipe()
            fullscreenObservation = nil
            if let webView = hosted, webView.superview?.superview === self {
                webView.removeFromSuperview()
            }
            if let reader = hostedReader, reader.superview?.superview === self {
                reader.removeFromSuperview()
            }
        }

        private func adopt(_ webView: WKWebView, reader: UIView) {
            hosted = webView
            hostedReader = reader
            orientation.track(webView)
            // WebKit sets the state on the main thread inside its own fullscreen calls.
            fullscreenObservation = webView.observe(\.fullscreenState) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.fullscreenChanged(webView) }
            }
        }

        private func pin(_ view: UIView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                view.topAnchor.constraint(equalTo: stage.topAnchor),
                view.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
    }

    // Under the page during an edge swipe: the landing tab's picture over its tint, trailing the page by a share of the
    // width and dimmed until the page has gone, with a soft shadow along the page's left edge.
    final class EdgeUnderlay: UIView {
        private let content = UIView()
        private let picture = UIImageView()
        private let dim = UIView()
        private let shadow = UIView()
        private let shadowGradient = CAGradientLayer()

        init(picture image: UIImage?, fill: UIColor) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            clipsToBounds = true
            content.backgroundColor = fill
            picture.image = image
            picture.contentMode = .scaleToFill
            content.addSubview(picture)
            addSubview(content)
            dim.backgroundColor = .black
            addSubview(dim)
            shadowGradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.2).cgColor]
            shadowGradient.startPoint = CGPoint(x: 0, y: 0.5)
            shadowGradient.endPoint = CGPoint(x: 1, y: 0.5)
            shadow.layer.addSublayer(shadowGradient)
            addSubview(shadow)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // The picture is the page's width, top aligned, as the switcher's card draws it.
        func layout(shift: CGFloat) {
            let width = bounds.width
            let progress = EdgeArchive.progress(offset: shift, width: width)
            content.bounds = bounds
            content.center = CGPoint(
                x: bounds.midX + EdgeArchive.underlayOffset(progress: progress, width: width), y: bounds.midY)
            if let image = picture.image, image.size.width > 0 {
                picture.frame = CGRect(x: 0, y: 0, width: width, height: image.size.height * width / image.size.width)
            }
            dim.frame = bounds
            dim.alpha = EdgeArchive.underlayDim(progress: progress)
            let shadowWidth = Theme.Metrics.edgeArchiveShadow
            shadow.frame = CGRect(x: shift - shadowWidth, y: 0, width: shadowWidth, height: bounds.height)
            shadow.alpha = 1 - progress
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shadowGradient.frame = shadow.bounds
            CATransaction.commit()
        }
    }

    nonisolated final class CropLayer: CALayer {
        private(set) var updates = 0

        func update(frame: CGRect, corner: CGFloat) {
            updates += 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frame = frame
            cornerRadius = corner
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Container {
        Container()
    }

    func updateUIView(_ container: Container, context: Context) {
        container.hostIfNeeded(controller.webView, reader: controller.reader.view)
        // A private page starts below its taller band.
        let top = screenInsets.top + (isPrivate ? Theme.Metrics.privateBandExtra : 0)
        if !container.isHoldingFullscreen {
            controller.apply(safeTop: top)
        }
        container.paintBand(height: top, color: controller.bandTint)
        container.showPrivateBand(isPrivate, safeTop: screenInsets.top)
        container.onWindow = { [weak controller] in controller?.revealWhenPainted() }
        controller.revealWhenPainted()
        container.apply(geometry)
        container.isUserInteractionEnabled = isInteractive
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.dismantle()
    }
}
