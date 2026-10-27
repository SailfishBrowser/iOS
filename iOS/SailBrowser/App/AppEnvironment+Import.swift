import Foundation

extension AppEnvironment {
    // Imported tabs join the end of the deck unshown and never private, whatever incognito says, so they are not the
    // previous tab or a recent until visited (21b). An empty deck opens the first one, so the active tab has a page.
    func importTabs(_ tabs: [ImportedTab]) {
        var rest = tabs[...]
        if browser.activeTab == nil, let first = tabs.first {
            open(first.url)
            browser.updatePage(browser.activeTabID!, url: first.url, title: first.title, tint: nil)
            rest = tabs.dropFirst()
        }
        for imported in rest {
            var tab = browser.makeTab(url: imported.url)
            tab.title = imported.title
            tab.lastActiveAt = .distantPast
            browser.insert(tab, activate: false)
        }
        if !tabs.isEmpty {
            haptics.fire(.archiveRestore)
        }
    }
}
