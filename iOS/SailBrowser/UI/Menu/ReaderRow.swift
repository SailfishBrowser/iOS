extension MenuRow {
    // Reader Mode, enabled once the page has an article; while the reader shows, the row closes it.
    static func reader(_ controller: WebTabController, env: AppEnvironment) -> MenuRow {
        let isOpen = controller.readerArticle != nil
        let interaction: Interaction = isOpen ? .readerClose : .readerOpen
        return MenuRow(
            id: "reader", icon: "doc.plaintext", title: isOpen ? "Close Reader Mode" : "Reader Mode",
            action: {
                env.haptics.fire(interaction)
                env.ui.close()
                if isOpen {
                    controller.closeReader()
                } else {
                    let lists = env.blocker.ruleLists(for: controller.webView.configuration.userContentController)
                    Task { await controller.openReader(ruleLists: lists) }
                }
            },
            isEnabled: isOpen || controller.isReaderable)
    }
}
