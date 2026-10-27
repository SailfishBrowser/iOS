import SwiftUI
import UIKit

struct NavPill: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    let controller: WebTabController
    let fill: Color
    let ink: Color
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                URLEditor(
                    text: controller.url?.absoluteString,
                    keyboardAppearance: colorScheme == .dark ? .dark : .light,
                    onSubmit: submit,
                    onEnd: { isEditing = false }
                )
                .padding(.horizontal, Theme.Metrics.menuPadding)
            } else {
                button("chevron.left", label: "Back", enabled: controller.canGoBack, action: controller.goBack)
                button("chevron.right", label: "Forward", enabled: controller.canGoForward, action: controller.goForward)
                Button {
                    env.haptics.fire(.menuAddressEdit)
                    isEditing = true
                } label: {
                    ZStack {
                        if let url = controller.url {
                            Text(verbatim: Self.displayText(url))
                                .font(Theme.Typography.navPillURL)
                                .foregroundStyle(ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Edit Address")
                Button(action: copyLink) {
                    icon("link")
                }
                .buttonStyle(PressStyle(scale: Theme.Metrics.pressScaleWide, preparing: .menuCopyLink))
                .disabled(controller.url == nil)
                .opacity(controller.url == nil ? Theme.Opacity.navPillDisabled : 1)
                .accessibilityLabel("Copy Link")
                #if DEBUG
                .debugAction(.menuCopyLink, copyLink)
                #endif
                button("arrow.clockwise", label: "Reload", enabled: true, action: controller.reload)
                #if DEBUG
                .debugAction(.menuNav) { navigate(controller.reload) }
                #endif
            }
        }
        .padding(.horizontal, isEditing ? 0 : Theme.Metrics.navPillInset)
        .frame(height: Theme.Metrics.navPillHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.navPillCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metrics.navPillCorner)
                .strokeBorder(ink.opacity(Theme.Opacity.navPillStroke), lineWidth: Theme.Metrics.hairlineWidth)
        }
    }

    static func displayText(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let path = url.path()
        return path == "/" ? host : host + path
    }

    private func submit(_ text: String) {
        guard let url = InputResolver.resolve(text, engine: env.browser.settings.searchEngine) else { return }
        env.haptics.fire(.menuAddressSubmit)
        controller.load(url)
        env.ui.close()
    }

    private func copyLink() {
        UIPasteboard.general.url = TrackingParams.strip(controller.url!)
        env.haptics.fire(.menuCopyLink)
    }

    private func navigate(_ action: () -> Void) {
        env.haptics.fire(.menuNav)
        action()
    }

    private func button(_ systemImage: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            navigate(action)
        } label: {
            icon(systemImage)
        }
        .buttonStyle(PressStyle(scale: Theme.Metrics.pressScaleWide, preparing: .menuNav))
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.navPillDisabled)
        .accessibilityLabel(label)
    }

    private func icon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(Theme.Typography.navPillGlyph)
            .foregroundStyle(ink.opacity(Theme.Opacity.menuIcon))
            .frame(width: Theme.Metrics.navPillButtonWidth, height: Theme.Metrics.navPillHeight)
            .contentShape(Rectangle())
    }
}

private struct URLEditor: UIViewRepresentable {
    let text: String?
    let keyboardAppearance: UIKeyboardAppearance
    let onSubmit: (String) -> Void
    let onEnd: () -> Void

    final class Field: UITextField {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                becomeFirstResponder()
                selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: URLEditor

        init(parent: URLEditor) {
            self.parent = parent
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit(textField.text!)
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEnd()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = text
        field.font = Theme.Typography.navPillURLUIFont
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.keyboardAppearance = keyboardAppearance
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
    }
}
