import UIKit

// The native page inside the web view for a failed load: opaque, takes touches, the tab's last picture dimmed under
// the reason in plain words, the host and one button, and a text action back to the page under it when there is one.
final class LoadErrorView: UIView {
    let glyphView = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let button = UIButton(type: .custom)
    let dismissButton = UIButton(type: .custom)
    private(set) var backdropView: UIImageView?
    private var dim: UIView?
    private var band: UIView?
    private let onAction: () -> Void
    private let onDismiss: (() -> Void)?
    private var insets = UIEdgeInsets.zero

    init(
        error: LoadError, backdrop: UIImage?, background: UIColor, onAction: @escaping () -> Void,
        onDismiss: (() -> Void)?
    ) {
        self.onAction = onAction
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        backgroundColor = background
        isOpaque = true
        clipsToBounds = true
        overrideUserInterfaceStyle = .dark
        let ink = Theme.Network.errorInk
        if let backdrop {
            let imageView = UIImageView(image: backdrop)
            backdropView = imageView
            addSubview(imageView)
            let dim = UIView()
            dim.backgroundColor = .black.withAlphaComponent(Theme.Network.errorSnapshotDim)
            addSubview(dim)
            self.dim = dim
            let band = UIView()
            band.backgroundColor = background
            addSubview(band)
            self.band = band
        }
        glyphView.tintColor = ink
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: Theme.Network.errorGlyphStyle)
        addSubview(glyphView)
        titleLabel.font = Theme.Network.errorTitleFont
        titleLabel.textColor = ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "loadError.title"
        addSubview(titleLabel)
        detailLabel.font = Theme.Network.errorDetailFont
        detailLabel.textColor = ink.withAlphaComponent(Theme.Network.errorDetailOpacity)
        detailLabel.textAlignment = .center
        addSubview(detailLabel)
        button.titleLabel?.font = Theme.Network.errorButtonFont
        button.setTitleColor(ink, for: .normal)
        button.backgroundColor = ink.withAlphaComponent(Theme.Network.errorButtonFill)
        button.accessibilityIdentifier = "loadError.action"
        button.addAction(UIAction { [unowned self] _ in self.onAction() }, for: .touchUpInside)
        addSubview(button)
        dismissButton.titleLabel?.font = Theme.Network.errorDetailFont
        dismissButton.setTitleColor(ink.withAlphaComponent(Theme.Network.errorDetailOpacity), for: .normal)
        dismissButton.setTitle("Go back", for: .normal)
        dismissButton.accessibilityIdentifier = "loadError.dismiss"
        dismissButton.addAction(UIAction { [unowned self] _ in self.onDismiss?() }, for: .touchUpInside)
        addSubview(dismissButton)
        for label in [titleLabel, detailLabel, button.titleLabel!, dismissButton.titleLabel!] {
            label.adjustsFontForContentSizeCategory = true
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self], action: #selector(setNeedsLayout))
        update(error: error, canDismiss: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The copy, the symbol, the button and the way back change in place; the backdrop stays the last real picture.
    func update(error: LoadError, canDismiss: Bool) {
        glyphView.image = UIImage(systemName: error.reason.symbol)
        titleLabel.text = error.reason.title
        detailLabel.text = error.host
        detailLabel.isHidden = error.host == nil
        button.setTitle(error.reason.button, for: .normal)
        dismissButton.isHidden = onDismiss == nil || !canDismiss
        setNeedsLayout()
    }

    // The page's obscured insets: the column sits centred between the band and the bar.
    func apply(insets: UIEdgeInsets) {
        self.insets = insets
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if let backdropView, let image = backdropView.image {
            let height = image.size.height * width / image.size.width
            backdropView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            dim?.frame = backdropView.frame
            band?.frame = CGRect(x: 0, y: 0, width: width, height: insets.top)
        }
        let textWidth = width - 2 * Theme.Network.errorSidePadding
        let gap = Theme.Network.errorGap
        glyphView.sizeToFit()
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        detailLabel.sizeToFit()
        dismissButton.sizeToFit()
        // The button's width and height are minimums: its label grows with the text size.
        let buttonLabel = button.titleLabel!.intrinsicContentSize
        let buttonSize = CGSize(
            width: max(Theme.Network.errorButtonMinWidth, buttonLabel.width + 2 * Theme.Network.errorButtonPadding),
            height: max(Theme.Network.errorButtonHeight, buttonLabel.height + Theme.Network.errorButtonPadding))
        button.layer.cornerRadius = buttonSize.height / 2
        var sizes: [(UIView, CGSize)] = [
            (glyphView, glyphView.bounds.size), (titleLabel, CGSize(width: textWidth, height: titleHeight)),
        ]
        if !detailLabel.isHidden {
            sizes.append((detailLabel, CGSize(width: min(textWidth, detailLabel.bounds.width), height: detailLabel.bounds.height)))
        }
        sizes.append((button, buttonSize))
        if !dismissButton.isHidden {
            sizes.append((dismissButton, dismissButton.bounds.size))
        }
        let total = sizes.reduce(0) { $0 + $1.1.height } + gap * CGFloat(sizes.count - 1)
        var y = bounds.inset(by: insets).midY - total / 2
        for (view, size) in sizes {
            view.frame = CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height)
            y += size.height + gap
        }
    }
}
