import SwiftUI
import UIKit

// The status bar reads on what is behind it: the band (the page's or the reader's) while browsing, dark backdrops
// everywhere else.
enum StatusBarStyle {
    static func style(
        tint: UIColor?, deckProgress: CGFloat, overlay: UIState.Overlay, traits: UITraitCollection
    ) -> UIStatusBarStyle {
        guard let tint, deckProgress == 0, overlay == .none || overlay == .menu else {
            return .lightContent
        }
        return Theme.Palette.isLight(tint, in: traits) ? .darkContent : .lightContent
    }
}

// SwiftUI's root controller offers no status bar style of its own, so a clear window above the app's, with no
// touches and never key, owns it.
final class StatusBarWindow: UIWindow {
    private let controller = StatusBarController()

    var style: UIStatusBarStyle {
        get { controller.style }
        set { controller.style = newValue }
    }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .normal + 1
        backgroundColor = .clear
        isUserInteractionEnabled = false
        rootViewController = controller
        isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    override var canBecomeKey: Bool {
        false
    }
}

private final class StatusBarController: UIViewController {
    var style = UIStatusBarStyle.lightContent {
        didSet {
            if style != oldValue {
                setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        style
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
}

// Reads only what the style needs, so a change elsewhere never re-renders it.
struct StatusBarStyler: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ui = env.ui
        StatusBarInstaller(
            style: StatusBarStyle.style(
                tint: env.activeIsPrivate ? Theme.Palette.privateBand : env.activeController?.bandTint, deckProgress: ui.deckProgress, overlay: ui.overlay,
                traits: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)),
            isFullscreen: OrientationPolicy.shared.isElementFullscreen)
    }
}

struct StatusBarInstaller: UIViewRepresentable {
    let style: UIStatusBarStyle
    let isFullscreen: Bool

    final class InstallerView: UIView {
        var style = UIStatusBarStyle.lightContent {
            didSet { statusWindow?.style = style }
        }
        // While a page is in element fullscreen the status window steps aside, so WebKit's own controller, in its
        // window above the app's, shows and hides the bar with its controls.
        var isFullscreen = false {
            didSet { statusWindow?.isHidden = isFullscreen }
        }
        private(set) var statusWindow: StatusBarWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard statusWindow == nil, let scene = window?.windowScene else { return }
            let statusWindow = StatusBarWindow(windowScene: scene)
            statusWindow.style = style
            statusWindow.isHidden = isFullscreen
            self.statusWindow = statusWindow
        }
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.style = style
        view.isFullscreen = isFullscreen
    }
}
