import SwiftUI

// One drag of the sheet from where it is drawn: 1:1 down, stretched up. Only the finger's own travel decides: the detent
// arms on it and a flick projects it, so a sheet taken mid-motion and let go at once returns.
nonisolated struct MenuDrag: Equatable, Sendable {
    enum Release: Equatable { case close(velocity: Double), stay(velocity: Double) }

    // Where the drag starts, as a translation: a sheet drawn above its rest is already stretched.
    private let base: CGFloat
    private var detent = Detent(line: Theme.Gesture.sheetDragClose)

    init(from offset: CGFloat = 0) {
        base = offset >= 0 ? offset : -Magnet.rubberBandInverse(-offset, stretch: Theme.Gesture.sheetStretch)
    }

    mutating func changed(_ translation: CGFloat) -> CGFloat {
        _ = detent.update(translation)
        return SheetDrag.offset(translation: base + translation)
    }

    // The velocity is relative to what is left of the travel to where the sheet goes.
    func ended(translation: CGFloat, velocity: CGFloat, sheetHeight: CGFloat) -> Release {
        let offset = SheetDrag.offset(translation: base + translation)
        if SheetDrag.closes(armed: detent.isArmed, translation: translation, velocity: velocity) {
            return .close(velocity: SheetDrag.releaseVelocity(velocity, toward: sheetHeight - offset))
        }
        return .stay(velocity: SheetDrag.releaseVelocity(velocity, toward: -offset))
    }
}

// The menu's content: the address pill, a row of tiles, then cards of rows. Rows are data, kept in `sections`, so a new
// row or a new card is one more entry there.
struct MenuSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var systemScheme
    let controller: WebTabController
    let tab: Tab
    let onLook: (MenuLook) -> Void
    // Runs a change that folds or unfolds a card, so the host can move the sheet to its new height.
    let onFold: (@escaping () -> Void) -> Void
    @State private var footer: TrackerFooter.Shown?
    // The language the Translate row offers, which comes and goes as a fold does.
    @State private var translateSource: Locale.Language?

    var body: some View {
        let traits = UITraitCollection(userInterfaceStyle: systemScheme == .dark ? .dark : .light)
        let isLight = Theme.Palette.isLight(controller.barTint, in: traits)
        let ink = Theme.Palette.menuInk(light: isLight)
        let fill = ink.opacity(Theme.Opacity.menuFill)
        let pin = Self.pinTile(pinned: tab.isPinned)
        VStack(spacing: 0) {
            NavPill(controller: controller, fill: fill, ink: ink)
            HStack(spacing: Theme.Metrics.menuTileGap) {
                ActionTile(
                    title: "Find on Page", systemImage: "doc.text.magnifyingglass", fill: fill, ink: ink,
                    preparing: .menuFind
                ) {
                    env.haptics.fire(.menuFind)
                    env.ui.close()
                    controller.presentFind()
                }
                ActionTile(
                    title: pin.title, systemImage: pin.systemImage, fill: fill, ink: ink, preparing: pin.interaction,
                    on: tab.isPinned ? Color(isLight ? Theme.Palette.menuSheetTop : Theme.Palette.menuSheetDark) : nil,
                    action: togglePin
                )
                #if DEBUG
                .background { Color.clear.debugAction(pin.interaction, togglePin).id(pin.interaction) }
                #endif
                ActionTile(title: "Share", systemImage: "square.and.arrow.up", fill: fill, ink: ink, preparing: .menuShare) {
                    env.haptics.fire(.menuShare)
                    env.ui.close()
                    SharePresenter.share(controller)
                }
                .disabled(controller.url == nil)
            }
            .padding(.top, Theme.Metrics.menuPillToTiles)
            VStack(spacing: Theme.Metrics.menuGroupGap) {
                ForEach(sections.indices, id: \.self) { index in
                    MenuGroup(section: sections[index], fill: fill, ink: ink)
                }
                if let footer, let siteSettingsAction {
                    TrackerFooter(shown: footer, fill: fill, open: siteSettingsAction)
                }
            }
            .padding(.top, ActionTile.labelToList)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink.opacity(Theme.Opacity.menuPrimary))
        .padding([.horizontal, .top], Theme.Metrics.menuPadding)
        .padding(.bottom, Theme.Metrics.menuBottomPadding)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .onChange(of: MenuLook(isLight: isLight, tint: tint), initial: true) { _, look in onLook(look) }
        .onChange(of: footerShown, initial: true) { _, shown in showFooter(shown) }
        .onChange(of: controller.translator.source, initial: true) { _, source in onFold { translateSource = source } }
    }

    private var sections: [MenuSection] {
        let expanded = env.browser.settings.displayOptionsExpanded
        return [
            MenuSection(
                header: MenuRow(
                    id: "displayOptions", icon: "doc.richtext", title: "Display Options", accessory: .fold(expanded: expanded),
                    action: toggleDisplayOptions),
                rows: TranslateRow.rows(for: controller.translator, source: translateSource, env: env) + [
                    .reader(controller, env: env),
                    MenuRow(
                        id: "pageZoom", icon: "textformat.size", title: "Page Zoom",
                        accessory: controller.url?.host().map(MenuRow.Accessory.zoom(host:))),
                    MenuRow(
                        id: "desktopSite", icon: tab.prefersDesktop ? "iphone" : "laptopcomputer",
                        title: tab.prefersDesktop ? "Request Mobile Site" : "Request Desktop Site",
                        action: toggleDesktop),
                ],
                expanded: expanded),
            MenuSection(rows: [MenuRow(id: "siteSettings", icon: "gearshape", title: "Site Settings", action: siteSettingsAction)]),
        ]
    }

    // The site's colour, from its favicon.
    private var tint: UIColor? {
        controller.url?.host().flatMap { env.favicons.favicon(for: $0).tint }
    }

    static func pinTile(pinned: Bool) -> (title: String, systemImage: String, interaction: Interaction) {
        pinned ? ("Unpin", "pin.slash", .unpin) : ("Pin", "pin", .pin)
    }

    private func togglePin() {
        let pinned = !tab.isPinned
        env.setPinned(pinned, for: tab.id)
        env.haptics.fire(pinned ? .pin : .unpin)
    }

    private func toggleDisplayOptions() {
        env.haptics.fire(.displayOptionsToggle)
        onFold { env.browser.settings.displayOptionsExpanded.toggle() }
    }

    // A page without a host has no site to set.
    private var siteSettingsAction: (() -> Void)? {
        guard let host = controller.url?.host() else { return nil }
        return {
            env.haptics.fire(.settingsOpen)
            env.ui.close()
            env.ui.openSiteSettings(for: host)
        }
    }

    private var footerShown: TrackerFooter.Shown? {
        guard let host = controller.url?.host(),
            let content = TrackerFooter.Content.of(
                blocksGlobally: !env.browser.settings.blockedCategories.isEmpty,
                blocksSite: env.siteSettings(forHost: host).blocksTrackers, count: controller.blockedCount)
        else { return nil }
        return TrackerFooter.Shown(host: host, content: content)
    }

    // The footer comes and goes as a fold does: springing while the menu is up, after a close has hidden it.
    private func showFooter(_ shown: TrackerFooter.Shown?) {
        onFold { footer = shown }
    }

    private func toggleDesktop() {
        env.haptics.fire(.desktopToggle)
        env.setDesktopMode(!tab.prefersDesktop, for: tab.id)
    }
}

struct MenuRow: Identifiable {
    enum Accessory {
        case zoom(host: String)
        // A short text at the right, or a spinner while it is nil.
        case status(String?)
        // A fold header's chevron: down while its rows show, right while they are folded away.
        case fold(expanded: Bool)
    }

    // Stable while the title changes, as Request Desktop Site's does, so the row is not rebuilt under the finger.
    let id: String
    let icon: String
    let title: String
    var accessory: Accessory?
    // A row with an action is a button; one without holds its accessory's controls.
    var action: (() -> Void)?
    var isEnabled = true
}

// A card: an optional header that folds it, then its rows.
struct MenuSection {
    var header: MenuRow?
    let rows: [MenuRow]
    var expanded = true
}

// A card of rows, each its own fill, apart by a hairline that shows the sheet.
struct MenuGroup: View {
    let section: MenuSection
    let fill: Color
    let ink: Color

    var body: some View {
        let shown = section.expanded ? section.rows : []
        VStack(spacing: Theme.Metrics.menuRowGap) {
            // A disabled row is drawn as one, its text and glyph dimmed, so an enabled row's press dims it all as before.
            ForEach([section.header].compactMap { $0 } + shown) { row in
                if let action = row.action, row.isEnabled {
                    Button(action: action) { content(row) }
                } else if row.action != nil {
                    content(row)
                        .disabled(true)
                        .accessibilityAddTraits(.isButton)
                } else {
                    content(row)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.menuListCorner, style: .continuous))
    }

    private func content(_ row: MenuRow) -> some View {
        HStack(spacing: 0) {
            Text(row.title)
                .font(Theme.Typography.menuRow)
            Spacer(minLength: 0)
            switch row.accessory {
            case .zoom(let host):
                ZoomStepper(host: host, ink: ink)
                    .padding(.trailing, Theme.Metrics.menuStepperInset)
            case .status(let text?):
                Text(text)
                    .font(Theme.Typography.menuRow)
                    .foregroundStyle(ink.opacity(Theme.Opacity.menuSecondary))
                    .padding(.trailing, Theme.Metrics.menuStepperInset)
            case .status(nil):
                ProgressView()
                    .accessibilityLabel("In Progress")
                    .padding(.trailing, Theme.Metrics.menuStepperInset)
            case .fold(let expanded):
                FoldChevron(expanded: expanded, color: UIColor(ink.opacity(Theme.Opacity.menuChevron)))
                    .fixedSize()
                    .frame(width: 2 * Theme.Metrics.menuChevronCentre)
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
        }
        .padding(.leading, Theme.Metrics.menuRowTextInset)
        .overlay(alignment: .leading) {
            Image(systemName: row.icon)
                .font(Theme.Typography.menuRowIcon)
                .foregroundStyle(ink.opacity(Theme.Opacity.menuIcon))
                .frame(width: 2 * Theme.Metrics.menuRowIconCentre)
                .accessibilityHidden(true)
        }
        .opacity(row.isEnabled ? 1 : Theme.Opacity.menuRowDisabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metrics.menuListRowHeight)
        .background(fill)
        .contentShape(Rectangle())
    }
}

// An image view as wide as it is tall, so a glyph keeps its size when turned.
final class SquareImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        let side = max(size.width, size.height)
        return CGSize(width: side, height: side)
    }
}

// A fold header's chevron: down while its rows show, right while they are folded away. It turns on Core Animation, on
// the fold's spring, from where it is drawn.
struct FoldChevron: UIViewRepresentable {
    let expanded: Bool
    let color: UIColor

    private var angle: CGFloat {
        expanded ? 0 : -.pi / 2
    }

    func makeUIView(context: Context) -> UIImageView {
        let chevron = SquareImageView(
            image: UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(font: Theme.Typography.menuChevronUIFont)))
        // Drawn unscaled in a square, so the glyph turned on its side is as tall as it was wide instead of being
        // squeezed into the wide, short frame of the down-pointing one.
        chevron.contentMode = .center
        chevron.transform = CGAffineTransform(rotationAngle: angle)
        return chevron
    }

    // A chevron never drawn yet, as in a menu folded while hidden, takes its angle with no motion.
    func updateUIView(_ chevron: UIImageView, context: Context) {
        chevron.tintColor = color
        // The angle reads back from the layer's transform, so it is compared within a tolerance.
        let shownAngle = chevron.layer.value(forKeyPath: "transform.rotation.z") as! CGFloat
        guard abs(shownAngle - angle) > Theme.Motion.angleSettled else { return }
        guard let shown = chevron.layer.presentation() else {
            chevron.transform = CGAffineTransform(rotationAngle: angle)
            return
        }
        let turn = Theme.Motion.menuFold.layerAnimation(
            keyPath: "transform.rotation.z", from: shown.value(forKeyPath: "transform.rotation.z")!)
        turn.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.layer.add(turn, forKey: "turn")
        chevron.transform = CGAffineTransform(rotationAngle: angle)
        chevron.layer.letSpringsArrive()
        CATransaction.commit()
    }
}
