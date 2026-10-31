import Foundation
import Testing
import UIKit
@testable import SailBrowser

struct ShareItemsTests {
    @Test func aLivePageSharesTheStrippedURL() {
        let page = SharedPage(url: URL(string: "https://example.com/?utm_source=x&id=1")!, subject: "T")

        #expect(page.url == URL(string: "https://example.com/?id=1")!)
    }

    @Test func anArchivedEntrySharesItsURLOnly() {
        let entry = ArchivedTab(
            id: UUID(), url: URL(string: "https://example.com/?utm_source=x&id=1")!, title: "Old", archivedAt: .now)

        let items = SharePresenter.activityItems(for: entry.url)

        #expect(!items.contains { $0 is UIPrintFormatter })
        #expect(items.count == 1)
        #expect(items.first as? URL == URL(string: "https://example.com/?id=1")!)
    }
}
