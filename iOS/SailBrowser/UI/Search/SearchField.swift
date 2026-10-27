import UIKit

final class SearchField: UITextField {
    private let clearButton = UIButton(type: .custom)
    // Inside the capsule, so the capsule's morph to and from the "+" pill clips it with the rest of the field. On an
    // empty field it sits where the clear button sits over text.
    let privateToggle = UIButton(type: .custom)
    // The grey "Incognito" left of the eyes or the clear button, wiped in from its leading edge by its mask's width.
    let privateLabel = UILabel()
    private(set) var isPrivate = false
    private let onClear: () -> Void

    override var text: String? {
        didSet { updateClearButton() }
    }

    init(onPress: @escaping () -> Void, onClear: @escaping () -> Void) {
        self.onClear = onClear
        super.init(frame: .zero)
        font = Theme.Typography.searchFieldUIFont
        textColor = .white
        tintColor = UIColor(Theme.Palette.searchCaret)
        attributedPlaceholder = NSAttributedString(
            string: "Search...",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(Theme.Opacity.searchFieldPlaceholder)])
        let glyph = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(font: Theme.Typography.searchClearUIFont))!
        clearButton.setImage(
            glyph.withTintColor(.white.withAlphaComponent(Theme.Opacity.searchClear), renderingMode: .alwaysOriginal),
            for: .normal)
        clearButton.addAction(UIAction { _ in onPress() }, for: .touchDown)
        clearButton.addAction(UIAction { [unowned self] _ in clear() }, for: .primaryActionTriggered)
        rightView = clearButton
        rightViewMode = .always
        addSubview(privateToggle)
        privateLabel.text = "Incognito"
        privateLabel.font = Theme.Typography.privateFieldLabelUIFont
        privateLabel.textColor = Theme.Palette.privateFieldLabel
        privateLabel.isUserInteractionEnabled = false
        let wipe = CALayer()
        wipe.backgroundColor = UIColor.black.cgColor
        wipe.anchorPoint = CGPoint(x: 0, y: 0.5)
        privateLabel.layer.mask = wipe
        addSubview(privateLabel)
        showPrivate(false)
        addAction(UIAction { [unowned self] _ in updateClearButton() }, for: .editingChanged)
        updateClearButton()
        keyboardAppearance = .dark
        keyboardType = .webSearch
        returnKeyType = .go
        enablesReturnKeyAutomatically = true
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        textContentType = .URL
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        textArea(bounds)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        textArea(bounds)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        textArea(bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        privateToggle.frame = privateToggleRect(forBounds: bounds)
        privateLabel.frame = privateLabelRect(forBounds: bounds)
        let size = privateLabel.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        privateLabel.layer.mask!.bounds = CGRect(x: 0, y: 0, width: isPrivate ? size.width : 0, height: size.height)
        privateLabel.layer.mask!.position = CGPoint(x: 0, y: size.height / 2)
        CATransaction.commit()
    }

    // "eyes.inverse" draws the off glyph, two outlined ovals; "eyes" its on glyph, two solid ones. The glyph swaps at
    // once; the label's wipe is the sheet's to run.
    func showPrivate(_ on: Bool) {
        isPrivate = on
        setNeedsLayout()
        let glyph = UIImage(
            systemName: on ? "eyes" : "eyes.inverse",
            withConfiguration: UIImage.SymbolConfiguration(font: Theme.Typography.privateToggleUIFont))!
        privateToggle.setImage(
            glyph.withTintColor(.white.withAlphaComponent(on ? 1 : Theme.Opacity.searchClear), renderingMode: .alwaysOriginal),
            for: .normal)
        privateToggle.accessibilityLabel = on ? "Turn Off Incognito" : "Turn On Incognito"
    }

    // Each button takes its glyph and the gap on each side, so the touches end where the text does.
    override func rightViewRect(forBounds bounds: CGRect) -> CGRect {
        button(clearButton, gap: Theme.Metrics.searchClearGap, in: bounds)
    }

    func privateToggleRect(forBounds bounds: CGRect) -> CGRect {
        button(privateToggle, gap: Theme.Metrics.privateToggleGap, in: bounds)
    }

    private func button(_ button: UIButton, gap: CGFloat, in bounds: CGRect) -> CGRect {
        let width = button.intrinsicContentSize.width + 2 * gap
        return CGRect(
            x: bounds.maxX - Theme.Metrics.searchClearCenterInset - width / 2, y: bounds.minY, width: width,
            height: bounds.height)
    }

    private func privateLabelRect(forBounds bounds: CGRect) -> CGRect {
        let end = clearButton.isHidden ? privateToggleRect(forBounds: bounds).minX : rightViewRect(forBounds: bounds).minX
        let width = privateLabel.intrinsicContentSize.width
        return CGRect(x: end - width, y: bounds.minY, width: width, height: bounds.height)
    }

    private func textArea(_ bounds: CGRect) -> CGRect {
        let inset = bounds.insetBy(dx: Theme.Metrics.searchFieldTextInset, dy: 0)
        let trailing = clearButton.isHidden ? privateToggleRect(forBounds: bounds).minX : rightViewRect(forBounds: bounds).minX
        let end = isPrivate ? privateLabelRect(forBounds: bounds).minX : trailing
        return CGRect(x: inset.minX, y: inset.minY, width: end - inset.minX, height: inset.height)
    }

    private func updateClearButton() {
        clearButton.isHidden = text?.isEmpty ?? true
        privateToggle.isHidden = !clearButton.isHidden
        setNeedsLayout()
    }

    private func clear() {
        onClear()
        text = ""
        sendActions(for: .editingChanged)
    }
}

final class SearchFieldCapsule: UIView {
    static let fieldFill = UIColor.white.withAlphaComponent(Theme.Opacity.searchFieldFill)

    static func pillFill(_ look: SearchBarLook) -> UIColor {
        UIColor(look.style.controlFill)
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = Self.fieldFill
        layer.borderWidth = Theme.Metrics.hairlineWidth
        layer.borderColor = UIColor.white.withAlphaComponent(Theme.Opacity.searchFieldRim).cgColor
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// The sheet's own blur, and the destination bar drawn under it: both square at the bar, so the hand-off to the real bar
// at the end of a close (and from it at the start of an open) shows no step.
final class SearchSheetMaterial: ChromeMaterial {
    override init(_ style: UIBlurEffect.Style?) {
        super.init(style)
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        shape(barProgress: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // A blur leaves by its effect, never by an alpha on it or an ancestor over the sharp page, which drops it at once.
    func clear() {
        show(nil)
        contentView.alpha = 0
    }

    func restore() {
        show(Theme.Frost.sheet)
        contentView.alpha = 1
    }

    func shape(barProgress progress: CGFloat) {
        layer.cornerRadius = Theme.Metrics.searchSheetCorner * (1 - progress)
    }
}

final class SearchSheetEdge: SheetEdge {
    init() {
        super.init(corner: Theme.Metrics.searchSheetCorner)
        shape(barProgress: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func shape(barProgress progress: CGFloat) {
        layer.cornerRadius = Theme.Metrics.searchSheetCorner * (1 - progress)
        let edge = Theme.Opacity.searchSheetEdge + (Theme.Opacity.barEdge - Theme.Opacity.searchSheetEdge) * progress
        layer.borderColor = UIColor.white.withAlphaComponent(edge).cgColor
    }
}
